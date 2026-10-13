#!/usr/bin/env bash
# 设备验收（**对照基准**）：molly 以 T1 桥接把专家版前缀交给设备 ucode 渲染（ADR 0003）。
#
# 只走 HTTP，**与实现无关**：无论专家版渲染内置在 Odin dispatcher 还是交设备 ucode 桥接，
# 都用同一份脚本验收——
# 前提是目标以「T1 形态」起：`--luci-cgi "<ucode> <CGI 兜底脚本>"`（可选 `--ubus-socket`）。
#
#   MOLLY_DEVICE_PASS=xxx ./tests/device_luci.sh            # 默认 http://192.168.1.1:8080
#   MOLLY_DEVICE_PASS=xxx ./tests/device_luci.sh http://192.168.1.1:8080
#
#   专家版前缀由部署给（别写死）：MOLLY_LUCI_PREFIX=挂载前缀（默认 /cgi-bin/luci，
#   本站 /admin）；MOLLY_LUCI_SUB=前缀之后 URL 里那段（默认 /admin，配 --luci-strip admin
#   的站给空串）。本机部署（/admin + strip admin）：
#     MOLLY_DEVICE_PASS=xxx MOLLY_LUCI_PREFIX=/admin MOLLY_LUCI_SUB= \
#       ./tests/device_luci.sh
#
# 覆盖（对应 2026-10-07 的真机验收记录）：
#   0) 未登录：$LUCI/ 必须 403 + `x-luci-login-required: yes`
#   1) 表单登录：302 + Set-Cookie（sysauth_*）
#
# 注：专家版的目标形态是内置 Odin dispatcher（用 Odin 重写的 LuCI），不是这条 ucode 桥接；
# 本脚本留着是为了拿原版行为当基准。前缀由部署给（本站 /admin），别写死。
#   2) 9 个页面全 200 且不再要求登录
#   3) 5 个静态资源全 200
#   4) 6 条首屏 RPC 全 ret=0
#   5) 12 条浏览器形态批量：合法 JSON 且条目数对齐（原 "No related RPC reply" 场景）
#   6) 并发页面（默认 40）：不得出现 503（连接悬崖/崩进程都会被这里抓到）
#
# 失败数不为 0 时脚本退出码非 0。
set -uo pipefail

BASE="${1:-${MOLLY_BASE:-http://192.168.1.1:8080}}"
USER_NAME="${MOLLY_DEVICE_USER:-root}"
: "${MOLLY_DEVICE_PASS:?需要 MOLLY_DEVICE_PASS=<root 密码>（脚本要真的走一遍表单登录）}"
CONC="${MOLLY_LUCI_CONC:-40}"
# 专家版前缀由部署给（见文件头）：LUCI=挂载前缀，SUB=前缀之后 URL 里那段（strip 站给空串）。
LUCI="${MOLLY_LUCI_PREFIX:-/cgi-bin/luci}"
SUB="${MOLLY_LUCI_SUB-/admin}"   # 用 `-` 而非 `:-`：显式空串表示 strip 已把那段折叠进前缀

PASS=0
FAIL=0
check() { # $1=名字 $2=期望 $3=实际
  if [[ "$2" == "$3" ]]; then
    PASS=$((PASS + 1))
    printf '  ok   %-48s\n' "$1"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL %-48s 期望=[%s] 实际=[%s]\n' "$1" "$2" "$3"
  fi
}

echo "== 0. 未登录：登录判定 =="
hdr="$(curl -s -i -m 20 "$BASE$LUCI/" 2>&1)"
check "GET $LUCI/ 状态码" "403" "$(printf '%s' "$hdr" | awk 'NR==1{print $2}')"
check "登录提示头 x-luci-login-required" "yes" \
  "$(printf '%s' "$hdr" | awk -F': ' 'tolower($1)=="x-luci-login-required"{print $2}' | tr -d '\r' | head -1)"

echo "== 1. 表单登录 =="
login="$(curl -s -i -m 25 -X POST "$BASE$LUCI/" \
  --data-urlencode "luci_username=$USER_NAME" --data-urlencode "luci_password=$MOLLY_DEVICE_PASS" 2>&1)"
check "登录状态码" "302" "$(printf '%s' "$login" | awk 'NR==1{print $2}')"
cookie="$(printf '%s' "$login" | awk -F': ' 'tolower($1)=="set-cookie"{print $2}' | tr -d '\r' | head -1)"
COOKIE_PAIR="$(printf '%s' "$cookie" | awk -F';' '{print $1}')"
if [[ -z "$COOKIE_PAIR" ]]; then
  echo "  没拿到 Set-Cookie——密码错或桥接没把响应头透传出来" >&2
fi
check "Set-Cookie 是 sysauth_*" "yes" \
  "$([[ "$cookie" =~ sysauth_ ]] && echo yes || echo no)"

# 后面几节的断言全交给 python：JSON 与并发在 shell 里写不可靠。
results="$(BASE="$BASE" COOKIE="$COOKIE_PAIR" CONC="$CONC" RPC_PASS="$MOLLY_DEVICE_PASS" LUCI="$LUCI" SUB="$SUB" python3 - <<'PY'
import json, os, subprocess, concurrent.futures
from collections import Counter

BASE = os.environ["BASE"]
COOKIE = os.environ["COOKIE"]
CONC = int(os.environ["CONC"])
RPC_PASS = os.environ["RPC_PASS"]
LUCI = os.environ["LUCI"]
SUB = os.environ["SUB"]
rows = []

def curl(args, timeout="30"):
    return subprocess.run(["curl", "-s", "-k", "--max-time", timeout] + args,
                          capture_output=True, text=True).stdout

def row(name, expect, actual):
    rows.append("%s\t%s\t%s" % (name, expect, str(actual).replace("\t", " ")))

# --- 2. 页面 ---
# 前缀 + strip 折算出的实际 URL：根 = <LUCI>/，子页 = <LUCI><SUB>/<rel>
root = LUCI.rstrip("/") + "/"
sub = LUCI.rstrip("/") + SUB
pages = [root,
         sub + "/status/overview", sub + "/network/network", sub + "/network/wireless",
         sub + "/system/system", sub + "/status/routes",
         sub + "/status/logs", sub + "/system/admin",
         sub + "/network/dhcp"]
for p in pages:
    curl(["-o", "/tmp/dluci.html", "-D", "/tmp/dluci.h", "-H", "Cookie: " + COOKIE, BASE + p])
    code = curl(["-o", "/dev/null", "-w", "%{http_code}", "-H", "Cookie: " + COOKIE, BASE + p]).strip()
    h = open("/tmp/dluci.h", errors="ignore").read().lower()
    body = open("/tmp/dluci.html", errors="ignore").read()
    row("页面 " + p, "200", code)
    row("不再要求登录 " + p, "no", "yes" if "x-luci-login-required" in h else "no")
    row("页面非空 " + p, "yes", "yes" if len(body) > 200 else "no-but-%d-bytes" % len(body))

# --- 3. 静态资源 ---
for f in ["/luci-static/resources/luci.js", "/luci-static/resources/ui.js",
          "/luci-static/resources/view/status/index.js",
          "/luci-static/bootstrap-light/cascade.css", "/luci-static/resources/cbi.js"]:
    code = curl(["-o", "/dev/null", "-w", "%{http_code}", "-H", "Cookie: " + COOKIE, BASE + f]).strip()
    row("静态 " + f, "200", code)

# --- 4. 首屏 RPC ---
ANON = "00000000000000000000000000000000"

def call(params):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "call", "params": params})
    out = curl(["-X", "POST", BASE + "/ubus/", "-H", "Content-Type: application/json", "-d", body])
    try:
        d = json.loads(out)
        d = d[0] if isinstance(d, list) else d
        r = d.get("result")
        if isinstance(r, list):
            return "ret=%s" % r[0]
        return "error=%s" % (d.get("error") or {}).get("code")
    except Exception:
        return "非JSON"

sid = ""
try:
    d = json.loads(curl(["-X", "POST", BASE + "/ubus/", "-d",
        '{"jsonrpc":"2.0","id":1,"method":"call","params":["%s","session","login",{"username":"root","password":"%s"}]}'
        % (ANON, RPC_PASS)]))
    d = d[0] if isinstance(d, list) else d
    sid = d["result"][1]["ubus_rpc_session"]
except Exception:
    pass
row("session login（RPC 侧）", "yes", "yes" if sid else "no")
USE = sid or ANON
for obj, meth, p in [("session", "access", {"scope": "uci", "object": "luci", "function": "read"}),
                     ("session", "get", {}), ("luci", "getFeatures", {}),
                     ("luci-rpc", "getBoardJSON", {}), ("luci-rpc", "getNetworkDevices", {}),
                     ("system", "board", {})]:
    row("RPC %s.%s" % (obj, meth), "ret=0", call([USE, obj, meth, p]))

# --- 5. 12 条批量（浏览器形态） ---
calls = [("session", "access", {"scope": "uci", "object": "luci", "function": "read"}),
         ("session", "get", {}), ("luci", "getFeatures", {}), ("uci", "get", {"config": "network"}),
         ("luci-rpc", "getBoardJSON", {}), ("luci-rpc", "getHostHints", {}),
         ("luci-rpc", "getNetworkDevices", {}), ("luci-rpc", "getWirelessDevices", {}),
         ("system", "board", {}), ("network.interface", "dump", {}),
         ("file", "list", {"path": "/etc/init.d"}), ("file", "read", {"path": "/etc/config/network"})]
batch = [{"jsonrpc": "2.0", "id": i + 1, "method": "call", "params": [USE, o, m, p]}
         for i, (o, m, p) in enumerate(calls)]
raw = curl(["-X", "POST", BASE + "/ubus/", "-H", "Content-Type: application/json",
            "-d", json.dumps(batch)])
try:
    d = json.loads(raw)
    row("批量条目数", str(len(calls)), str(len(d)) if isinstance(d, list) else "非数组")
    if isinstance(d, list):
        # 每条都必须有 result 或 error（缺任何一条就是当年那个 "No related RPC reply"）
        missing = [i for i, e in enumerate(d) if not isinstance(e, dict) or
                   ("result" not in e and "error" not in e)]
        row("批量每条都有 result/error", "0", str(len(missing)))
except Exception:
    row("批量是合法 JSON", "yes", "no")

# --- 6. 并发（不得出现 503） ---
def one(_):
    return curl(["-o", "/dev/null", "-w", "%{http_code}", "-H", "Cookie: " + COOKIE,
                 BASE + sub + "/status/overview"]).strip()
with concurrent.futures.ThreadPoolExecutor(max_workers=CONC) as ex:
    codes = list(ex.map(one, range(CONC)))
c = Counter(codes)
row("%d 并发页面出现 503" % CONC, "0", str(c.get("503", 0)))
row("%d 并发页面全部 200" % CONC, "yes", "yes" if c.get("200", 0) == CONC else str(dict(c)))

for r in rows:
    print(r)
PY
)"

while IFS=$'\t' read -r name expect actual; do
  [[ -n "$name" ]] || continue
  check "$name" "$expect" "$actual"
done <<<"$results"

echo
echo "通过 ${PASS}，失败 ${FAIL}"
[[ "$FAIL" -eq 0 ]] || exit 1
