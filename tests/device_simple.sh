#!/usr/bin/env bash
# 设备验收（黑盒）：**简洁版 /lite** —— 只走 HTTP，与实现无关。
#
# 覆盖 2026-10-09 的诉求「测一下简洁版各操作是否正常使用」：把 /lite 单页应用真正会打的
# 请求，逐条以浏览器形态（旧式 JSON-RPC `method:"call", params:[SID,obj,m,p]`）复现并断言。
#
#   MOLLY_DEVICE_PASS=xxx ./molly/tests/device_simple.sh            # 默认 http://192.168.1.1:8080
#   MOLLY_DEVICE_PASS=xxx ./molly/tests/device_simple.sh http://127.0.0.1:8080
#   MOLLY_SIMPLE_CONC=40 MOLLY_DEVICE_PASS=xxx ./molly/tests/device_simple.sh
#
# 覆盖：
#   A) 路由与外壳：`/` → 302 到 /lite/；/lite 前缀下任意路径都 200 出同一份 SPA（深链/刷新）；
#      SPA 里 `__CFG__` 已被替换、注入了 sid/menu/expert；对 /lite 的 POST → 405（登录不在这里）。
#   B) 认证面 /auth：错口令 302 带 auth_error 且不下发会话；GET /auth/login → 404（只接 POST）；
#      正确口令 302 + Set-Cookie sysauth_molly=<32 hex>。
#   C) 各页面读操作（登录态 SID）全 ret=0 且返回形状对得上：
#      dash/system、network、wifi、dhcp、log、disk、svc、diag、bk 每页首屏的 ubus 调用。
#   D) ACL 兜底：匿名读被拒；root 读 /etc/shadow 被拒；root 往 /tmp 写被拒（写路径接通且受限）。
#   E) 并发：GET /lite/ 与并发 uci.get 不得 503（连接悬崖/崩进程在这里被抓）。
#   F) 退出：/auth/logout 302 清 cookie；登出后旧 SID 再读被拒（会话已销毁）。
#
# **不在活设备上做的**（有破坏性，写逻辑另由宿主 tests/smoke.sh 覆盖）：
#   真 uci set/commit/apply、network.reload、服务 start/stop/restart、system.reboot、/auth/password。
#
# 失败数不为 0 时脚本退出码非 0。
set -uo pipefail

BASE="${1:-${MOLLY_BASE:-http://192.168.1.1:8080}}"
USER_NAME="${MOLLY_DEVICE_USER:-root}"
: "${MOLLY_DEVICE_PASS:?需要 MOLLY_DEVICE_PASS=<root 密码>（脚本要真的走一遍 /auth/login）}"
CONC="${MOLLY_SIMPLE_CONC:-30}"
LITE="/lite"

PASS=0
FAIL=0
check() { # $1=名字 $2=期望 $3=实际
  if [[ "$2" == "$3" ]]; then
    PASS=$((PASS + 1))
    printf '  ok   %-50s\n' "$1"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL %-50s 期望=[%s] 实际=[%s]\n' "$1" "$2" "$3"
  fi
}
# http_code：只取状态码
code() { curl -s -o /dev/null -m 20 -w '%{http_code}' "$@" 2>/dev/null; }
# hdr_of：取某个响应头（大小写不敏感，去 CR）
hdr_of() { curl -s -i -m 20 "$@" 2>/dev/null | tr -d '\r'; }

echo "== A. 路由与 SPA 外壳 =="
# 字符串包含一律用 bash 的 [[ == *needle* ]]：`printf 大字符串 | grep -q` 在 set -o pipefail
# 下会踩 SIGPIPE（grep -q 命中即关管道、printf 尚未写完退 141），SPA 那份大 HTML 会因此误判。
h="$(hdr_of "$BASE/")"
loc="$(printf '%s' "$h" | awk -F': ' 'tolower($1)=="location"{print $2}' | head -1)"
ct="$(printf '%s' "$(hdr_of "$BASE$LITE/")" | awk -F': ' 'tolower($1)=="content-type"{print tolower($2)}')"
shell_body="$(curl -s -m 20 "$BASE$LITE/" 2>/dev/null)"
check "GET / 状态码" "302" "$(printf '%s' "$h" | awk 'NR==1{print $2}')"
check "GET / 跳向 /lite/" "/lite/" "$loc"
check "GET /lite 状态码" "200" "$(code "$BASE$LITE")"
check "GET /lite/ 状态码" "200" "$(code "$BASE$LITE/")"
check "GET /lite/ 内容类型含 text/html" "yes" "$([[ "$ct" == *text/html* ]] && echo yes || echo no)"
check "外壳已替换 __CFG__ 占位符" "no" "$([[ "$shell_body" == *__CFG__* ]] && echo yes || echo no)"
check "外壳注入菜单（含 dash 与 bk）" "yes" \
  "$([[ "$shell_body" == *'"id":"dash"'* && "$shell_body" == *'"id":"bk"'* ]] && echo yes || echo no)"
check "外壳未登录时注入空 sid" "yes" "$([[ "$shell_body" == *'"sid":""'* ]] && echo yes || echo no)"
check "深链 /lite/net 也 200（同一份 SPA）" "200" "$(code "$BASE$LITE/net")"
check "对 /lite/ 的 POST → 405（登录不在这里）" "405" "$(code -X POST "$BASE$LITE/")"

echo "== B. 认证面 /auth =="
check "GET /auth/login → 404（只接 POST）" "404" "$(code "$BASE/auth/login")"
bad="$(hdr_of -X POST "$BASE/auth/login" --data-urlencode "username=$USER_NAME" --data-urlencode "password=__definitely_wrong__")"
check "错口令登录状态码" "302" "$(printf '%s' "$bad" | awk 'NR==1{print $2}')"
check "错口令跳转带 auth_error" "yes" \
  "$(printf '%s' "$bad" | awk -F': ' 'tolower($1)=="location"{print $2}' | grep -q 'auth_error' && echo yes || echo no)"
check "错口令不下发有效会话 cookie" "no" \
  "$(printf '%s' "$bad" | grep -qiE 'set-cookie: *sysauth_molly=[0-9a-fA-F]{6,}' && echo yes || echo no)"

login="$(hdr_of -X POST "$BASE/auth/login" --data-urlencode "username=$USER_NAME" --data-urlencode "password=$MOLLY_DEVICE_PASS")"
check "正确口令登录状态码" "302" "$(printf '%s' "$login" | awk 'NR==1{print $2}')"
SID="$(printf '%s' "$login" | grep -iE 'set-cookie:' | tr -d '\r' \
        | grep -oE 'sysauth_molly=[0-9a-fA-F]+' | head -1 | cut -d= -f2)"
check "Set-Cookie 有 sysauth_molly=<32 hex>" "yes" \
  "$([[ "$SID" =~ ^[0-9a-fA-F]{32}$ ]] && echo yes || echo no)"
if [[ -z "$SID" ]]; then
  echo "  拿不到会话 SID —— 后续读操作会全失败，先排查 /auth/login 与 rpcd 会话" >&2
fi

# C/D/E 交给 python：JSON 与并发在 shell 里写不可靠。
results="$(BASE="$BASE" SID="$SID" CONC="$CONC" python3 - <<'PY'
import json, os, subprocess, concurrent.futures
from collections import Counter

BASE = os.environ["BASE"]
SID = os.environ["SID"]
CONC = int(os.environ["CONC"])
ANON = "00000000000000000000000000000000"
rows = []

def curl(args, timeout="30"):
    return subprocess.run(["curl", "-s", "-k", "--max-time", timeout] + args,
                          capture_output=True, text=True).stdout

def row(name, expect, actual):
    rows.append("%s\t%s\t%s" % (name, expect, str(actual).replace("\t", " ")))

def rpc(sid, obj, meth, params):
    """浏览器形态的旧式单调用；返回 (ok, tag, data)。ok=RPC 且 ret==0。"""
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "call",
                       "params": [sid, obj, meth, params]})
    raw = curl(["-X", "POST", BASE + "/ubus/", "-H", "Content-Type: application/json", "-d", body])
    try:
        d = json.loads(raw)
        d = d[0] if isinstance(d, list) else d
    except Exception:
        return (False, "非JSON", None)
    if not isinstance(d, dict):
        return (False, "非对象", None)
    if "error" in d:
        return (False, "err=%s" % (d.get("error") or {}).get("code"), None)
    r = d.get("result")
    if isinstance(r, list) and r and r[0] == 0:
        return (True, "ret=0", r[1] if len(r) > 1 else {})
    return (False, "ret=%s" % (r[0] if isinstance(r, list) else "?"), None)

def ok_read(name, obj, meth, params, key=None):
    ok, tag, data = rpc(SID, obj, meth, params)
    detail = tag
    if ok and key is not None:
        has = isinstance(data, dict) and key in data
        detail = "ret=0 含%s" % key if has else "ret=0 缺%s(keys=%s)" % (key, list(data)[:6] if isinstance(data, dict) else type(data).__name__)
        ok = ok and has
    row(name, "yes", "yes" if ok else "no(%s)" % detail)

def ok_denied(name, sid, obj, meth, params):
    ok, tag, _ = rpc(sid, obj, meth, params)
    row(name, "denied", "denied" if not ok else "误放行(%s)" % tag)

# --- C. 各页面读操作（登录态） ---
ok_read("dash  system.info", "system", "info", {}, "uptime")
ok_read("dash  system.board", "system", "board", {}, "hostname")
ok_read("dash  uci.get network", "uci", "get", {"config": "network"}, "values")
ok_read("dash  uci.get dhcp", "uci", "get", {"config": "dhcp"}, "values")
ok_read("net   uci.get wireless", "uci", "get", {"config": "wireless"}, "values")
ok_read("wifi  luci-rpc.getWirelessDevices", "luci-rpc", "getWirelessDevices", {})
ok_read("dhcp  luci-rpc.getDHCPLeases", "luci-rpc", "getDHCPLeases", {"family": 0}, "dhcp_leases")
ok_read("log   log.read", "log", "read", {"stream": False, "lines": 20})
ok_read("disk  file.read /proc/mounts", "file", "read", {"path": "/proc/mounts"}, "data")
ok_read("disk  file.exec /bin/df", "file", "exec", {"command": "/bin/df", "params": ["-k"]}, "stdout")
ok_read("svc   file.list /etc/rc.d", "file", "list", {"path": "/etc/rc.d"}, "entries")
ok_read("diag  file.exec /bin/ping(环回)", "file", "exec", {"command": "/bin/ping", "params": ["-c", "1", "127.0.0.1"]}, "code")
ok_read("bk    file.list /etc/config", "file", "list", {"path": "/etc/config"}, "entries")
ok_read("bk    file.read /etc/config/network", "file", "read", {"path": "/etc/config/network"}, "data")

# --- D. ACL 兜底 ---
ok_denied("匿名 uci.get network 被拒", ANON, "uci", "get", {"config": "network"})
ok_denied("root 读 /etc/shadow 被拒（不在 allowlist）", SID, "file", "read", {"path": "/etc/shadow"})
ok_denied("root 往 /tmp 写被拒（write 未放行 /tmp）", SID, "file", "write",
          {"path": "/tmp/molly_bk_probe.txt", "data": "probe\n", "mode": 420})

# --- E. 并发 ---
def one_get(_):
    return curl(["-o", "/dev/null", "-w", "%{http_code}", BASE + "/lite/"]).strip()
with concurrent.futures.ThreadPoolExecutor(max_workers=CONC) as ex:
    codes = list(ex.map(one_get, range(CONC)))
c = Counter(codes)
row("%d 并发 GET /lite/ 出现 503" % CONC, "0", str(c.get("503", 0)))
row("%d 并发 GET /lite/ 全部 200" % CONC, "yes", "yes" if c.get("200", 0) == CONC else str(dict(c)))

def one_rpc(_):
    ok, _, _ = rpc(SID, "uci", "get", {"config": "network"})
    return ok
with concurrent.futures.ThreadPoolExecutor(max_workers=CONC) as ex:
    oks = list(ex.map(one_rpc, range(CONC)))
row("%d 并发 uci.get 全部 ret=0" % CONC, "yes", "yes" if all(oks) else "%d/%d" % (sum(oks), CONC))

for r in rows:
    print(r)
PY
)"

while IFS=$'\t' read -r name expect actual; do
  [[ -n "$name" ]] || continue
  check "$name" "$expect" "$actual"
done <<<"$results"

echo "== F. 退出 =="
if [[ -n "$SID" ]]; then
  out="$(hdr_of -X POST "$BASE/auth/logout" -H "Cookie: sysauth_molly=$SID")"
  check "登出状态码" "302" "$(printf '%s' "$out" | awk 'NR==1{print $2}')"
  check "登出清 cookie（空值 sysauth_molly）" "yes" \
    "$(printf '%s' "$out" | grep -iE 'set-cookie:' | tr -d '\r' | grep -q 'sysauth_molly=;' && echo yes || echo no)"
  # 旧 SID 应已失效：会话被 destroy（桥接态落在 rpcd）。
  after="$(curl -s -m 20 -X POST "$BASE/ubus/" -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"call\",\"params\":[\"$SID\",\"uci\",\"get\",{\"config\":\"network\"}]}" 2>/dev/null)"
  check "登出后旧 SID 再读被拒" "denied" \
    "$(printf '%s' "$after" | grep -qE '"error"|\"result\":\[[1-9]' && echo denied || echo "误放行")"
else
  echo "  跳过 F：没有有效 SID"
fi

echo
echo "通过 ${PASS}，失败 ${FAIL}"
[[ "$FAIL" -eq 0 ]] || exit 1
