#!/usr/bin/env bash
# molly 验收：起本机服务，curl 断言路由、静态文件、/ubus 的 JSON-RPC 信封，
# 以及 /cgi-bin/luci 的 dispatcher（菜单树 / depends / ACL 裁树 / 登录提示）与
# CGI 子进程桥。
#
# 对应 Odin 版的 tests/http_smoke.sh + tests/cgi_smoke.sh（合并成一份）。
# 失败数不为 0 时脚本退出码非 0。
set -uo pipefail
cd "$(dirname "$0")/.."

PORT="${PORT:-18080}"
# CGI 桥用 5 个桩脚本，各自一个实例（对应 Odin 版 tests/cgi_smoke.sh）：echo 环境与
# body、status 头透传、broken 无输出退出码、noctype 缺 Content-Type、sizeprobe 64KB body。
CGI_PORT="${CGI_PORT:-18081}"
CGI2_PORT="${CGI2_PORT:-18082}"
CGI3_PORT="${CGI3_PORT:-18083}"
CGI4_PORT="${CGI4_PORT:-18084}"
CGI5_PORT="${CGI5_PORT:-18085}"
BIN=build/molly-host
# 仓库根 = 本脚本所在目录的上一级（脚本在 tests/ 下）。写死 "cd .." 只在「脚本位于
# 仓库根的子目录里」时成立，一旦仓库结构变了就会指到别处。
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOCROOT="$ROOT/tests/fixtures/www"
BASE="http://127.0.0.1:$PORT"
CGI_BASE="http://127.0.0.1:$CGI_PORT"
CGI2_BASE="http://127.0.0.1:$CGI2_PORT"
CGI3_BASE="http://127.0.0.1:$CGI3_PORT"
CGI4_BASE="http://127.0.0.1:$CGI4_PORT"
CGI5_BASE="http://127.0.0.1:$CGI5_PORT"

go build -o "$BIN" . || exit 1

# 会话 ACL 的 acl.d 目录：darwin 的默认相对路径在 molly/ 下不成立，用环境变量覆盖
export GOMOLLY_ACL_DIR="$ROOT/tests/fixtures/acl.d"

PIDS=()
start_server() { # start_server <端口> [额外参数...]
  local port="$1"
  shift
  "$BIN" --listen "127.0.0.1:$port" --docroot "$DOCROOT" \
    --menu-dir "$ROOT/tests/fixtures/menu.d" "$@" >"/tmp/molly-smoke-$port.log" 2>&1 &
  PIDS+=($!)
}
stop_all() {
  for pid in "${PIDS[@]:-}"; do kill "$pid" 2>/dev/null; done
  for pid in "${PIDS[@]:-}"; do wait "$pid" 2>/dev/null; done
}
trap stop_all EXIT

# 默认实例用内置占位 dispatcher：那 40 多条 LuCI dispatcher 断言打的是这条路径
# （自研站点是默认渲染方式，由下面 --luci-prefix 那份实例覆盖）。
start_server "$PORT" --luci-render builtin
# 其余实例都走 --luci-cgi：整个 /cgi-bin/luci 前缀交给子进程（设备上的 ucode dispatcher）
start_server "$CGI_PORT" --luci-cgi "$ROOT/tests/fixtures/cgi/echo.sh"
start_server "$CGI2_PORT" --luci-cgi "$ROOT/tests/fixtures/cgi/status.sh"
start_server "$CGI3_PORT" --luci-cgi "$ROOT/tests/fixtures/cgi/broken.sh"
start_server "$CGI4_PORT" --luci-cgi "$ROOT/tests/fixtures/cgi/noctype.sh"
start_server "$CGI5_PORT" --luci-cgi "$ROOT/tests/fixtures/cgi/sizeprobe.sh"

# 等端口起来（最多 3 秒）
wait_cgi() { # wait_cgi <base>
  for _ in $(seq 1 30); do
    if curl -s -o /dev/null "$1/cgi-bin/luci"; then return 0; fi
    sleep 0.1
  done
}
for _ in $(seq 1 30); do
  if curl -s -o /dev/null "$BASE/"; then break; fi
  sleep 0.1
done
wait_cgi "$CGI_BASE"
wait_cgi "$CGI2_BASE"
wait_cgi "$CGI3_BASE"
wait_cgi "$CGI4_BASE"
wait_cgi "$CGI5_BASE"

PASS=0
FAIL=0

# check <描述的> <期望值> <实际值>
check() {
  if [[ "$2" == "$3" ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: $1  期望=[$2] 实际=[$3]"
  fi
}

# status <方法> <路径> [额外 curl 参数...]
#
# HEAD 必须用 -I 而不是 `-X HEAD`：后者只换了请求行的方法，curl 仍按「有 body」
# 去读，而 HEAD 响应没有 body —— 会一直挂到超时。
status() {
  local method="$1" path="$2"
  shift 2
  if [[ "$method" == "HEAD" ]]; then
    curl -s -o /dev/null -w '%{http_code}' -I "$@" "http://127.0.0.1:$PORT$path"
  else
    curl -s -o /dev/null -w '%{http_code}' -X "$method" "$@" "http://127.0.0.1:$PORT$path"
  fi
}

# header <路径> <头名>
header() {
  curl -s -D - -o /dev/null "http://127.0.0.1:$PORT$1" | tr -d '\r' |
    awk -F': ' -v k="$2" 'tolower($1)==tolower(k){print $2; exit}'
}

# header_of <头名> <curl 参数...> —— 用完整 curl 参数取某个响应头（POST 用）
header_of() {
  local name="$1"; shift
  curl -sD- -o /dev/null "$@" | tr -d '\r' |
    awk -F': ' -v k="$name" 'tolower($1)==tolower(k){print $2; exit}'
}

# header_line <路径> <头名> —— 取「头名: 值」整行，且头名比对**大小写敏感**。
# 上面两个 helper 用 tolower 比对（HTTP 语义上头名不区分大小写），但 Odin 版是
# **按字节透传**头名的，所以字节级契约得单独用这一条锁。
header_line() {
  curl -s -D - -o /dev/null "http://127.0.0.1:$PORT$1" | tr -d '\r' |
    awk -F': ' -v k="$2" '$1==k{print $1": "$2; exit}'
}

# json_get <JSON 文本> <python 表达式> —— d 是解析后的对象，用来取字段/错误码
json_get() {
  python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(eval(sys.argv[2]))' "$1" "$2"
}

# upost <路径> <curl 额外参数...> —— POST 到 $BASE<路径>
upost() {
  local p="$1"; shift
  curl -s -X POST "$@" "$BASE$p"
}

# ---- dispatcher 断言辅助（都作用在 $BASE，即内置 dispatcher 实例）----
# h1_of <curl 参数...> —— 占位页的 <h1>（title 或 action.path 回落）
h1_of() { curl -s "$@" | grep -o '<h1>[^<]*</h1>' | head -1 | sed 's/<[^>]*>//g'; }
# view_of <curl 参数...> —— 占位页的 <dt>view</dt><dd>…</dd>
view_of() { curl -s "$@" | grep -o '<dt>view</dt><dd>[^<]*</dd>' | sed 's/.*<dd>//; s/<\/dd>//'; }
# readonly_of <curl 参数...> —— 占位页的 <dt>readonly</dt><dd>yes|no</dd>
readonly_of() {
  curl -s "$@" | grep -o '<dt>readonly</dt><dd>[^<]*</dd>' | sed 's/.*<dd>//; s/<\/dd>//'
}
# body_of <curl 参数...> —— 响应正文
body_of() { curl -s "$@"; }
# code_of <curl 参数...> —— 任意完整 URL 的状态码（CGI 段用，$PORT 之外的实例）
code_of() { curl -s -o /dev/null -w '%{http_code}' "$@"; }

# ---- 路由顺序 / 边界 ----
# 根路径是**新手版入口**（302 到 /lite/），不是静态首页了；新手版页面本体在 /lite/。
check "根路径是入口 → 302" "302" "$(status GET /)"
check "/ubus 走 ubus 路由（GET 回 404）" "404" "$(status GET /ubus)"
check "/ubus/ 也走 ubus 路由（GET 回 404）" "404" "$(status GET /ubus/)"
check "/ubus.html 不被 ubus 抢走（边界）" "404" "$(status GET /ubus.html)"
# /cgi-bin/luci 走 dispatcher：无 cookie 时 root firstchild 落到 admin（带 auth.login）
# → 403 + 登录提示（不是 404）。fixture 的 admin 与设备真实 menu.d 同形。
check "/cgi-bin/luci 无 cookie → 403" "403" "$(status GET /cgi-bin/luci)"
check "/cgi-bin/luci 无 cookie 带 X-LuCI-Login-Required" "yes" \
  "$(header /cgi-bin/luci X-LuCI-Login-Required)"
# 边界：/cgi-bin/luci-static **不是** /cgi-bin/luci 前缀，不能被 dispatcher 抢走。
# 现在这里回 403（docroot 的 /cgi-bin/* 一律不外发，见 internal/handlers/static.go），
# 而 dispatcher 接管时会回 404——两者不同，正好说明它没被 dispatcher 吃掉。
check "/cgi-bin/luci-static 不被抢走（边界）" "403" "$(status GET /cgi-bin/luci-static)"

# ---- 静态文件 ----
check "静态文件 200" "200" "$(status GET /ubus-probe.txt)"
check "静态文件正文" "$(cat "$DOCROOT/ubus-probe.txt")" \
  "$(curl -s "http://127.0.0.1:$PORT/ubus-probe.txt")"
# Content-Type 逐条对齐原厂 uhttpd（2026-10-07 真机实测）：**不带 charset**。
check "css 的 Content-Type" "text/css" "$(header /luci-static/test.css Content-Type)"
check "txt 的 Content-Type" "text/plain" "$(header /ubus-probe.txt Content-Type)"
check "不存在的文件 404" "404" "$(status GET /nope.txt)"
# uhttpd 的 404 是 text/html（正文是 `Not Found` 那条；正文里含路径，不逐字节钉）
check "404 的 Content-Type" "text/html" "$(header /nope.txt Content-Type)"
# `/lite` 是**新手版**（编译进二进制的单文件页），`/` 只是跳转入口；两者都不再是
# docroot 的 index.html——目录回落的覆盖改用 /luci-static/sub/（fixture 里有它自己的
# index.html）。
check "目录有 index.html 时回落" "200" "$(status GET /luci-static/sub/)"
check "目录无 index.html 时 404" "404" "$(status GET /luci-static/)"
# 入口：/ → 302 /lite/（302 而不是 301：前缀以后还可能再挪，301 会被浏览器永久缓存）
check "/ 是入口 → 302" "302" "$(status GET /)"
check "/ 跳到 /lite/" "/lite/" "$(header_of Location "$BASE/")"
# 新手版三件事：就是内联那一页、占位符被替换干净、服务端把 cookie 里的 sid 注进页面。
check "新手版标题" "yes" \
  "$(curl -s "$BASE/lite/" | grep -q '<title>路由器 · 新手版</title>' && echo yes || echo no)"
check "新手版占位符已替换" "0" "$(curl -s "$BASE/lite/" | grep -c '__SID__\|__EXPERT_PREFIX__' || true)"
check "新手版的 cookie sid 被注入页面" "yes" \
  "$(curl -s -H 'Cookie: sysauth_molly=0123456789abcdef0123456789abcdef' "$BASE/lite/" \
    | grep -q '0123456789abcdef0123456789abcdef' && echo yes || echo no)"
# cookie 是客户端可控的，而它会被拼进页面的 JS 字符串：非 hex 一律整串丢弃
check "非法 cookie 不外泄进页面" "0" \
  "$(curl -s -H 'Cookie: sysauth_molly=<script>x</script>' "$BASE/lite/" | grep -c '<script>x' || true)"
check "/lite（无尾斜杠）也走新手版" "200" "$(status GET /lite)"
check "/lite/index.html 也走新手版" "text/html; charset=utf-8" \
  "$(header_of Content-Type "$BASE/lite/index.html")"
check "静态路径上的 POST 405" "405" "$(status POST /ubus-probe.txt)"

# ---- 会话统一：新手版登录 → 专家版直接可用 ----
#
# 登录/退出由服务端处理（ServeNovice 的 POST 分支），下发的 cookie 用 path=/，于是
# `/`、`/lite`、专家版前缀都收得到它——两套界面读写的是**同一个 cookie 槽位**，也就是
# 同一条会话。登录本身调的是与专家版同一个 `session` 对象，所以这里的断言是端到端的
# 「一处登录、两处可用」。
NL_HDR=$(mktemp)
NL_CODE=$(curl -s -o /dev/null -D "$NL_HDR" -w '%{http_code}' -X POST "$BASE/auth/login" \
  -d 'username=root' -d 'password=test1234')
check "/auth/login → 302" "302" "$NL_CODE"
check "登录成功回到 /" "/" \
  "$(awk -F': ' 'tolower($1)=="location"{print $2}' "$NL_HDR" | tr -d '\r')"
SESCOOKIE=$(awk -F': ' 'tolower($1)=="set-cookie"{print $2}' "$NL_HDR" | tr -d '\r' | head -1)
check "下发共用会话 cookie（path=/）" "yes" \
  "$(printf '%s' "$SESCOOKIE" | grep -qi 'sysauth_molly=[0-9a-f]\{32\}.*path=/' && echo yes || echo no)"
NSID=$(printf '%s' "$SESCOOKIE" | sed -n 's/^sysauth_molly=\([^;]*\).*/\1/p')
check "会话 id 是 32 位" "32" "${#NSID}"
# 关键断言：拿**新手版登录得到的** cookie 去专家版页面，应当直接可用
check "新手版会话在专家版直接可用" "200" \
  "$(status GET /cgi-bin/luci/admin/status/overview -b "sysauth_molly=$NSID")"
check "该会话在专家版拿到真页面" "Overview" \
  "$(h1_of -b "sysauth_molly=$NSID" "$BASE/cgi-bin/luci/admin/status/overview")"
# 反方向：专家版也认这个 cookie 名（luciSIDFromCookie 优先读它）
check "专家版页面认 sysauth_molly 这个名字" "200" \
  "$(status GET /cgi-bin/luci/admin/status/overview -b "sysauth_molly=$NSID; sysauth_http=bad")"

# 退出：清掉共用 cookie
LO_HDR=$(mktemp)
check "/auth/logout → 302" "302" \
  "$(curl -s -o /dev/null -D "$LO_HDR" -w '%{http_code}' -X POST "$BASE/auth/logout" \
     -b "sysauth_molly=$NSID")"
check "退出清掉会话 cookie" "yes" \
  "$(awk -F': ' 'tolower($1)=="set-cookie"{print $2}' "$LO_HDR" | tr -d '\r' \
     | grep -q 'sysauth_molly=;' && echo yes || echo no)"
# 密码错：回登录页并带错误标记，且不下发 cookie
check "密码错 → 带 auth_error 回登录页" "/?auth_error=bad_credentials" \
  "$(curl -s -o /dev/null -D- -X POST "$BASE/auth/login" -d 'username=root' \
     -d 'password=wrong' | tr -d '\r' | awk -F': ' 'tolower($1)=="location"{print $2}')"
check "密码错不下发 cookie" "0" \
  "$(curl -s -o /dev/null -D- -X POST "$BASE/auth/login" -d 'username=root' \
     -d 'password=wrong' | grep -ci '^set-cookie' || true)"
# 认证面搬走后，新手版页面**不再**接 POST（旧接口下线）
check "POST /lite/ 已下线 → 405" "405" "$(status POST /lite/)"
# /auth 的边界：不接受 GET、也不该有别的子路径（不泄露方法存在性）
check "GET /auth/login → 404" "404" "$(status GET /auth/login)"
check "POST /auth/nope → 404" "404" "$(status POST /auth/nope)"
# LuCI 表单的那套字段名也收（专家版主题表单要切过来时不用改 HTML）
check "/auth/login 收 luci_* 字段" "302" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/auth/login" \
     -d 'luci_username=root' -d 'luci_password=test1234')"
rm -f "$NL_HDR" "$LO_HDR"

# ---- HEAD：完整头 + 空 body ----
check "HEAD 200" "200" "$(status HEAD /ubus-probe.txt)"
check "HEAD 带 Content-Length" "26" "$(header /ubus-probe.txt Content-Length)"
check "HEAD 无 body" "0" \
  "$(curl -s -I -o /dev/null -w '%{size_download}' "http://127.0.0.1:$PORT/ubus-probe.txt")"

# ---- URI 规范化边界 ----
check ".. 逃逸 403" "403" "$(status GET /../etc/passwd --path-as-is)"
check "编码的 .. 逃逸 403" "403" "$(status GET /a/%2e%2e/b --path-as-is)"
check "非法百分号编码 400" "400" "$(status GET /a%zz --path-as-is)"
check "NUL 拒绝 400" "400" "$(status GET /a%00b --path-as-is)"
check "编码的 / 解码后命中真实文件" "200" "$(status GET /luci-static%2ftest.css --path-as-is)"
check "编码的 . 段被丢弃" "200" "$(status GET /luci-static/./test.css --path-as-is)"

# ---- 头行为（对齐 Odin 版：故意不发 Date / Server）----
check "不发 Date 头" "" "$(header / Date)"
check "不发 Server 头" "" "$(header / Server)"

# ---- /ubus GET：list 与路由边界 ----
echo
echo "== /ubus GET：list 与路由边界 =="
check "GET /ubus/list → 200" "200" "$(status GET /ubus/list)"
check "list Content-Type" "application/json" "$(header /ubus/list Content-Type)"
check "list 对象齐全且字典序" "file,luci,luci-rpc,molly.probe,session,uci" \
  "$(json_get "$(curl -s "$BASE/ubus/list")" '",".join(sorted(d))')"
check "list/session 含 login" "login" \
  "$(json_get "$(curl -s "$BASE/ubus/list/session")" '"login" if "login" in d else "缺 login"')"
check "未知对象 → 500" "500" "$(status GET /ubus/list/nope)"
check "500 正文是 JSON" "application/json" "$(header /ubus/list/nope Content-Type)"
check "GET list 500 正文 code=4" "4" \
  "$(json_get "$(curl -s "$BASE/ubus/list/nope")" 'd["code"]')"
check "GET /ubus → 404" "404" "$(status GET /ubus)"
check "GET /ubus/<其它> → 404" "404" "$(status GET /ubus/nope)"
check "OPTIONS /ubus → 200" "200" "$(status OPTIONS /ubus)"
check "OPTIONS 的 Content-Length 为 0" "0" \
  "$(header_of Content-Length -X OPTIONS "$BASE/ubus")"
check "HEAD /ubus → 400" "400" "$(status HEAD /ubus)"
check "PUT /ubus → 400" "400" "$(status PUT /ubus)"
check "POST /ubus/nope → 404" "404" "$(status POST /ubus/nope -d '{}')"

# ---- /ubus 旧式 POST（JSON-RPC 信封）----
echo
echo "== /ubus 旧式 POST（JSON-RPC 信封）=="
# P3-6 起 call 先走 uhttpd 那道前置 ACL 校验（uh_ubus_allowed → session.access）：
# 哨兵会话（32 个 0）只被 unauthenticated 组授予 session.login/access，其余调用一律
# -32002。所以先登一个会话（fixture 的 smoke-full 组授了 `*` ubus），后面各对象的
# **对象级**语义断言才跑得起来。
sid0="00000000000000000000000000000000"
P2SID=$(upost /ubus/call/session \
  -d '{"jsonrpc":"2.0","id":"acl1","method":"login","params":{"username":"root","password":"test1234"}}' \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["result"]["ubus_rpc_session"])')
check "登录拿到 32 位 sid" "32" "${#P2SID}"
AUTH="Authorization: Bearer $P2SID"

legacy='{"jsonrpc":"2.0","id":1,"method":"call","params":["'"$P2SID"'","luci","getBoardJSON",{}]}'
check "旧式状态 200" "200" "$(status POST /ubus -d "$legacy")"
check "旧式 Content-Type" "application/json" \
  "$(header_of Content-Type -X POST -d "$legacy" "$BASE/ubus")"
r=$(upost /ubus -d "$legacy")
check "旧式 result 是数组 [0,…]" "0" "$(json_get "$r" 'd["result"][0]')"
check "旧式回显 object" "luci" "$(json_get "$r" 'd["result"][1]["echo"]["object"]')"
check "旧式回显 method" "getBoardJSON" "$(json_get "$r" 'd["result"][1]["echo"]["method"]')"
check "旧式 sid 取 params[0]" "$P2SID" "$(json_get "$r" 'd["result"][1]["echo"]["sid"]')"
check "id 原样回显" "1" "$(json_get "$r" 'd["id"]')"
check "缺 id 时回 null" "True" \
  "$(json_get "$(upost /ubus -d '{"jsonrpc":"2.0","method":"list"}')" 'd["id"] is None')"

# --- 前置 ACL 校验（uhttpd 的 uh_ubus_allowed）---
check "哨兵调用非 session 对象 → -32002（fail-closed）" "-32002" \
  "$(json_get "$(upost /ubus -d '{"jsonrpc":"2.0","id":50,"method":"call","params":["'"$sid0"'","uci","configs",{}]}')" 'd["error"]["code"]')"
check "哨兵 login → 放行（unauthenticated 组授了 session.login）" "32" \
  "$(json_get "$(upost /ubus -d '{"jsonrpc":"2.0","id":51,"method":"call","params":["'"$sid0"'","session","login",{"username":"root","password":"test1234"}]}')" 'len(d["result"][1]["ubus_rpc_session"])')"
check "无效 sid → -32002（会话取不到 → fail-closed）" "-32002" \
  "$(json_get "$(upost /ubus -d '{"jsonrpc":"2.0","id":52,"method":"call","params":["deadbeefdeadbeefdeadbeefdeadbeef","uci","configs",{}]}')" 'd["error"]["code"]')"
check "对象不存在优先于 ACL → -32000" "-32000" \
  "$(json_get "$(upost /ubus -d '{"jsonrpc":"2.0","id":53,"method":"call","params":["'"$sid0"'","nope","frob",{}]}')" 'd["error"]["code"]')"

check "未知对象 → -32000" "-32000" \
  "$(json_get "$(upost /ubus -d '{"jsonrpc":"2.0","id":2,"method":"call","params":["","nope","list",{}]}')" 'd["error"]["code"]')"
check "未知方法 → -32601" "-32601" \
  "$(json_get "$(upost /ubus -d '{"jsonrpc":"2.0","id":3,"method":"frob"}')" 'd["error"]["code"]')"
check "jsonrpc 非 2.0 → -32700" "-32700" \
  "$(json_get "$(upost /ubus -d '{"jsonrpc":"1.0","id":4,"method":"list"}')" 'd["error"]["code"]')"
check "params 不足四项 → -32700" "-32700" \
  "$(json_get "$(upost /ubus -d '{"jsonrpc":"2.0","id":5,"method":"call","params":["","session","list"]}')" 'd["error"]["code"]')"
check "params 带 ubus_rpc_session → -32602" "-32602" \
  "$(json_get "$(upost /ubus -d '{"jsonrpc":"2.0","id":6,"method":"call","params":["'"$P2SID"'","session","list",{"ubus_rpc_session":"x"}]}')" 'd["error"]["code"]')"
check "正文非法 JSON → -32700" "-32700" \
  "$(json_get "$(upost /ubus -d '{oops')" 'd["error"]["code"]')"
check "正文是标量 → -32700" "-32700" \
  "$(json_get "$(upost /ubus -d '42')" 'd["error"]["code"]')"

check "list 无 params → 路径数组" "file,luci,luci-rpc,molly.probe,session,uci" \
  "$(json_get "$(upost /ubus -d '{"jsonrpc":"2.0","id":7,"method":"list"}')" '",".join(d["result"])')"
check "list 带 params → 详细表（查不到的忽略）" "session,uci" \
  "$(json_get "$(upost /ubus -d '{"jsonrpc":"2.0","id":8,"method":"list","params":["session","uci","nope"]}')" '",".join(sorted(d["result"]))')"
check "数组正文 → 批响应" "0,file,luci,luci-rpc,molly.probe,session,uci" \
  "$(json_get "$(upost /ubus -d '[{"jsonrpc":"2.0","id":9,"method":"call","params":["'"$P2SID"'","uci","configs",{}]},{"jsonrpc":"2.0","id":10,"method":"list"}]')" '",".join([str(d[0]["result"][0])] + d[1]["result"])')"
check "空数组正文 → []" "[]" "$(upost /ubus -d '[]')"

# ---- /ubus 新式 POST /ubus/call/<path> ----
echo
echo "== /ubus 新式 POST /ubus/call/<path> =="
# AUTH 复用上面的登录会话（P2SID）；新式会话只从 Authorization 头取（不看 body）。
new() { upost "$1" -d "$2" -H "$AUTH"; }
r=$(new /ubus/call/luci '{"jsonrpc":"2.0","id":11,"method":"getBoardJSON","params":{}}')
check "新式状态 200" "200" \
  "$(status POST /ubus/call/luci -H "$AUTH" -d '{"jsonrpc":"2.0","id":11,"method":"getBoardJSON"}')"
check "新式 result 是对象（无外层数组）" "luci" "$(json_get "$r" 'd["result"]["echo"]["object"]')"
check "新式 method 就是 ubus 方法名" "getBoardJSON" "$(json_get "$r" 'd["result"]["echo"]["method"]')"
check "Authorization 的 sid 送进对象" "$P2SID" "$(json_get "$r" 'd["result"]["echo"]["sid"]')"
check "无 params → 空参数表" "{}" \
  "$(json_get "$(new /ubus/call/luci '{"jsonrpc":"2.0","id":13,"method":"getBoardJSON"}')" 'json.dumps(d["result"]["echo"]["params"],sort_keys=True)')"
check "无 Authorization（哨兵）→ -32002（fail-closed）" "-32002" \
  "$(json_get "$(upost /ubus/call/luci -d '{"jsonrpc":"2.0","id":12,"method":"getBoardJSON"}')" 'd["error"]["code"]')"
check "无效 Bearer → -32002（会话取不到）" "-32002" \
  "$(json_get "$(upost /ubus/call/luci -H 'Authorization: Bearer deadbeefdeadbeefdeadbeefdeadbeef' -d '{"jsonrpc":"2.0","id":12,"method":"getBoardJSON"}')" 'd["error"]["code"]')"
check "对象不存在 → -32000" "-32000" \
  "$(json_get "$(new /ubus/call/nope '{"jsonrpc":"2.0","id":14,"method":"frob"}')" 'd["error"]["code"]')"
check "未知方法 → ubus 返回码 3" "3" \
  "$(json_get "$(new /ubus/call/uci '{"jsonrpc":"2.0","id":15,"method":"frob"}')" 'd["error"]["code"]')"
check "params 非表 → -32602" "-32602" \
  "$(json_get "$(new /ubus/call/uci '{"jsonrpc":"2.0","id":16,"method":"configs","params":[1,2]}')" 'd["error"]["code"]')"
check "params 为 null → -32602" "-32602" \
  "$(json_get "$(new /ubus/call/uci '{"jsonrpc":"2.0","id":17,"method":"configs","params":null}')" 'd["error"]["code"]')"
check "对象不存在优先于参数错误" "-32000" \
  "$(json_get "$(new /ubus/call/nope '{"jsonrpc":"2.0","id":18,"method":"configs","params":[1]}')" 'd["error"]["code"]')"
check "正文非法 JSON → -32700" "-32700" \
  "$(json_get "$(new /ubus/call/uci '{oops')" 'd["error"]["code"]')"
check "POST /ubus/call（无路径）→ 404" "404" "$(status POST /ubus/call -d '{}')"

# ---- /ubus/subscribe（SSE）----
echo
echo "== /ubus/subscribe（SSE）=="
# 上游 ubus.c:373-424：订阅的 ACL 点是伪方法 ":subscribe"，**不是** call 的方法名；
# 不过时回 200 + application/json + {"code":-13,"message":"Permission denied"}
# （posix **负码**，与 /ubus/call 的 -32002 不是一回事）。成功后是 text/event-stream，
# 帧格式 `event: <method>\ndata: <json>\n\n`。
check "哨兵订阅 → 200（错误在正文里）" "200" \
  "$(status GET /ubus/subscribe/molly.probe)"
sser=$(curl -s "$BASE/ubus/subscribe/molly.probe")
check "哨兵订阅正文是 posix 负码 -13" "-13" "$(json_get "$sser" 'd["code"]')"
check "哨兵订阅的 Content-Type 是 json" "application/json" \
  "$(header /ubus/subscribe/molly.probe Content-Type)"
check "授权订阅的 Content-Type 是 text/event-stream" "text/event-stream" \
  "$(header_of Content-Type --max-time 2 -H "Authorization: Bearer $P2SID" \
     "$BASE/ubus/subscribe/molly.probe")"
check "授权会话订阅不存在的对象 → code 4" "4" \
  "$(json_get "$(curl -s --max-time 2 -H "Authorization: Bearer $P2SID" "$BASE/ubus/subscribe/nope")" 'd["code"]')"
# 事件投递：后台挂一条订阅，再让探针对象发一条通知（`molly.probe` 的 `notify`：
# linux 上是 `ubus_notify`，darwin 上直接推事件总线，两者同形），看帧有没有到。
SSE_OUT=$(mktemp)
curl -sN --max-time 4 -H "Authorization: Bearer $P2SID" \
  "$BASE/ubus/subscribe/molly.probe" > "$SSE_OUT" &
SSE_PID=$!
sleep 1
upost /ubus/call/molly.probe -H "Authorization: Bearer $P2SID" \
  -d '{"jsonrpc":"2.0","id":"ev1","method":"notify","params":{}}' >/dev/null
wait "$SSE_PID" 2>/dev/null
check "SSE 收到 event 帧" "1" "$(grep -c '^event: ping$' "$SSE_OUT")"
check "SSE 帧带 data" "1" "$(grep -c '^data: {"hello":"world"}$' "$SSE_OUT")"
rm -f "$SSE_OUT"

# ---- /cgi-bin/luci dispatcher（菜单树 + 路径解析 + 会话 ACL）----
echo
echo "== /cgi-bin/luci dispatcher（菜单树 + 路径解析 + 会话 ACL）=="
# 语义复刻上游 modules/luci-base/ucode/dispatcher.uc：menu.d → 树 → 逐段下降；
# firstchild 选权重最小的可展示子节点；depends.fs / depends.uci 决定 satisfied；
# depends.acl 参与裁树（缺组 → 路径 404 / firstchild 跳过；只有 read → 可见但只读）。
# 会话来自 LuCI 写的 cookie（sysauth_http / sysauth_https）。fixture 见 tests/fixtures/menu.d/。
sid0="00000000000000000000000000000000"
P2SID=$(upost /ubus/call/session \
  -d '{"jsonrpc":"2.0","id":"disp1","method":"login","params":{"username":"root","password":"test1234"}}' \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["result"]["ubus_rpc_session"])')
LUCICOOKIE="sysauth_http=$P2SID"
check "登录拿到 32 位 sid" "32" "${#P2SID}"

check "裸前缀 → 200" "200" "$(status GET /cgi-bin/luci -b "$LUCICOOKIE")"
check "带尾斜杠 → 200" "200" "$(status GET /cgi-bin/luci/ -b "$LUCICOOKIE")"
check "占位页 Content-Type" "text/html; charset=utf-8" \
  "$(header_of Content-Type -b "$LUCICOOKIE" "$BASE/cgi-bin/luci/")"
# root 的 firstchild 必须跳过 depends.fs 未命中的 hidden（order 1，权重最小）
check "root firstchild 跳过 unsatisfied" "Overview" "$(h1_of -b "$LUCICOOKIE" "$BASE/cgi-bin/luci/")"
check "指定路径命中" "Overview" \
  "$(h1_of -b "$LUCICOOKIE" "$BASE/cgi-bin/luci/admin/status/overview")"
check "查询串被剥掉" "200" "$(status GET '/cgi-bin/luci/admin/status/overview?v=1' -b "$LUCICOOKIE")"
check "占位页没有 ACL 未实施横幅" "0" \
  "$(body_of -b "$LUCICOOKIE" "$BASE/cgi-bin/luci/admin/status/overview" | grep -c 'ACL 未实施')"
check "depends 原样展示" "1" \
  "$(body_of -b "$LUCICOOKIE" "$BASE/cgi-bin/luci/admin/status/overview" | grep -c 'luci-base')"
check "登录会话（有 write）不是只读" "no" \
  "$(readonly_of -b "$LUCICOOKIE" "$BASE/cgi-bin/luci/admin/status/overview")"

# --- 中间层的 firstchild ---
check "/admin/status 走 firstchild" "Overview" \
  "$(h1_of -b "$LUCICOOKIE" "$BASE/cgi-bin/luci/admin/status")"
check "/admin/system 走 firstchild" "Reboot" \
  "$(h1_of -b "$LUCICOOKIE" "$BASE/cgi-bin/luci/admin/system")"

# --- depends.acl：裁树 + 只读 ---
# 「没有 cookie」≠「缺组」：admin 带 auth.login，无会话打这条路径先被判成「要登录」
# ——上游回 403 + X-LuCI-Login-Required + 登录页（不是 404）。
check "无 cookie：要登录的路径 → 403（不是 404）" "403" \
  "$(status GET /cgi-bin/luci/admin/status/overview)"
check "无 cookie：带 X-LuCI-Login-Required 头" "yes" \
  "$(header /cgi-bin/luci/admin/status/overview X-LuCI-Login-Required)"
# 头名按字节透传（CGI 桥与登录页都走 RespondFull）：Go 的 h.Add 会规范化成
# `X-Luci-…`，与 Odin 版不一致——这一条专门盯它。
check "无 cookie：头名按字节透传（不规范化）" "X-LuCI-Login-Required: yes" \
  "$(header_line /cgi-bin/luci/admin/status/overview X-LuCI-Login-Required)"
check "无 cookie：提示页是登录提示" "1" \
  "$(body_of "$BASE/cgi-bin/luci/admin/status/overview" | grep -c '<h1>Login required</h1>')"
check "无 cookie：提示页列出请求路径" "1" \
  "$(body_of "$BASE/cgi-bin/luci/admin/status/overview" | grep -c '<dt>path</dt><dd>/admin/status/overview</dd>')"
# 哨兵会话（有会话但缺组）：纯 ACL 结果 → 门控节点被裁掉
check "哨兵会话（有会话但缺组）：门控路径 → 404" "404" \
  "$(status GET /cgi-bin/luci/admin/status/overview -b "sysauth_http=$sid0")"
# 跳过 overview 后落到 logs（order 50）：title 被 luci-probe.json 的通配后缀覆盖
check "哨兵会话：firstchild 跳过门控节点" "Logs (wildcard)" \
  "$(h1_of -b "sysauth_http=$sid0" "$BASE/cgi-bin/luci/admin/status")"
# 只读会话：root 登录（拿到 luci-base read+write）后撤掉 write → 可见但只读
RO_SID=$(upost /ubus/call/session \
  -d '{"jsonrpc":"2.0","id":"ro1","method":"login","params":{"username":"root","password":"test1234"}}' \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["result"]["ubus_rpc_session"])')
upost /ubus/call/session -H "Authorization: Bearer $RO_SID" \
  -d '{"jsonrpc":"2.0","id":"ro2","method":"revoke","params":{"scope":"access-group","objects":[["luci-base","write"]]}}' >/dev/null
check "只读会话：门控路径 → 200" "200" \
  "$(status GET /cgi-bin/luci/admin/status/overview -b "sysauth_http=$RO_SID")"
check "只读会话：firstchild 恢复门控节点" "Overview" \
  "$(h1_of -b "sysauth_http=$RO_SID" "$BASE/cgi-bin/luci/admin/status")"
check "只读会话：页面标 readonly" "yes" \
  "$(readonly_of -b "sysauth_http=$RO_SID" "$BASE/cgi-bin/luci/admin/status/overview")"

# --- 同路径逐键合并（dispatcher.uc:406-408 只拷 spec 里出现的键）---
check "同路径逐键合并：title 保留" "Reboot" \
  "$(h1_of -b "$LUCICOOKIE" "$BASE/cgi-bin/luci/admin/system/reboot")"
check "同路径逐键合并：probe 的 action 生效" "system/reboot" \
  "$(view_of -b "$LUCICOOKIE" "$BASE/cgi-bin/luci/admin/system/reboot")"

# --- action.type 分流 ---
check "action.type=cbi → 501" "501" \
  "$(status GET /cgi-bin/luci/admin/status/routes -b "$LUCICOOKIE")"
check "501 正文带动作信息" \
  "not implemented: action.type=cbi view=status/routes menu=/admin/status/routes" \
  "$(body_of -b "$LUCICOOKIE" "$BASE/cgi-bin/luci/admin/status/routes")"

# --- 通配段（dispatcher.uc:410-414 / :1010-1011）---
check "通配段收下剩余段" "200" \
  "$(status GET /cgi-bin/luci/admin/status/logs/syslog -b "$LUCICOOKIE")"
check "通配段的 request_args 进页面" "syslog" \
  "$(body_of -b "$LUCICOOKIE" "$BASE/cgi-bin/luci/admin/status/logs/syslog" \
     | grep -o '<dd>[^<]*</dd>' | tail -1 | sed 's/<[^>]*>//g')"
check "通配节点无剩余段 → 用 base action" "status/logs-base" \
  "$(view_of -b "$LUCICOOKIE" "$BASE/cgi-bin/luci/admin/status/logs")"
check "通配节点有剩余段 → 用 wildcardaction" "status/logs-arg" \
  "$(view_of -b "$LUCICOOKIE" "$BASE/cgi-bin/luci/admin/status/logs/syslog")"

# --- depends.fs（dispatcher.uc:171-196 + :279-292）---
check "depends.fs file 命中 → 200" "200" "$(status GET /cgi-bin/luci/present)"
check "depends.fs file 未命中 → 404" "404" "$(status GET /cgi-bin/luci/hidden)"
check "depends.fs absent 且确实不存在 → 200" "200" "$(status GET /cgi-bin/luci/fsabsent)"
check "depends.fs object 需全部条目成立 → 404" "404" "$(status GET /cgi-bin/luci/fsand)"
check "depends.fs array 任一备选成立 → 200" "200" "$(status GET /cgi-bin/luci/fsarray)"
check "depends.fs directory 且非空 → 200" "200" "$(status GET /cgi-bin/luci/fsdir)"
check "depends.fs 要求 directory 但是文件 → 404" "404" "$(status GET /cgi-bin/luci/fskind)"
check "depends.fs executable 命中 → 200" "200" "$(status GET /cgi-bin/luci/fsexec)"
check "depends.fs executable 无执行位 → 404" "404" "$(status GET /cgi-bin/luci/fsexecmiss)"
check "depends.fs 非 object 备选 → 忽略（满足）" "200" "$(status GET /cgi-bin/luci/fsstrform)"

# --- depends.uci（dispatcher.uc:198-276；macOS 上走 backend 的假配置）---
check "depends.uci 具名 section → 200" "200" "$(status GET /cgi-bin/luci/ucipage)"
check "depends.uci section 不存在 → 404" "404" "$(status GET /cgi-bin/luci/ucimissing)"
check "depends.uci true（config 有 section）→ 200" "200" "$(status GET /cgi-bin/luci/ucitrue)"
check "depends.uci config 存在但无 section → 404" "404" "$(status GET /cgi-bin/luci/uciemptycfg)"
check "depends.uci config 不存在 → 404" "404" "$(status GET /cgi-bin/luci/ucicfgmissing)"
check "depends.uci @type 命中匿名 section → 200" "200" "$(status GET /cgi-bin/luci/uciaftype)"
check "depends.uci option 值精确匹配 → 200" "200" "$(status GET /cgi-bin/luci/uciopt)"
check "depends.uci option 值不符 → 404" "404" "$(status GET /cgi-bin/luci/ucioptmiss)"
check "depends.uci object 需全部 config 成立 → 404" "404" "$(status GET /cgi-bin/luci/uciand)"
check "depends.uci 非 object 备选 → 忽略（满足）" "200" "$(status GET /cgi-bin/luci/ucistrform)"

# --- schema 白名单（dispatcher.uc:406-408 是**逐键**处理）---
check "白名单外的键只忽略该键 → 200" "200" "$(status GET /cgi-bin/luci/badfield)"
check "类型不符的键被忽略（root firstchild 仍是 Overview）" "Overview" \
  "$(h1_of -b "$LUCICOOKIE" "$BASE/cgi-bin/luci/")"

# --- 路由边界 ---
check "未命中路径 → 404" "404" "$(status GET /cgi-bin/luci/nope -b "$LUCICOOKIE")"
check "未知子树（带会话）→ 404" "404" "$(status GET /cgi-bin/luci/admin/nope -b "$LUCICOOKIE")"
check "未知子树（无会话）→ 403" "403" "$(status GET /cgi-bin/luci/admin/nope)"
check "dispatcher 上的 POST → 405" "405" \
  "$(status POST /cgi-bin/luci/admin/status/overview -b "$LUCICOOKIE")"
check "HEAD 有完整头无 body" "0" \
  "$(curl -s -I -b "$LUCICOOKIE" "$BASE/cgi-bin/luci/admin/status/overview" | awk 'BEGIN{b=0} /^\r?$/{f=1;next} f{b+=length($0)+1} END{print b}')"
check "HEAD 到被裁掉的路径也没有 body" "0" \
  "$(curl -s -I -b "sysauth_http=$sid0" "$BASE/cgi-bin/luci/admin/status/overview" | awk 'BEGIN{b=0} /^\r?$/{f=1;next} f{b+=length($0)+1} END{print b}')"
check "HEAD 到登录提示页也没有 body" "0" \
  "$(curl -s -I "$BASE/cgi-bin/luci/admin/status/overview" | awk 'BEGIN{b=0} /^\r?$/{f=1;next} f{b+=length($0)+1} END{print b}')"

# ---- /cgi-bin/luci 子进程桥（--luci-cgi）----
echo
echo "== /cgi-bin/luci 子进程桥（--luci-cgi）=="
# 对应 Odin 版 tests/cgi_smoke.sh：桩脚本替掉设备上的 ucode dispatcher，验的是**桥接**本身
# ——环境变量、请求体透传、响应头解析与透传、错误路径。设备上把 --luci-cgi 换成 /www/cgi-bin/luci。
out=$(body_of "$CGI_BASE/cgi-bin/luci")
check "CGI 裸前缀 200" "200" "$(code_of "$CGI_BASE/cgi-bin/luci")"
check "CGI 方法是 GET" "method=GET" "$(printf '%s\n' "$out" | grep '^method=')"
check "CGI 脚本名是 /cgi-bin/luci" "script=/cgi-bin/luci" "$(printf '%s\n' "$out" | grep '^script=')"
check "CGI 裸前缀 PATH_INFO 为空" "path=" "$(printf '%s\n' "$out" | grep '^path=')"
check "CGI QUERY_STRING 为空" "query=" "$(printf '%s\n' "$out" | grep '^query=')"
check "CGI GATEWAY_INTERFACE" "gateway=CGI/1.1" "$(printf '%s\n' "$out" | grep '^gateway=')"
check "CGI DOCUMENT_ROOT 透传" "docroot=$DOCROOT" "$(printf '%s\n' "$out" | grep '^docroot=')"
check "CGI REMOTE_ADDR 是回环地址" "remote=127.0.0.1" "$(printf '%s\n' "$out" | grep '^remote=')"

out=$(body_of "$CGI_BASE/cgi-bin/luci/admin/status/overview?v=1&x=2")
check "CGI PATH_INFO 是前缀之后的路径" "path=/admin/status/overview" \
  "$(printf '%s\n' "$out" | grep '^path=')"
check "CGI QUERY_STRING 保留原样" "query=v=1&x=2" "$(printf '%s\n' "$out" | grep '^query=')"
check "CGI REQUEST_URI 含查询串" "request_uri=/cgi-bin/luci/admin/status/overview?v=1&x=2" \
  "$(printf '%s\n' "$out" | grep '^request_uri=')"

out=$(body_of -H 'X-Test: abc' -H 'Host: router.lan' "$CGI_BASE/cgi-bin/luci")
check "CGI 普通头映射成 HTTP_*" "xtest=abc" "$(printf '%s\n' "$out" | grep '^xtest=')"
check "CGI Host 也映射" "host=router.lan" "$(printf '%s\n' "$out" | grep '^host=')"

out=$(body_of -X POST -d 'hello' "$CGI_BASE/cgi-bin/luci/admin/x")
check "CGI POST 方法" "method=POST" "$(printf '%s\n' "$out" | grep '^method=')"
check "CGI CONTENT_LENGTH 是 body 长度" "clen=5" "$(printf '%s\n' "$out" | grep '^clen=')"
check "CGI body 原样透传" "body=hello" "$(printf '%s\n' "$out" | grep '^body=')"

out=$(body_of -X POST -H 'Content-Type: application/json' -d '{}' "$CGI_BASE/cgi-bin/luci")
check "CGI CONTENT_TYPE 单独给（不做成 HTTP_*）" "ctype=application/json" \
  "$(printf '%s\n' "$out" | grep '^ctype=')"

big=$(python3 -c 'print("a"*65536)')
check "CGI 64KB body 完整到达（无死锁）" "len=65536" \
  "$(body_of -X POST --data-binary "$big" "$CGI5_BASE/cgi-bin/luci")"

check "CGI Status: 302 透传" "302" "$(code_of "$CGI2_BASE/cgi-bin/luci")"
check "CGI Location 透传" "/cgi-bin/luci/" "$(header_of Location "$CGI2_BASE/cgi-bin/luci")"
# 会话 cookie 的 path 被放宽成 `/`（两套界面共用同一个 cookie 槽位，见
# internal/handlers/cgi.go 的 widenSessionCookiePath）；其余 cookie 原样透传。
check "CGI 会话 Set-Cookie 的 path 放宽到 /" "sysauth=deadbeef; path=/" \
  "$(header_of Set-Cookie "$CGI2_BASE/cgi-bin/luci")"
check "CGI Cache-Control 透传" "no-store" "$(header_of Cache-Control "$CGI2_BASE/cgi-bin/luci")"
check "CGI Content-Type 用脚本给的" "text/html; charset=utf-8" \
  "$(header_of Content-Type "$CGI2_BASE/cgi-bin/luci")"
check "CGI Content-Length 由 molly 重算" "19" \
  "$(header_of Content-Length "$CGI2_BASE/cgi-bin/luci")"

check "CGI 脚本无输出 → 500" "500" "$(code_of "$CGI3_BASE/cgi-bin/luci")"
check "CGI 无输出的 500 正文带退出码" "1" \
  "$(body_of "$CGI3_BASE/cgi-bin/luci" | grep -c 'invalid CGI response (exit 3): ""')"
check "CGI 缺 Content-Type → 500（CGI 规范）" "500" "$(code_of "$CGI4_BASE/cgi-bin/luci")"
check "CGI HEAD 有头无体" "0" \
  "$(curl -s -I "$CGI_BASE/cgi-bin/luci" | awk 'BEGIN{b=0} /^\r?$/{f=1;next} f{b+=length($0)+1} END{print b}')"
check "CGI HEAD 仍带真实 Content-Length" "1" \
  "$(cl=$(header_of Content-Length -I "$CGI_BASE/cgi-bin/luci"); [[ "${cl:-0}" -gt 0 ]] && echo 1 || echo 0)"
check "CGI keep-alive 复用同一连接" "1" \
  "$(curl -sv "$CGI_BASE/cgi-bin/luci" "$CGI_BASE/cgi-bin/luci" 2>&1 | grep -ci 'Re-using existing connection')"

# ---- P3-2 session 对象（molly 自己提供的 ubus 对象，darwin 上走真实现）----
echo
echo "== P3-2 session 对象 =="
# 语义依据 rpcd session.c；断言里带行号，改契约前先回去看那一行。
# jget '<python 表达式后缀>'：从 stdin 的 JSON 里取值；jq1 是 json_get 的别名
# （与 Odin 版 http_smoke.sh 同名，便于逐条对照）。
jget() { python3 -c 'import sys,json; d=json.load(sys.stdin); print(eval("d"+sys.argv[1]))' "$1"; }
jq1() { json_get "$@"; }

SID=$(upost /ubus/call/session \
  -d '{"jsonrpc":"2.0","id":1,"method":"login","params":{"username":"root","password":"test1234"}}' \
  | jget '["result"]["ubus_rpc_session"]')
check "login 返回 32 位 sid" "32" "${#SID}"
check "login 写入 data.username" "root" \
  "$(upost /ubus/call/session \
       -d '{"jsonrpc":"2.0","id":1,"method":"login","params":{"username":"root","password":"test1234"}}' \
     | jget '["result"]["data"]["username"]')"
check "login timeout 默认 300" "300" \
  "$(upost /ubus/call/session \
       -d '{"jsonrpc":"2.0","id":1,"method":"login","params":{"username":"root","password":"test1234"}}' \
     | jget '["result"]["timeout"]')"
check "login 显式 timeout 生效" "60" \
  "$(upost /ubus/call/session \
       -d '{"jsonrpc":"2.0","id":1,"method":"login","params":{"username":"root","password":"test1234","timeout":60}}' \
     | jget '["result"]["timeout"]')"
check "密码错误 → code 6（PERMISSION_DENIED）" "6" \
  "$(upost /ubus/call/session \
       -d '{"jsonrpc":"2.0","id":1,"method":"login","params":{"username":"root","password":"nope"}}' \
     | jget '["error"]["code"]')"

sess() { # sess <方法> <params JSON>
  upost /ubus/call/session -H "Authorization: Bearer $SID" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"$1\",\"params\":$2}"
}

check "get 回 values.username" "root" "$(sess get '{}' | jget '["result"]["values"]["username"]')"
check "set 无回复数据（result null）" "None" "$(sess set '{"values":{"token":"abc"}}' | jget '["result"]')"
check "get(keys) 只回命中的键" "abc" \
  "$(sess get '{"keys":["token","nope"]}' | jget '["result"]["values"]["token"]')"
check "grant 后 access=true（fnmatch file/* 命中 read）" "True" \
  "$(sess grant '{"objects":[["file","*"]]}' >/dev/null; sess access '{"object":"file","function":"read"}' | jget '["result"]["access"]')"
# P3-6 起登录会话带 acl.d 的 ACL：smoke-full 组把 scope "ubus" 全放行了，所以负例要
# 换一个**没被任何组**覆盖的 scope（scope "file" 的条目只来自 grant）。
check "未授权的方法 access=false" "False" \
  "$(sess access '{"scope":"file","object":"nope","function":"frob"}' | jget '["result"]["access"]')"
check "access 不给 object → 回 ACL 表（scope→object→[function]）" "True" \
  "$(jq1 "$(sess access '{}')" '"*" in d["result"]["ubus"]["file"] and "list" in d["result"]["ubus"]["file"]')"
check "unset 后键消失" "None" \
  "$(sess unset '{"keys":["token"]}' >/dev/null; sess get '{"keys":["token"]}' | jget '["result"]["values"].get("token")')"
check "list 带 sid → 单个会话 dump" "$SID" "$(sess list '{}' | jget '["result"]["ubus_rpc_session"]')"
check "哨兵调 session.get → -32002（unauthenticated 只授 access/login）" "-32002" \
  "$(upost /ubus/call/session -d '{"jsonrpc":"2.0","id":3,"method":"get","params":{}}' \
     | jget '["error"]["code"]')"
check "未知方法 → code 3（METHOD_NOT_FOUND）" "3" "$(sess nope '{}' | jget '["error"]["code"]')"

sess destroy '{}' >/dev/null
check "destroy 后 get → -32002（会话没了，前端先拦）" "-32002" "$(sess get '{}' | jget '["error"]["code"]')"
check "哨兵调 destroy → -32002（前端拦；对象级的 6 由单测覆盖）" "-32002" \
  "$(upost /ubus/call/session \
       -H 'Authorization: Bearer 00000000000000000000000000000000' \
       -d '{"jsonrpc":"2.0","id":4,"method":"destroy","params":{}}' \
     | jget '["error"]["code"]')"

# ---- P3-3 uci 对象 ----
echo
echo "== P3-3 uci 对象（S1 configs/get；S2 delta；S3 写操作；S4 apply 系）=="
USID=$(upost /ubus/call/session \
  -d '{"jsonrpc":"2.0","id":1,"method":"login","params":{"username":"root","password":"test1234"}}' \
  | jget '["result"]["ubus_rpc_session"]')

uci0() { upost /ubus/call/uci -d "$1"; }                                  # 无 Authorization → 哨兵会话
uci1() { upost /ubus/call/uci -H "Authorization: Bearer $USID" -d "$1"; }
usid1() { upost /ubus/call/session -H "Authorization: Bearer $USID" -d "$1"; }

USID2=$(upost /ubus/call/session \
  -d '{"jsonrpc":"2.0","id":1,"method":"login","params":{"username":"root","password":"test1234"}}' \
  | jget '["result"]["ubus_rpc_session"]')
uci2() { upost /ubus/call/uci -H "Authorization: Bearer $USID2" -d "$1"; }

check "哨兵读 uci → -32002（前端 ACL 先拦）" "-32002" \
  "$(uci0 '{"jsonrpc":"2.0","id":2,"method":"get","params":{"config":"network"}}' | jget '["error"]["code"]')"

cfg0=$(uci1 '{"jsonrpc":"2.0","id":3,"method":"configs"}')
check "configs 不检查对象级 ACL" "True" "$(jq1 "$cfg0" 'len(d["result"]["configs"]) > 0')"
check "configs 列出 config 名" "dhcp,empty-config,network,rpcd,system" \
  "$(jq1 "$cfg0" '",".join(sorted(d["result"]["configs"]))')"

usid1 '{"jsonrpc":"2.0","id":4,"method":"grant","params":{"scope":"uci","objects":[["network","read"]]}}' >/dev/null
check "只 grant 了 network：读 dhcp → code 6" "6" \
  "$(uci1 '{"jsonrpc":"2.0","id":14,"method":"get","params":{"config":"dhcp"}}' | jget '["error"]["code"]')"

pkg=$(uci1 '{"jsonrpc":"2.0","id":5,"method":"get","params":{"config":"network"}}')
check "get 整包：option 值" "static" "$(jq1 "$pkg" 'd["result"]["values"]["lan"]["proto"]')"
check "get 整包：.index 按整份配置的顺序（含被筛掉的）" "0,1,2" \
  "$(jq1 "$pkg" '",".join(str(d["result"]["values"][k][".index"]) for k in ["lan","wan","wg0"])')"
check "get 整包：.anonymous/.type 齐全" "False,interface" \
  "$(jq1 "$pkg" 'str(d["result"]["values"]["lan"][".anonymous"]) + "," + d["result"]["values"]["lan"][".type"]')"

sec=$(uci1 '{"jsonrpc":"2.0","id":6,"method":"get","params":{"config":"network","section":"lan"}}')
check "get section：.name/.type + option" "lan,interface,static" \
  "$(jq1 "$sec" 'd["result"]["values"][".name"] + "," + d["result"]["values"][".type"] + "," + d["result"]["values"]["proto"]')"
check "get section：不带 .index" "False" "$(jq1 "$sec" '".index" in d["result"]["values"]')"

check "get option：键是 value" "static" \
  "$(jq1 "$(uci1 '{"jsonrpc":"2.0","id":7,"method":"get","params":{"config":"network","section":"lan","option":"proto"}}')" 'd["result"]["value"]')"
check "get 扩展形式 @interface[1] → wan" "wan" \
  "$(jq1 "$(uci1 '{"jsonrpc":"2.0","id":8,"method":"get","params":{"config":"network","section":"@interface[1]"}}')" 'd["result"]["values"][".name"]')"
check "get type=interface：匿名 switch 被筛掉" "lan,wan,wg0" \
  "$(jq1 "$(uci1 '{"jsonrpc":"2.0","id":9,"method":"get","params":{"config":"network","type":"interface"}}')" '",".join(sorted(d["result"]["values"]))')"
check "get match proto=dhcp → 只有 wan" "wan" \
  "$(jq1 "$(uci1 '{"jsonrpc":"2.0","id":10,"method":"get","params":{"config":"network","match":{"proto":"dhcp"}}}')" '",".join(sorted(d["result"]["values"]))')"

check "缺 config → code 2（INVALID_ARGUMENT）" "2" \
  "$(uci1 '{"jsonrpc":"2.0","id":11,"method":"get","params":{}}' | jget '["error"]["code"]')"
check "未授权且 config 不存在 → 仍是 code 6（ACL 先于 load）" "6" \
  "$(uci1 '{"jsonrpc":"2.0","id":12,"method":"get","params":{"config":"nope"}}' | jget '["error"]["code"]')"
usid1 '{"jsonrpc":"2.0","id":16,"method":"grant","params":{"scope":"uci","objects":[["*","read"]]}}' >/dev/null
check "未知 config → code 4（NOT_FOUND）" "4" \
  "$(uci1 '{"jsonrpc":"2.0","id":12,"method":"get","params":{"config":"nope"}}' | jget '["error"]["code"]')"
check "未知 section → code 4" "4" \
  "$(uci1 '{"jsonrpc":"2.0","id":13,"method":"get","params":{"config":"network","section":"nope"}}' | jget '["error"]["code"]')"

# --- S2：changes（darwin 的假 delta：network 有 6 条，其中 1 条 section 为空要被丢掉）---
ch_all=$(uci1 '{"jsonrpc":"2.0","id":20,"method":"changes"}')
check "changes 不带 config：只列有 delta 的 config" "network" \
  "$(jq1 "$ch_all" '",".join(sorted(d["result"]["changes"]))')"
check "changes：section 为空的条目被丢掉" "5" \
  "$(jq1 "$ch_all" 'len(d["result"]["changes"]["network"])')"
check "changes 形状 [type,section,name,value]" \
  "set,lan,ipaddr,10.0.0.1,list-add,lan,dns,9.9.9.9,remove,wan,proto,order,lan,3,add,wg1" \
  "$(jq1 "$ch_all" '",".join(",".join(str(x) for x in e) for e in d["result"]["changes"]["network"])')"
check "changes：order 的 value 是数字（上游写 u32）" "int" \
  "$(jq1 "$ch_all" 'type(d["result"]["changes"]["network"][3][2]).__name__')"
check "changes 带 config → 数组" "5" \
  "$(jq1 "$(uci1 '{"jsonrpc":"2.0","id":21,"method":"changes","params":{"config":"network"}}')" 'len(d["result"]["changes"])')"
check "changes：没有 delta 的 config → 空数组（不是错误）" "0" \
  "$(jq1 "$(uci1 '{"jsonrpc":"2.0","id":22,"method":"changes","params":{"config":"system"}}')" 'len(d["result"]["changes"])')"
check "changes：不存在的 config → code 4" "4" \
  "$(uci1 '{"jsonrpc":"2.0","id":23,"method":"changes","params":{"config":"nope"}}' | jget '["error"]["code"]')"

# --- S2：state / commit / revert ---
check "state → code 8（darwin 无已提交态读取）" "8" \
  "$(uci1 '{"jsonrpc":"2.0","id":24,"method":"state","params":{"config":"network"}}' | jget '["error"]["code"]')"
check "未授权写：commit → code 6" "6" \
  "$(uci1 '{"jsonrpc":"2.0","id":25,"method":"commit","params":{"config":"network"}}' | jget '["error"]["code"]')"
usid1 '{"jsonrpc":"2.0","id":26,"method":"grant","params":{"scope":"uci","objects":[["*","write"]]}}' >/dev/null
check "授权写之后 commit → code 8（按决策写路径只在 linux 上实现）" "8" \
  "$(uci1 '{"jsonrpc":"2.0","id":27,"method":"commit","params":{"config":"network"}}' | jget '["error"]["code"]')"
check "revert 同理 → code 8" "8" \
  "$(uci1 '{"jsonrpc":"2.0","id":28,"method":"revert","params":{"config":"network"}}' | jget '["error"]["code"]')"

# --- S3：set / add 已实现（参数校验 → ACL → 平台能力）---
check "set（已授权）→ code 8（darwin 无写事务）" "8" \
  "$(uci1 '{"jsonrpc":"2.0","id":30,"method":"set","params":{"config":"network","section":"lan","values":{"proto":"static"}}}' | jget '["error"]["code"]')"
check "add（已授权）→ code 8" "8" \
  "$(uci1 '{"jsonrpc":"2.0","id":31,"method":"add","params":{"config":"network","type":"interface","name":"molly0"}}' | jget '["error"]["code"]')"
check "set 缺 values → code 2（校验先于一切）" "2" \
  "$(uci1 '{"jsonrpc":"2.0","id":32,"method":"set","params":{"config":"network","section":"lan"}}' | jget '["error"]["code"]')"
check "add 缺 type → code 2" "2" \
  "$(uci1 '{"jsonrpc":"2.0","id":33,"method":"add","params":{"config":"network"}}' | jget '["error"]["code"]')"
check "未授权会话 set → code 6" "6" \
  "$(uci2 '{"jsonrpc":"2.0","id":34,"method":"set","params":{"config":"network","section":"lan","values":{"proto":"static"}}}' | jget '["error"]["code"]')"

# --- S3：delete / rename / order 已实现（校验顺序同 set/add）---
check "delete 缺 section/type/match → code 2" "2" \
  "$(uci1 '{"jsonrpc":"2.0","id":40,"method":"delete","params":{"config":"network"}}' | jget '["error"]["code"]')"
check "rename 缺 name → code 2" "2" \
  "$(uci1 '{"jsonrpc":"2.0","id":41,"method":"rename","params":{"config":"network","section":"lan"}}' | jget '["error"]["code"]')"
check "order 的 sections 不是数组 → code 2" "2" \
  "$(uci1 '{"jsonrpc":"2.0","id":42,"method":"order","params":{"config":"network","sections":"lan"}}' | jget '["error"]["code"]')"
check "delete（已授权）→ code 8（darwin 无写事务）" "8" \
  "$(uci1 '{"jsonrpc":"2.0","id":43,"method":"delete","params":{"config":"network","section":"lan","options":["dns"]}}' | jget '["error"]["code"]')"
check "rename（已授权）→ code 8" "8" \
  "$(uci1 '{"jsonrpc":"2.0","id":44,"method":"rename","params":{"config":"network","section":"lan","name":"lan2"}}' | jget '["error"]["code"]')"
check "order（已授权）→ code 8" "8" \
  "$(uci1 '{"jsonrpc":"2.0","id":45,"method":"order","params":{"config":"network","sections":["wan","lan"]}}' | jget '["error"]["code"]')"
check "未授权会话 delete（含非法 section）→ code 6" "6" \
  "$(uci2 '{"jsonrpc":"2.0","id":46,"method":"delete","params":{"config":"network","section":"lan[0]"}}' | jget '["error"]["code"]')"

# --- S4：apply 系（apply / confirm / rollback / reload_config）---
check "confirm（无待确认 apply）→ code 5（NO_DATA）" "5" \
  "$(uci1 '{"jsonrpc":"2.0","id":50,"method":"confirm"}' | jget '["error"]["code"]')"
check "rollback（无待确认 apply）→ code 5" "5" \
  "$(uci1 '{"jsonrpc":"2.0","id":51,"method":"rollback"}' | jget '["error"]["code"]')"
check "apply（该会话没有 delta）→ code 4（NOT_FOUND）" "4" \
  "$(uci1 '{"jsonrpc":"2.0","id":52,"method":"apply"}' | jget '["error"]["code"]')"
check "apply rollback=true 且无待确认 → 先列 delta 目录 → code 4" "4" \
  "$(uci1 '{"jsonrpc":"2.0","id":53,"method":"apply","params":{"rollback":true,"timeout":60}}' | jget '["error"]["code"]')"
check "reload_config → code 8（darwin 不 fork）" "8" \
  "$(uci1 '{"jsonrpc":"2.0","id":54,"method":"reload_config"}' | jget '["error"]["code"]')"

# ---- P3-4 file 对象 ----
echo
echo "== P3-4 file 对象（路径/权限核心 + read/stat/lstat/list/md5/write/remove）=="
FILE_USID=$(upost /ubus/call/session \
  -d '{"jsonrpc":"2.0","id":1,"method":"login","params":{"username":"root","password":"test1234"}}' \
  | jget '["result"]["ubus_rpc_session"]')

file0() { upost /ubus/call/file -d "$1"; }
file1() { upost /ubus/call/file -H "Authorization: Bearer $FILE_USID" -d "$1"; }
fsid1() { upost /ubus/call/session -H "Authorization: Bearer $FILE_USID" -d "$1"; }

check "缺 path → code 2" "2" \
  "$(file1 '{"jsonrpc":"2.0","id":3,"method":"read","params":{}}' | jget '["error"]["code"]')"

rm -rf /private/tmp/molly-file-dir
mkdir -p /private/tmp/molly-file-dir
printf 'molly-p3-4\n' > /private/tmp/molly-file-dir/probe.txt

# 只授 read+write（不授 list）：md5（"read"）和 write（"write"）放行，stat（"list"）被拒。
fsid1 '{"jsonrpc":"2.0","id":4,"method":"grant","params":{"scope":"file","objects":[["/private/tmp/*","read"],["/private/tmp/*","write"]]}}' >/dev/null

check "无权限读 /etc/hosts → code 6" "6" \
  "$(file1 '{"jsonrpc":"2.0","id":5,"method":"read","params":{"path":"/etc/hosts"}}' | jget '["error"]["code"]')"
check "路径规范化：/tmp/../etc/hosts → code 6" "6" \
  "$(file1 '{"jsonrpc":"2.0","id":7,"method":"read","params":{"path":"/tmp/../etc/hosts"}}' | jget '["error"]["code"]')"

check "md5 授权内文件（权限名 read）" "True" \
  "$(jq1 "$(file1 '{"jsonrpc":"2.0","id":8,"method":"md5","params":{"path":"/private/tmp/molly-file-dir/probe.txt"}}')" 'd["result"]["md5"] == "'"$(md5 -q /private/tmp/molly-file-dir/probe.txt)"'"')"
check "md5 对目录 → code 8（上游只认普通文件）" "8" \
  "$(file1 '{"jsonrpc":"2.0","id":9,"method":"md5","params":{"path":"/private/tmp/molly-file-dir"}}' | jget '["error"]["code"]')"

check "write 新建文件（权限名 write）" "True" \
  "$(jq1 "$(file1 '{"jsonrpc":"2.0","id":10,"method":"write","params":{"path":"/private/tmp/molly-file-dir/new.txt","data":"hello write"}}')" '"error" not in d')"
check "write 写出的内容可读回" "hello write" \
  "$(jq1 "$(file1 '{"jsonrpc":"2.0","id":11,"method":"read","params":{"path":"/private/tmp/molly-file-dir/new.txt"}}')" 'd["result"]["data"]')"
check "write append 不截断" "hello write+more" \
  "$(jq1 "$(file1 '{"jsonrpc":"2.0","id":12,"method":"write","params":{"path":"/private/tmp/molly-file-dir/new.txt","data":"+more","append":true}}' >/dev/null ; file1 '{"jsonrpc":"2.0","id":13,"method":"read","params":{"path":"/private/tmp/molly-file-dir/new.txt"}}')" 'd["result"]["data"]')"
check "write 缺 data → code 2" "2" \
  "$(file1 '{"jsonrpc":"2.0","id":14,"method":"write","params":{"path":"/private/tmp/molly-file-dir/new.txt"}}' | jget '["error"]["code"]')"
check "write base64 解码" "b64-ok" \
  "$(jq1 "$(file1 '{"jsonrpc":"2.0","id":15,"method":"write","params":{"path":"/private/tmp/molly-file-dir/b64.txt","data":"YjY0LW9r","base64":true}}' >/dev/null ; file1 '{"jsonrpc":"2.0","id":16,"method":"read","params":{"path":"/private/tmp/molly-file-dir/b64.txt"}}')" 'd["result"]["data"]')"

# P3-6 起登录会话带 acl.d 的 ACL：fixture 的 luci-base 授了 file 的 "/*" → list，
# 所以要造「拒绝」场景得先把整个 file scope 撤掉（revoke 不带 objects = 清空 scope）。
fsid1 '{"jsonrpc":"2.0","id":18,"method":"revoke","params":{"scope":"file"}}' >/dev/null
check "清空 file scope：stat → code 6（stat 的权限名是 list！）" "6" \
  "$(file1 '{"jsonrpc":"2.0","id":17,"method":"stat","params":{"path":"/private/tmp/molly-file-dir/probe.txt"}}' | jget '["error"]["code"]')"
check "清空 file scope：list → code 6" "6" \
  "$(file1 '{"jsonrpc":"2.0","id":18,"method":"list","params":{"path":"/private/tmp/molly-file-dir"}}' | jget '["error"]["code"]')"
check "清空 file scope：read → code 6" "6" \
  "$(file1 '{"jsonrpc":"2.0","id":18,"method":"read","params":{"path":"/private/tmp/molly-file-dir/probe.txt"}}' | jget '["error"]["code"]')"

fsid1 '{"jsonrpc":"2.0","id":19,"method":"grant","params":{"scope":"file","objects":[["/private/tmp/*","read"],["/private/tmp/*","write"],["/private/tmp/*","list"]]}}' >/dev/null

st=$(file1 '{"jsonrpc":"2.0","id":20,"method":"stat","params":{"path":"/private/tmp/molly-file-dir/probe.txt"}}')
check "stat：type/size/path" "file,11,/private/tmp/molly-file-dir/probe.txt" \
  "$(jq1 "$st" 'd["result"]["type"] + "," + str(d["result"]["size"]) + "," + d["result"]["path"]')"
check "stat：mode 含类型位（0o100644=33188）" "33188" \
  "$(jq1 "$st" 'd["result"]["mode"]')"

rm -f /private/tmp/molly-file-dir/link
ln -s probe.txt /private/tmp/molly-file-dir/link
check "lstat 符号链接 → type=symlink（不解析）" "symlink" \
  "$(jq1 "$(file1 '{"jsonrpc":"2.0","id":21,"method":"lstat","params":{"path":"/private/tmp/molly-file-dir/link"}}')" 'd["result"]["type"]')"
check "stat 符号链接 → 跟随到目标（file）" "file" \
  "$(jq1 "$(file1 '{"jsonrpc":"2.0","id":22,"method":"stat","params":{"path":"/private/tmp/molly-file-dir/link"}}')" 'd["result"]["type"]')"

lst=$(file1 '{"jsonrpc":"2.0","id":23,"method":"list","params":{"path":"/private/tmp/molly-file-dir"}}')
check "list：条目齐（. / .. 被跳过）" "True" \
  "$(jq1 "$lst" 'sorted(e["name"] for e in d["result"]["entries"]) == ["b64.txt","link","new.txt","probe.txt"]')"
check "list：符号链接条目带 target（name+type）" "probe.txt,file" \
  "$(jq1 "$lst" '(lambda e: e["target"]["name"] + "," + e["target"]["type"])(next(e for e in d["result"]["entries"] if e["name"]=="link"))')"
check "list 对普通文件 → code 2（opendir ENOTDIR）" "2" \
  "$(file1 '{"jsonrpc":"2.0","id":24,"method":"list","params":{"path":"/private/tmp/molly-file-dir/probe.txt"}}' | jget '["error"]["code"]')"
check "list 不存在的目录 → code 4" "4" \
  "$(file1 '{"jsonrpc":"2.0","id":25,"method":"list","params":{"path":"/private/tmp/molly-file-dir/nope"}}' | jget '["error"]["code"]')"

check "remove 文件（权限名 write）" "True" \
  "$(jq1 "$(file1 '{"jsonrpc":"2.0","id":26,"method":"remove","params":{"path":"/private/tmp/molly-file-dir/new.txt"}}')" '"error" not in d')"
check "remove 后 read → code 4" "4" \
  "$(file1 '{"jsonrpc":"2.0","id":27,"method":"read","params":{"path":"/private/tmp/molly-file-dir/new.txt"}}' | jget '["error"]["code"]')"
check "remove 递归删除目录" "True" \
  "$(jq1 "$(file1 '{"jsonrpc":"2.0","id":28,"method":"remove","params":{"path":"/private/tmp/molly-file-dir"}}')" '"error" not in d')"
check "remove 后 stat → code 4" "4" \
  "$(file1 '{"jsonrpc":"2.0","id":29,"method":"stat","params":{"path":"/private/tmp/molly-file-dir"}}' | jget '["error"]["code"]')"

rm -rf /private/tmp/molly-file-dir2
mkdir -p /private/tmp/molly-file-dir2
ln -s /etc/hosts /private/tmp/molly-file-dir2/escape
check "符号链接指向授权外 → code 6（复查 realpath）" "6" \
  "$(file1 '{"jsonrpc":"2.0","id":30,"method":"read","params":{"path":"/private/tmp/molly-file-dir2/escape"}}' | jget '["error"]["code"]')"
rm -rf /private/tmp/molly-file-dir2

check "exec 带 env + 会话 → code 6" "6" \
  "$(file1 '{"jsonrpc":"2.0","id":31,"method":"exec","params":{"command":"echo","env":{"A":"1"}}}' | jget '["error"]["code"]')"
check "exec 未授权 → code 6" "6" \
  "$(file1 '{"jsonrpc":"2.0","id":32,"method":"exec","params":{"command":"echo"}}' | jget '["error"]["code"]')"
check "exec 不存在的命令 → code 4（PATH 找不到）" "4" \
  "$(file1 '{"jsonrpc":"2.0","id":33,"method":"exec","params":{"command":"molly-definitely-not-here"}}' | jget '["error"]["code"]')"

fsid1 '{"jsonrpc":"2.0","id":34,"method":"grant","params":{"scope":"file","objects":[["/bin/echo","exec"]]}}' >/dev/null
ex=$(file1 '{"jsonrpc":"2.0","id":35,"method":"exec","params":{"command":"echo","params":["hello exec"]}}')
check "exec echo：code 0 + stdout" "0,hello exec" \
  "$(jq1 "$ex" 'str(d["result"]["code"]) + "," + d["result"]["stdout"].strip()')"

FS_USID2=$(upost /ubus/call/session \
  -d '{"jsonrpc":"2.0","id":36,"method":"login","params":{"username":"root","password":"test1234"}}' \
  | jget '["result"]["ubus_rpc_session"]')
file2() { upost /ubus/call/file -H "Authorization: Bearer $FS_USID2" -d "$1"; }
f2sid() { upost /ubus/call/session -H "Authorization: Bearer $FS_USID2" -d "$1"; }
f2sid '{"jsonrpc":"2.0","id":37,"method":"grant","params":{"scope":"file","objects":[["/bin/echo only-this","exec"]]}}' >/dev/null
check "命令行 ACL：精确串匹配 → 放行" "only-this" \
  "$(jq1 "$(file2 '{"jsonrpc":"2.0","id":38,"method":"exec","params":{"command":"echo","params":["only-this"]}}')" 'd["result"]["stdout"].strip()')"
check "命令行 ACL：参数不同 → code 6" "6" \
  "$(file2 '{"jsonrpc":"2.0","id":39,"method":"exec","params":{"command":"echo","params":["other"]}}' | jget '["error"]["code"]')"

# ---- P3-5 luci-rpc 对象 ----
echo
echo "== P3-5 luci-rpc 对象（S1：getBoardJSON / getDHCPLeases）=="
printf '4000000000 aa:bb:cc:dd:ee:ff 192.168.1.123 phone 01:11:22:33:44:55:66\n' > /tmp/molly-dhcp.leases
printf '# br-lan 0001000100004c1faabbccddeeff 1 host6 4000000000 0 128 fd00::1234\n' > /tmp/molly-odhcpd.leases

lc() { upost /ubus/call/luci-rpc -H "Authorization: Bearer $P2SID" -d "$1"; }

check "getBoardJSON：model 名" "Molly Mock Board" \
  "$(jq1 "$(lc '{"jsonrpc":"2.0","id":1,"method":"getBoardJSON"}')" 'd["result"]["model"]["name"]')"
check "getBoardJSON：network.lan.protocol" "static" \
  "$(jq1 "$(lc '{"jsonrpc":"2.0","id":1,"method":"getBoardJSON"}')" 'd["result"]["network"]["lan"]["protocol"]')"

lb4=$(lc '{"jsonrpc":"2.0","id":2,"method":"getDHCPLeases","params":{"family":4}}')
check "getDHCPLeases family=4：只有 dhcp_leases 键" "True" \
  "$(jq1 "$lb4" '"dhcp6_leases" not in d["result"]')"
check "family=4：v4 条目字段" "aa:bb:cc:dd:ee:ff,phone,192.168.1.123" \
  "$(jq1 "$lb4" 'd["result"]["dhcp_leases"][0]["macaddr"] + "," + d["result"]["dhcp_leases"][0]["hostname"] + "," + d["result"]["dhcp_leases"][0]["ipaddr"]')"
check "family=4：01: 前缀 clientid 不覆盖行内 MAC（上游 if(!ea)）" "aa:bb:cc:dd:ee:ff" \
  "$(jq1 "$lb4" 'd["result"]["dhcp_leases"][0]["macaddr"]')"
check "family=4：expires 是正数（未到期）" "True" \
  "$(jq1 "$lb4" 'd["result"]["dhcp_leases"][0]["expires"] > 0')"

lb6=$(lc '{"jsonrpc":"2.0","id":3,"method":"getDHCPLeases","params":{"family":6}}')
check "family=6：只有 dhcp6_leases 键" "True" \
  "$(jq1 "$lb6" '"dhcp_leases" not in d["result"]')"
check "family=6：odhcpd 条目" "br-lan,fd00::1234,aa:bb:cc:dd:ee:ff" \
  "$(jq1 "$lb6" 'd["result"]["dhcp6_leases"][0]["interface"] + "," + d["result"]["dhcp6_leases"][0]["ip6addr"] + "," + d["result"]["dhcp6_leases"][0]["macaddr"]')"

lb0=$(lc '{"jsonrpc":"2.0","id":4,"method":"getDHCPLeases"}')
check "family 缺省 → 两个键都有" "True" \
  "$(jq1 "$lb0" '"dhcp_leases" in d["result"] and "dhcp6_leases" in d["result"]')"
check "family 类型不符 → 当作缺省（两键都有）" "True" \
  "$(jq1 "$(lc '{"jsonrpc":"2.0","id":5,"method":"getDHCPLeases","params":{"family":"4"}}')" '"dhcp_leases" in d["result"] and "dhcp6_leases" in d["result"]')"
check "family=5 → code 2" "2" \
  "$(lc '{"jsonrpc":"2.0","id":6,"method":"getDHCPLeases","params":{"family":5}}' | jget '["error"]["code"]')"

lh=$(lc '{"jsonrpc":"2.0","id":8,"method":"getDUIDHints"}')
check "getDUIDHints：key 是 duid%iaid" "True" \
  "$(jq1 "$lh" '"0001000100004c1faabbccddeeff%1" in d["result"]')"
check "getDUIDHints：条目字段" "br-lan,0001000100004c1faabbccddeeff,1,host6,aa:bb:cc:dd:ee:ff" \
  "$(jq1 "$lh" '(lambda e: e["interface"] + "," + e["duid"] + "," + e["iaid"] + "," + e["hostname"] + "," + e["macaddr"])(d["result"]["0001000100004c1faabbccddeeff%1"])')"
check "getDUIDHints：v4 租约不出现" "True" \
  "$(jq1 "$lh" 'all("phone" != e.get("hostname") for e in d["result"].values())')"

for m in getNetworkDevices getWirelessDevices getHostHints; do
  lbody2=$(printf '{"jsonrpc":"2.0","id":9,"method":"%s"}' "$m")
  check "luci-rpc.$m linux-only → darwin 回 code 8" "8" "$(lc "$lbody2" | jget '["error"]["code"]')"
done
rm -f /tmp/molly-dhcp.leases /tmp/molly-odhcpd.leases

# ---- 专家版前缀可配（--luci-prefix）+ 两套界面共存 ----
#
# 再起一份实例，把专家版让到 /plus（本站部署形态）。目的是钉住「前缀是一个同源值」：
# 它同时是路由判据、CGI 的 SCRIPT_NAME、以及新手版页面上注入的链接——任何一处不同步
# 都会在这里露馅（比如只改了路由，页面里还链到 /cgi-bin/luci）。
PREFIX_PORT="${PREFIX_PORT:-18086}"
start_server "$PREFIX_PORT" --luci-prefix /plus --luci-strip admin
B2="http://127.0.0.1:$PREFIX_PORT"
for _ in $(seq 1 30); do
  if curl -s -o /dev/null "$B2/"; then break; fi
  sleep 0.1
done
# 会话是**进程内**的，第二份实例要自己登一个；cookie 用专家版补丁后的专属名
SID3=$(curl -s -X POST "$B2/ubus/call/session" \
  -d '{"jsonrpc":"2.0","id":1,"method":"login","params":{"username":"root","password":"test1234"}}' \
  | jget '["result"]["ubus_rpc_session"]')
check "新前缀实例能拿到会话" "32" "${#SID3}"
COOKIE3="sysauth_molly=$SID3"
check "新前缀 /plus/ 有菜单页" "200" \
  "$(curl -s -o /dev/null -w '%{http_code}' -b "$COOKIE3" "$B2/plus/")"
# 自研站点是**单页应用**：根路径与任何子路径都回同一份 HTML，导航在 #/ 片段里。
# 所以这里断言「根与子路径给的是同一份页面」，而不是内置 dispatcher 那套 firstchild 语义。
check "自研站点：根与子路径同一份页面" "same" \
  "$([ "$(curl -s -b "$COOKIE3" "$B2/plus/" | wc -c)" = "$(curl -s -b "$COOKIE3" "$B2/plus/status/overview" | wc -c)" ] && echo same || echo differ)"
# --luci-strip admin：URL 里省掉顶层 admin 节点，进树时自动补回
check "短写法 /plus/status/overview" "200" \
  "$(curl -s -o /dev/null -w '%{http_code}' -b "$COOKIE3" "$B2/plus/status/overview")"
# 长写法（带 admin）同样回页面：单页语义下没有"长短"之分，链接都靠前端片段。
check "长写法 /plus/admin/status/overview" "200" \
  "$(curl -s -o /dev/null -w '%{http_code}' -b "$COOKIE3" "$B2/plus/admin/status/overview")"
# 未登录：页面照给（里面自己弹登录卡），这不是 403——403 是 LuCI 那套的语义。
check "未登录也出页面（前端弹登录）" "200" \
  "$(curl -s -o /dev/null -w '%{http_code}' "$B2/plus/")"
# 旧前缀不再由 dispatcher 服务，而且**也不会退化成静态下载**：docroot 里的 /cgi-bin/*
# 一律 403（上游 uhttpd 只执行它、从不吐脚本正文；见 internal/handlers/static.go）。
check "旧前缀不再由 dispatcher 服务" "403" \
  "$(curl -s -o /dev/null -w '%{http_code}' -b "$COOKIE3" "$B2/cgi-bin/luci/")"
check "docroot 的 /cgi-bin/* 不外发" "403" \
  "$(curl -s -o /dev/null -w '%{http_code}' "$B2/cgi-bin/luci")"
check "docroot 的 /cgi-bin 本身也拒绝" "403" \
  "$(curl -s -o /dev/null -w '%{http_code}' "$B2/cgi-bin")"
# 前缀是否真的贯穿到页面：新手版页里那句 JS 常量应当就是新前缀
check "新手版注入的是新前缀" "1" \
  "$(curl -s "$B2/lite/" | grep -c 'EXPERT_PREFIX = "/plus"' || true)"
check "新手版仍在 /lite/" "200" "$(curl -s -o /dev/null -w '%{http_code}' "$B2/lite/")"
# 这份实例是**默认渲染方式**（app = 自研站点），所以专家版前缀下应该是我们的页面：
check "专家版前缀发的是自研站点" "200" "$(curl -s -o /dev/null -w '%{http_code}' "$B2/plus/")"
check "自研站点：占位符已替换" "0" "$(curl -s "$B2/plus/" | grep -c '__SID__\|__MENU__' || true)"
check "自研站点：菜单来自二进制" "1" "$(curl -s "$B2/plus/" | grep -c '"id":"dash","title":"仪表盘"' || true)"
check "自研站点：无 LuCI/ucode 痕迹" "0" "$(curl -s "$B2/plus/" | grep -ciE 'luci-static|bootstrap|require ucode' || true)"
check "自研站点：子路径回同一份（单页）" "200" "$(curl -s -o /dev/null -w '%{http_code}' "$B2/plus/status/overview")"
# 十个页面都注册了、且菜单里没有「建设中」的灰项——菜单与页面脱节是最容易犯的错。
EXP=$(curl -s "$B2/plus/")
check "自研站点：注册了 10 个页面" "10" "$(printf '%s' "$EXP" | grep -c 'PAGES\.[a-z]*=')"
check "自研站点：菜单 10 项全部就绪" "0" "$(printf '%s' "$EXP" | grep -c '"ready":false')"
# 菜单 id 与页面 key 必须一一对应（否则点菜单会落进「建设中」）
check "自研站点：菜单与页面一一对应" "same" \
  "$([ "$(printf '%s' "$EXP" | grep -o 'PAGES\.[a-z]*=' | sed 's/PAGES\.//;s/=//' | sort | tr '\n' ' ')" \
       = "$(printf '%s' "$EXP" | grep -o '"id":"[a-z]*","title":"[^"]*","ready":true' | sed 's/"id":"//;s/","title".*//' | sort | tr '\n' ' ')" ] \
     && echo same || echo differ)"
# 未登录时 sid 必须是**空串**（页面据此跳登录页）。要防的是两件事：占位符没被替换、
# 或者空值变成了 anon 会话 id —— 后者会让未登录的人以为已登录。
# 登录遮罩必须能被 hidden 属性藏掉：.lg 用了 display:flex（作者样式），优先级高于
# hidden 自带的 UA display:none —— 少了 [hidden]{display:none!important} 遮罩会常驻，
# 表现为「登录成功后仍有一层登录框」。这是纯 CSS，curl 看不见，只能断言规则在。
check "自研站点：登录遮罩可被 hidden 藏掉（CSS 规则）" "1" \
  "$(printf '%s' "$EXP" | grep -c '\[hidden\]{display:none!important}')"

check "自研站点：未登录时注入空 sid" "yes" \
  "$(curl -s "$B2/plus/" | grep -q 'SID=""' && echo yes || echo no)"
check "自研站点：未登录时不注入 anon 会话" "yes" \
  "$(curl -s "$B2/plus/" | grep -q 'SID="0\{32\}"' && echo no || echo yes)"
# / 是入口：302 到 /lite/（302 而不是 301：前缀以后还可能再挪）
check "/ 仍是入口 → 302 /lite/" "/lite/" "$(header_of Location "$B2/")"

echo
# 全角标点紧跟变量必须用 ${}：bash 会把多字节标点的字节当成变量名的一部分
echo "通过 ${PASS}，失败 ${FAIL}"
[[ "$FAIL" -eq 0 ]] || exit 1