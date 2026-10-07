#!/usr/bin/env bash
# 真机 golden 抓取与对比（P3-0 取证 / P3-9 收尾的「真机回归」那一项）。
#
# 为什么单独一个脚本：golden 对比是**替换前**的最后一关——rpcd 的响应与 molly 的响应
# 必须逐字段对得上，而且样本要可复现（谁都能重抓、谁都能重跑对比）。
#
# 三个动作：
#   ./tests/golden.sh device <host>        # ssh root@<host>：抓设备上的契约样本
#   ./tests/golden.sh molly  <base-url>    # 抓 molly 的 /ubus 响应（同一批探针）
#   ./tests/golden.sh http   <base-url>    # 抓 HTTP 层样本 → 写 http-molly/（原厂样本留在 http/）
#   ./tests/golden.sh compare <dir>        # 对比 <dir>/ubus 与 <dir>/molly 的每对样本
#
# 产物目录：.ai-memory/golden/<yyyy-mm-dd>/（可用 GOLDEN_DIR 覆盖）
#
# ---------------------------------------------------------------------------
# 对比口径（判据成立的前提，改动前先读完）
#
# compare 只在**两侧抓取口径对称**时才有意义。历史上它不对称，于是出现
# 「DIFF 10/10」的假失败（M5 设备验收 §6 记录在案）：
#   (a) 形状不对称：设备侧是 `ubus -v call` 的**裸回复**，molly 侧是
#       `/ubus/call/<obj>` 的 **JSON-RPC 信封**（`{"jsonrpc":…,"result":…}`）；
#   (b) 授权不对称：molly 侧原先**不带会话**，于是需要 ACL 的方法全回 `-32002`，
#       而设备侧走 CLI 不经 ACL。
#
# 现在脚本自己保证这两条：
#   1. **两侧都走 HTTP**——探针统一打 `<base>/ubus/call/<obj>`，设备侧是原厂
#      uhttpd、molly 侧是 molly 自己。**不能**用 `ubus` CLI 抓设备侧：CLI 不经
#      uhttpd 的 ACL，实测同一份数据两个口径不一样（`uci configs`：CLI 回 18 个
#      config、HTTP 回 `-32002`；`file read`：CLI 空、HTTP `-6`）——混用会把
#      「两侧都拒绝」误报成 molly 的缺陷。
#   2. **两侧各带 root SID**——设备侧 `Authorization: Bearer <设备 root sid>`，
#      molly 侧 `Authorization: Bearer <molly root sid>`。任一侧拿不到 root SID 时
#      **compare 直接判失败**（exit 2），不会退化成匿名口径后给你一个没有意义的
#      「零差异」。
#   3. **剥信封**——compare 的归一化认信封：带 `jsonrpc` 的对象取 `result`；只有
#      `error` 时归一成 `{"__rpc-error__":{"code":…,"message":…}}`。两侧形状因此
#      严格同层（同时把 `id` 这类噪声抹掉）。
#
# 会话 id 会在归一化时掩成 `<sid>`：两侧各自登录，sid 必然不同，不掩就是假差异。
#
# 环境变量：
#   设备侧 root 密码：MOLLY_DEVICE_PASS=xxx ./tests/golden.sh device 192.168.1.1
#   molly 侧 root 会话：MOLLY_SID=<32hex> 或 MOLLY_PASS=<root 密码>
#                       （给 MOLLY_PASS 时脚本自己 POST /ubus/ 登录取 sid）
#   MOLLY_DEVICE_PASS=xxx MOLLY_PASS=xxx GOLDEN_DIR=/tmp/g ./tests/golden.sh device 192.168.1.1
#
# 设备侧还需要：ssh 免密（或 ssh-agent）、ubus、uci。
# ---------------------------------------------------------------------------
set -o pipefail
# 注：故意不加 -u（nounset）。macOS 自带 bash 3.2 对空数组 ${arr[@]} 与未匹配 glob
# 的展开会误报 "unbound variable"，而脚本逻辑本身没问题（auth 空数组、molly/*.json
# 在基线缺失时是预期的）。Linux bash ≥4 不受影响，这里为跨平台统一去掉 -u。
cd "$(dirname "$0")/.."

DIR="${GOLDEN_DIR:-.ai-memory/golden/$(date +%F)}"
ACTION="${1:-}"
shift || true
HOST="${1:-}"

mkdir -p "$DIR"

# 探针表：对象.方法 + 参数（与 docs/interfaces.md §7-§10 的契约条目一一对应）。
# 只放**只读**方法：golden 抓取绝不能改设备状态（AGENTS.md §2.2、计划 §2）。
PROBES=(
  "session list {}"
  "session get {}"
  "uci configs {}"
  "uci get {\"config\":\"system\"}"
  "uci changes {}"
  "file stat {\"path\":\"/etc/hosts\"}"
  "file read {\"path\":\"/etc/hostname\"}"
  "file md5 {\"path\":\"/etc/hostname\"}"
  "file list {\"path\":\"/etc\"}"
  "luci-rpc getBoardJSON {}"
)

# HTTP 层探针（相对 URL → 存档名）
HTTP_PROBES=(
  "/ :: root"
  "/ubus/list :: ubus-list"
  "/ubus/list/session :: ubus-list-session"
  "/ubus/list/nope :: ubus-list-nope"
  "/cgi-bin/luci/ :: luci-root"
  "/cgi-bin/luci/admin/status/overview :: luci-overview"
  "/nope :: static-404"
)

# ---------------------------------------------------------------------------
# JSON 小工具（一律走 python3：shell 里手抠 JSON 是这些脚本历史 bug 的来源）
# ---------------------------------------------------------------------------

# 从 stdin 的 JSON 文本里取 ubus_rpc_session；拿不到就给空串。
sid_of() {
  python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read())
except Exception:
    print(""); raise SystemExit
if isinstance(d, list):                       # molly 的批量回包
    d = d[0] if d else {}
if isinstance(d, dict) and isinstance(d.get("result"), list) and len(d["result"]) > 1:
    d = d["result"][1] or {}                  # JSON-RPC 信封 → result[1]
print((d or {}).get("ubus_rpc_session", "") if isinstance(d, dict) else "")'
}

capture_device() {
  local host="$1"
  local out="$DIR"
  mkdir -p "$out/ubus" "$out/http"

  echo "== 设备 $host =="

  # root 会话：口径要求「两侧各带 root SID」，拿不到就明说（compare 会据此判失败）
  local sid=""
  if [[ -n "${MOLLY_DEVICE_PASS:-}" ]]; then
    sid="$(ssh "root@$host" \
      "ubus call session login '{\"username\":\"root\",\"password\":\"$MOLLY_DEVICE_PASS\"}'" \
      2>/dev/null | sid_of)"
  fi
  if [[ -n "$sid" ]]; then
    printf '%s\n' "$sid" >"$out/ubus/root-sid.txt"
    echo "  root 会话：${sid:0:8}…（每个探针都带 ubus_rpc_session）"
  else
    : >"$out/ubus/root-sid.txt"
    echo "  root 会话：**缺失**——设 MOLLY_DEVICE_PASS=<root 密码> 再抓；" >&2
    echo "    否则本次样本只能匿名，compare 会直接判失败（口径不成立）。" >&2
  fi

  ssh "root@$host" 'ubus -v list' >"$out/ubus/objects.txt" 2>&1
  ssh "root@$host" 'ubus -v list session uci file luci-rpc' >"$out/ubus/signatures.txt" 2>&1

  # 探针抓的是**原厂的 HTTP 面**（`/ubus/call/<obj>`），与 molly 侧同一层：
  # CLI（`ubus -v call`）不经 uhttpd 的 ACL，混用会产生假差异（见文件头 §1）。
  local auth=()
  if [[ -n "$sid" ]]; then
    auth=(-H "Authorization: Bearer $sid")
  fi
  local broken=""
  for p in "${PROBES[@]}"; do
    obj="${p%% *}"
    rest="${p#* }"
    method="${rest%% *}"
    params="${rest#* }"
    file="$out/ubus/$obj.$method.json"
    curl -sS -m 8 -X POST "${auth[@]}" \
      -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}" \
      "http://$host/ubus/call/$obj" >"$file" 2>&1
    printf '  device %s.%s -> %s\n' "$obj" "$method" "$(wc -c <"$file")"
    if grep -q '^curl: (' "$file" 2>/dev/null; then
      broken="$obj.$method"
      echo "  **设备侧在 $broken 处抓取失败（连接层）——后续样本无意义，停止**" >&2
      break
    fi
  done
  # 抓取中断的记号：compare 据此判「本次无效」，不会把一堆 connection refused 当差异
  if [[ -n "$broken" ]]; then
    printf '%s\n' "$broken" >"$out/ubus/_capture-broken.txt"
  else
    rm -f "$out/ubus/_capture-broken.txt"
  fi

  # ACL 与 rpcd 配置（P3-6 的对照物）
  ssh "root@$host" 'for f in /usr/share/rpcd/acl.d/*.json; do echo "===== $f"; cat "$f"; echo; done' \
    >"$out/acl.d.txt" 2>&1
  ssh "root@$host" 'cat /etc/config/rpcd' >"$out/rpcd.conf" 2>&1
  ssh "root@$host" 'ls -l /usr/lib/lib{uci,ubus,ubox,blobmsg_json}.so* /lib/ld-musl-aarch64.so.1' \
    >"$out/libs.txt" 2>&1
  ssh "root@$host" 'ucode -v; cat /etc/openwrt_release' >"$out/versions.txt" 2>&1

  # 登录原始回包也留一份（对比时可核会话形状；注意里面有 sid，别外传）
  if [[ -n "$sid" ]]; then
    ssh "root@$host" \
      "ubus call session login '{\"username\":\"root\",\"password\":\"$MOLLY_DEVICE_PASS\"}'" \
      >"$out/ubus/session.login.json" 2>&1
    echo "  （含 session.login，样本里有 sid，别外传）"
  fi

  # 原厂 uhttpd 的 HTTP 样本（P2 风险 R7 的校准物）
  for hp in "${HTTP_PROBES[@]}"; do
    url="${hp%% :: *}"
    name="${hp##* :: }"
    curl -sS -m 8 -D- -o /dev/null "http://$host$url" >"$out/http/$name.txt" 2>&1
  done
  echo "目录：$out"
}

capture_molly() {
  local base="$1"
  local out="$DIR"
  mkdir -p "$out/molly"

  # molly 侧同样要 root SID：MOLLY_SID 直接用，只有 MOLLY_PASS 时自己登录取一个。
  local sid="${MOLLY_SID:-}"
  if [[ -z "$sid" && -n "${MOLLY_PASS:-}" ]]; then
    sid="$(curl -sS -m 8 -X POST \
      -d '{"jsonrpc":"2.0","id":1,"method":"call","params":["00000000000000000000000000000000","session","login",{"username":"root","password":"'"$MOLLY_PASS"'"}]}' \
      "$base/ubus/" 2>/dev/null | sid_of)"
  fi
  if [[ -n "$sid" ]]; then
    printf '%s\n' "$sid" >"$out/molly/root-sid.txt"
    echo "  molly root 会话：${sid:0:8}…"
  else
    : >"$out/molly/root-sid.txt"
    echo "  molly root 会话：**缺失**——设 MOLLY_SID=<32hex> 或 MOLLY_PASS=<root 密码>；" >&2
    echo "    否则本次样本只能匿名，compare 会直接判失败（口径不成立）。" >&2
  fi

  local auth=()
  if [[ -n "$sid" ]]; then
    auth=(-H "Authorization: Bearer $sid")
  fi

  local broken=""
  for p in "${PROBES[@]}"; do
    obj="${p%% *}"
    rest="${p#* }"
    method="${rest%% *}"
    params="${rest#* }"
    file="$out/molly/$obj.$method.json"
    curl -sS -m 8 -X POST "${auth[@]}" \
      -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}" \
      "$base/ubus/call/$obj" >"$file" 2>&1
    printf '  molly %s.%s -> %s\n' "$obj" "$method" "$(wc -c <"$file")"
    # molly 崩了就是这个特征（curl 连不上/空回复）——立刻停下并记明崩点，
    # 否则后面全是一堆 connection refused，看着像「9 处差异」。
    if grep -q '^curl: (' "$file" 2>/dev/null; then
      broken="$obj.$method"
      echo "  **molly 在 $broken 处不可达（很可能崩了）——停止抓取**" >&2
      break
    fi
  done
  if [[ -n "$broken" ]]; then
    printf '%s\n' "$broken" >"$out/molly/_capture-broken.txt"
  else
    rm -f "$out/molly/_capture-broken.txt"
  fi
  echo "目录：$out"
}

capture_http() {
  local base="$1"
  local out="$DIR"
  # **单独一个目录**：原厂 uhttpd 的样本（capture_device 写的 http/）是 R7 的校准物，
  # 写进同一个目录会被 molly 这一侧覆盖掉（compare 又不比 HTTP，覆盖后无从查证）。
  mkdir -p "$out/http-molly"
  for hp in "${HTTP_PROBES[@]}"; do
    url="${hp%% :: *}"
    name="${hp##* :: }"
    curl -sS -m 8 -D- -o /dev/null "$base$url" >"$out/http-molly/$name.txt" 2>&1
    printf '  HTTP %s -> %s\n' "$url" "$name"
  done
  echo "目录：$out"
}

# 对比：两侧都先「剥信封 + 掩会话 id + 解析排序重排」再逐字段比。
# 归一化做三件事：
#   1. 剥信封——两侧都走 HTTP，所以都带 JSON-RPC 信封（取 result；只有 error 时归一成
#      __rpc-error__），形状因此严格同层（同时把 id 这类噪声抹掉）；
#   2. 掩会话 id——两侧各自登录，sid 必然不同，掩成 <sid> 免得成假差异；
#   3. 排序重排——rpcd 的 key 顺序是 blobmsg 插入序，molly 是 map 遍历序。
#
# 除 /ubus 探针外，还比一轮 **HTTP 面**（原厂 uhttpd :80 vs molly :8080），
# 覆盖 ADR 0003 T1 要锁的那些页面：只比状态码 + 契约头（见 norm_http 的白名单）。
compare() {
  local out="${1:-$DIR}"
  local fail=0

  if [[ ! -d "$out/ubus" || ! -d "$out/molly" ]]; then
    echo "缺少 $out/ubus 或 $out/molly（先跑 device 与 molly 两个动作）" >&2
    exit 2
  fi

  # 「两侧各带 root SID」是口径的一部分：缺任一侧，这次的「零差异」没有意义。
  if [[ ! -s "$out/ubus/root-sid.txt" || ! -s "$out/molly/root-sid.txt" ]]; then
    local miss=""
    [[ -s "$out/ubus/root-sid.txt" ]] || miss="$miss 设备侧"
    [[ -s "$out/molly/root-sid.txt" ]] || miss="$miss molly 侧"
    echo "两侧 root SID 不齐（缺：$miss）——本次对比不可用作判据。" >&2
    echo "  设备侧：MOLLY_DEVICE_PASS=<root 密码> ./tests/golden.sh device <host>" >&2
    echo "  molly 侧：MOLLY_SID=<32hex> 或 MOLLY_PASS=<root 密码> ./tests/golden.sh molly <base-url>" >&2
    exit 2
  fi

  # 抓取中途目标崩了 → 本次样本不完整，后续的 connection refused 不是「差异」。
  for side in ubus molly; do
    if [[ -s "$out/$side/_capture-broken.txt" ]]; then
      echo "$side 侧抓取中断于 $(cat "$out/$side/_capture-broken.txt")（目标崩了/不可达）——本次对比无效。" >&2
      echo "  修好崩溃后重抓再比；不要把中断后的 connection refused 当差异。" >&2
      exit 2
    fi
  done

  for f in "$out"/molly/*.json; do
    name="$(basename "$f")"
    dev="$out/ubus/$name"
    [[ -f "$dev" ]] || { echo "  跳过 $name（设备侧没有样本）"; continue; }

    if diff <(norm "$dev") <(norm "$f") >/tmp/golden-diff.txt 2>&1; then
      printf '  ok   %-34s\n' "$name"
    else
      printf '  DIFF %-34s\n' "$name"
      sed 's/^/       /' /tmp/golden-diff.txt | head -20
      fail=$((fail + 1))
    fi
  done

  # HTTP 面：原厂 uhttpd(:80) vs molly(:8080)。比的是「契约头」——状态码 + 白名单头名；
  # 不稳定或实现固有的头（Date / Server / Content-Length / 连接类 / Etag …）在 norm_http
  # 里剔除（这些差异是替换层固有的，见 docs/testing.md §7.1 的头对照一节）。
  if [[ -d "$out/http" && -d "$out/http-molly" ]]; then
    echo
    echo "== HTTP 面（原厂 uhttpd vs molly）=="
    for f in "$out"/http/*.txt; do
      name="$(basename "$f")"
      m="$out/http-molly/$name"
      [[ -f "$m" ]] || { echo "  跳过 $name（molly 侧没有样本）"; continue; }
      if diff <(norm_http "$f") <(norm_http "$m") >/tmp/golden-diff-http.txt 2>&1; then
        printf '  ok   %-34s\n' "$name"
      else
        printf '  DIFF %-34s\n' "$name"
        sed 's/^/       /' /tmp/golden-diff-http.txt | head -20
        fail=$((fail + 1))
      fi
    done
  fi

  echo
  echo "对比完成：/ubus $(find "$out/molly" -name '*.json' | wc -l) 对 + HTTP $(find "$out/http" -name '*.txt' 2>/dev/null | wc -l) 对，差异 $fail 处"
  [[ "$fail" -eq 0 ]]
}

# HTTP 头归一化：从 `curl -D-` 的转储里取出「契约头」。
#   - 只要状态**码**，不要原因短语（uhttpd 与 molly 的文案不同，属已知固有差异）；
#   - 剔除 Date / Server / Content-Length / 连接类 / Etag 等不稳定或实现固有的头；
#   - set-cookie 掩掉会话名与 sid（两侧 cookie 名按设计不同、sid 必然不同）；
#   - 头名**一律小写**后比较：HTTP 头名大小写不属契约（实测 uhttpd 自己都不统一——对
#     页面响应发 `content-type:`、对静态发 `Content-Type:`）。字节级大小写契约另由
#     tests/device_smoke.sh §2 的 header_line 断言负责，不在这里叠。
# 不做请求、不比对正文：登录页与页面壳里含随机 authtoken/sessionid，逐字节不可比；
# 正文的逐字节契约由 /ubus 探针负责。
norm_http() {
  python3 -c '
import re, sys

SKIP = {"date", "server", "content-length", "connection", "keep-alive",
        "transfer-encoding", "etag", "last-modified", "vary", "accept-ranges",
        "proxy-connection", "content-encoding"}

def mask(v):
    v = re.sub(r"\bsysauth_[A-Za-z0-9_]+=", "sysauth_*=", v)
    v = re.sub(r"\b[0-9a-fA-F]{32}\b", "<sid>", v)
    v = re.sub(r"authtoken[=:]\s*[^;,\s]+", "authtoken=<token>", v)
    return v

raw = open(sys.argv[1], encoding="utf-8", errors="replace").read()
if not raw.strip().upper().startswith("HTTP/"):
    print("<<not an http header dump>>")
    print(raw.strip()[:200])
    raise SystemExit

code = ""
hdrs = {}
for i, line in enumerate(raw.replace("\r\n", "\n").split("\n")):
    if i == 0:
        parts = line.split()
        code = parts[1] if len(parts) >= 2 else line.strip()
        continue
    if not line.strip() or ":" not in line:
        continue
    name, value = line.split(":", 1)
    name = name.strip()
    lname = name.lower()
    if lname in SKIP:
        continue
    hdrs.setdefault(lname, []).append(mask(value.strip()))

print("status=%s" % code)
for name in sorted(hdrs):
    for v in hdrs[name]:
        print("%s: %s" % (name, v))
' "$1"
}

# JSON 归一化（剥信封 + 掩 sid + 排序重排；不能解析就原样输出——那时 diff 会显式暴露问题）
norm() {
  python3 -c '
import json, sys

def strip_envelope(d):
    """带 jsonrpc 的对象是信封：取 result；只有 error 时归一成可比形状。"""
    if isinstance(d, dict) and d.get("jsonrpc") == "2.0":
        if "result" in d:
            return d["result"]
        e = d.get("error") or {}
        return {"__rpc-error__": {"code": e.get("code"), "message": e.get("message")}}
    return d

def mask_sid(o):
    """会话 id 两侧必然不同，掩掉；其余原样（保持类型与嵌套）。"""
    if isinstance(o, dict):
        return {k: ("<sid>" if k in ("ubus_rpc_session", "sid") else mask_sid(v))
                for k, v in o.items()}
    if isinstance(o, list):
        return [mask_sid(v) for v in o]
    return o

raw = open(sys.argv[1], encoding="utf-8", errors="replace").read()
try:
    d = json.loads(raw)
except Exception as e:
    print("<<not json: %s>>" % e)
    print(raw)
else:
    print(json.dumps(mask_sid(strip_envelope(d)), sort_keys=True,
                     ensure_ascii=False, indent=1))
' "$1"
}

case "$ACTION" in
device) capture_device "$HOST" ;;
molly) capture_molly "$HOST" ;;
http) capture_http "$HOST" ;;
compare) compare "${1:-$DIR}" ;;
*)
  sed -n '2,20p' "$0" | sed 's/^# //; s/^#//'
  exit 1
  ;;
esac
