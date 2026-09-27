#!/usr/bin/env bash
# 真机 golden 抓取与对比（P3-0 取证 / P3-9 收尾的「真机回归」那一项）。
#
# 为什么单独一个脚本：golden 对比是**替换前**的最后一关——rpcd 的响应与 molly 的响应
# 必须逐字段对得上，而且样本要可复现（谁都能重抓、谁都能重跑对比）。
#
# 三个动作：
#   ./tests/golden.sh device <host>        # ssh root@<host>：抓设备上的契约样本
#   ./tests/golden.sh molly  <base-url>    # 抓 molly 的 /ubus 响应（同一批探针）
#   ./tests/golden.sh http   <base-url>    # 抓 HTTP 层样本（原厂 uhttpd 或 molly 都行）
#   ./tests/golden.sh compare <dir>        # 对比 <dir>/ubus 与 <dir>/molly 的每对样本
#
# 产物目录：.ai-memory/golden/<yyyy-mm-dd>/（可用 GOLDEN_DIR 覆盖）
#
# 设备侧需要：ssh 免密（或 ssh-agent）、ubus、uci。登录探针需要密码：
#   MOLLY_DEVICE_PASS=xxx ./tests/golden.sh device 192.168.1.1
# molly 侧需要：一个已登录会话（可选），用它跑需要 ACL 的方法：
#   MOLLY_SID=<32hex> ./tests/golden.sh molly http://192.168.1.1:8081
set -uo pipefail
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

capture_device() {
  local host="$1"
  local out="$DIR"
  mkdir -p "$out/ubus" "$out/http"

  echo "== 设备 $host =="

  ssh "root@$host" 'ubus -v list' >"$out/ubus/objects.txt" 2>&1
  ssh "root@$host" 'ubus -v list session uci file luci-rpc' >"$out/ubus/signatures.txt" 2>&1

  for p in "${PROBES[@]}"; do
    obj="${p%% *}"
    rest="${p#* }"
    method="${rest%% *}"
    params="${rest#* }"
    file="$out/ubus/$obj.$method.json"
    ssh "root@$host" "ubus -v call $obj $method '$params'" >"$file" 2>&1
    printf '  ubus call %s %s -> %s\n' "$obj" "$method" "$(wc -c <"$file")"
  done

  # ACL 与 rpcd 配置（P3-6 的对照物）
  ssh "root@$host" 'for f in /usr/share/rpcd/acl.d/*.json; do echo "===== $f"; cat "$f"; echo; done' \
    >"$out/acl.d.txt" 2>&1
  ssh "root@$host" 'cat /etc/config/rpcd' >"$out/rpcd.conf" 2>&1
  ssh "root@$host" 'ls -l /usr/lib/lib{uci,ubus,ubox,blobmsg_json}.so* /lib/ld-musl-aarch64.so.1' \
    >"$out/libs.txt" 2>&1
  ssh "root@$host" 'ucode -v; cat /etc/openwrt_release' >"$out/versions.txt" 2>&1

  # 登录探针（可选）：拿到 sid 才能跑需要 ACL 的方法
  if [[ -n "${MOLLY_DEVICE_PASS:-}" ]]; then
    ssh "root@$host" \
      "ubus call session login '{\"username\":\"root\",\"password\":\"$MOLLY_DEVICE_PASS\"}'" \
      >"$out/ubus/session.login.json" 2>&1
    echo "  （含 session.login，注意样本里有 sid 之外的会话数据，别外传）"
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

  local auth=()
  if [[ -n "${MOLLY_SID:-}" ]]; then
    auth=(-H "Authorization: Bearer $MOLLY_SID")
  fi

  for p in "${PROBES[@]}"; do
    obj="${p%% *}"
    rest="${p#* }"
    method="${rest%% *}"
    params="${rest#* }"
    curl -sS -m 8 -X POST "${auth[@]}" \
      -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}" \
      "$base/ubus/call/$obj" >"$out/molly/$obj.$method.json" 2>&1
    printf '  molly %s.%s -> %s\n' "$obj" "$method" "$(wc -c <"$out/molly/$obj.$method.json")"
  done
  echo "目录：$out"
}

capture_http() {
  local base="$1"
  local out="$DIR"
  mkdir -p "$out/http"
  for hp in "${HTTP_PROBES[@]}"; do
    url="${hp%% :: *}"
    name="${hp##* :: }"
    curl -sS -m 8 -D- -o /dev/null "$base$url" >"$out/http/$name.txt" 2>&1
    printf '  HTTP %s -> %s\n' "$url" "$name"
  done
  echo "目录：$out"
}

# 对比：把两边的 JSON 都过一遍「解析 → 排序 → 重排」再逐字段比。
# 之所以先归一化：rpcd 的 key 顺序是 blobmsg 的插入序，molly 是 map 遍历序，
# 直接 diff 文本会得到一堆假差异。
compare() {
  local out="${1:-$DIR}"
  local fail=0

  if [[ ! -d "$out/ubus" || ! -d "$out/molly" ]]; then
    echo "缺少 $out/ubus 或 $out/molly（先跑 device 与 molly 两个动作）" >&2
    exit 2
  fi

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

  echo
  echo "对比完成：$(find "$out/molly" -name '*.json' | wc -l) 对，差异 $fail 处"
  [[ "$fail" -eq 0 ]]
}

# JSON 归一化（能解析就排序重排，不能解析就原样输出——那时 diff 会显式暴露问题）
norm() {
  python3 -c '
import json,sys
try:
    d = json.load(open(sys.argv[1]))
    print(json.dumps(d, sort_keys=True, ensure_ascii=False, indent=1))
except Exception as e:
    print("<<not json: %s>>" % e)
    print(open(sys.argv[1]).read())
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
