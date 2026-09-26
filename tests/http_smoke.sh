#!/usr/bin/env bash
# 第 2–5 步验收：请求解析、keep-alive、各类上限与错误码、静态文件、/ubus 路由与
# JSON-RPC 协议层（旧式 POST /ubus + 新式 POST /ubus/call/<path>）。
#
# 为什么在 macOS 上能测：HTTP 层与路由是平台无关代码，只有 uci/ubus 走
# src/backend/darwin.odin 的假数据。所以这里跑的解析器与真机上是同一份。
#
# 用法：./tests/http_smoke.sh [端口]
#   默认端口 18080（8080 常被别的服务占着）。
#   脚本会自己起 build/molly-host，跑完杀掉。

set -uo pipefail
cd "$(dirname "$0")/.."

PORT="${1:-18080}"
BASE="http://127.0.0.1:$PORT"
BIN="build/molly-host"

if [[ ! -x "$BIN" ]]; then
  echo "先跑 ./build.sh --host" >&2
  exit 1
fi

"$BIN" --listen "127.0.0.1:$PORT" --docroot tests/fixtures/www --menu-dir tests/fixtures/menu.d >/tmp/molly-smoke.log 2>&1 &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null' EXIT

# 等端口起来（最多 3 秒）
for _ in $(seq 1 30); do
  if curl -s -o /dev/null "$BASE/"; then break; fi
  sleep 0.1
done

PASS=0
FAIL=0

# check <用例名> <期望> <实际>
check() {
  if [[ "$2" == "$3" ]]; then
    printf '  ok   %-46s %s\n' "$1" "$3"
    PASS=$((PASS + 1))
  else
    printf '  FAIL %-46s 期望 %s，实际 %s\n' "$1" "$2" "$3"
    FAIL=$((FAIL + 1))
  fi
}

# status_of <curl 参数...> —— 只回状态码
status_of() {
  curl -s -o /dev/null -w '%{http_code}' "$@"
}

# header_of <头名> <curl 参数...> —— 只回某个响应头的值
header_of() {
  local name="$1"; shift
  curl -sD- -o /dev/null "$@" | tr -d '\r' | sed -n "s/^${name}: //p"
}

# ubus_post <路径> <JSON 正文> [curl 额外参数...] —— POST 一个 JSON-RPC 请求
ubus_post() {
  local path="$1"; shift
  local body="$1"; shift
  curl -s -X POST "$@" -d "$body" "$BASE$path"
}

# jq1 <JSON 文本> <python 表达式> —— d 是解析后的对象，用来取字段/错误码
jq1() {
  python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(eval(sys.argv[2]))' "$1" "$2"
}

# h1_of <curl 参数...> —— 占位页的标题（<h1> 文本）
h1_of() {
  curl -s "$@" | grep -o '<h1>[^<]*</h1>' | head -1 | sed 's/<[^>]*>//g'
}

# view_of <curl 参数...> —— 占位页里 <dt>view</dt><dd>…</dd> 的值（= 生效的 action.path）
view_of() {
  curl -s "$@" | grep -o '<dt>view</dt><dd>[^<]*</dd>' | head -1 \
    | sed 's/^<dt>view<\/dt><dd>//; s/<\/dd>$//'
}

echo "== 基本响应 =="
out=$(curl -s -D- "$BASE/")
check "状态行" "HTTP/1.1 200 OK" "$(printf '%s' "$out" | head -1 | tr -d '\r')"
check "Content-Length" "13" "$(printf '%s' "$out" | awk '/^Content-Length/{print $2}' | tr -d '\r')"
check "body" "hello, molly" "$(curl -s "$BASE/")"

echo
echo "== keep-alive =="
# 同一条连接上发两个请求，curl -v 会出现 Re-using existing connection
reuse=$(curl -sv "$BASE/" "$BASE/" 2>&1 | grep -ci 'Re-using existing connection')
check "两个请求复用同一连接" "1" "$reuse"
check "HTTP/1.1 声明 keep-alive" "keep-alive" \
  "$(curl -s -D- -o/dev/null "$BASE/" | awk '/^Connection/{print $2}' | tr -d '\r')"
check "HTTP/1.0 默认关闭" "close" \
  "$(curl -s -D- -o/dev/null --http1.0 "$BASE/" | awk '/^Connection/{print $2}' | tr -d '\r')"

echo
echo "== HEAD =="
check "HEAD 状态 200" "200" "$(status_of -I "$BASE/")"
check "HEAD 不回 body" "0" "$(curl -s -I "$BASE/" | awk 'BEGIN{b=0} /^\r?$/{f=1;next} f{b+=length($0)+1} END{print b}')"

echo
echo "== 上限与错误码 =="
big_header=$(python3 -c 'print("a"*9000)')
check "请求头超 8KB → 413" "413" "$(status_of -H "X-Big: $big_header" "$BASE/")"
check "chunked → 411" "411" "$(status_of -X POST -H 'Transfer-Encoding: chunked' "$BASE/")"
check "POST 无 Content-Length → 411" "411" "$(status_of -X POST -H 'Content-Length:' "$BASE/")"
check "Content-Length 超 64KB → 413" "413" "$(status_of -X POST -H 'Content-Length: 100000' "$BASE/")"
check "Content-Length 非数字 → 400" "400" "$(status_of -X POST -H 'Content-Length: abc' "$BASE/")"
check "目标不是 / 开头 → 400" "400" "$(status_of --request-target '*' "$BASE/")"

echo
echo "== 请求体 =="
# 第 3 步起 / 走静态文件，非 GET/HEAD 一律 405。这两条要看的是 body 被完整收下
# （不报 400/411/413），以及收完之后连接还能继续用，不是业务状态码本身。
check "POST 64KB body 被完整接收" "405" \
  "$(status_of -X POST --data-binary "$(python3 -c 'print("b"*65536)')" "$BASE/")"
check "POST 小 body 被完整接收" "405" "$(status_of -X POST -d 'hello' "$BASE/")"

echo
echo "== 静态文件 =="
# 目录 → index.html；/luci-static/* 天然落在 <docroot>/luci-static/*，不需要别名
check "/ 回落 index.html" "200" "$(status_of "$BASE/")"
check "/index.html" "200" "$(status_of "$BASE/index.html")"
check "html Content-Type" "text/html; charset=utf-8" "$(header_of Content-Type "$BASE/index.html")"
check "/luci-static/*.css" "200" "$(status_of "$BASE/luci-static/test.css")"
check "css Content-Type" "text/css; charset=utf-8" "$(header_of Content-Type "$BASE/luci-static/test.css")"
check "深层目录映射" "200" "$(status_of "$BASE/luci-static/sub/note.txt")"
check "txt Content-Type" "text/plain; charset=utf-8" "$(header_of Content-Type "$BASE/luci-static/sub/note.txt")"
check "未命中 → 404" "404" "$(status_of "$BASE/nope")"
check "目录无 index.html → 404" "404" "$(status_of "$BASE/luci-static/")"
check "文件上的 POST → 405" "405" "$(status_of -X POST -d '' "$BASE/index.html")"

echo
echo "== /ubus GET 路由与 list 正文 =="
# 形状按上游 uhttpd 的 ubus 插件（ubus.c）复刻，见计划「已验证的事实」。
# POST 的两种形态在下面的 JSON-RPC 段；GET /ubus/subscribe 按决策 8 留到 P3（501）。
list_all=$(curl -s "$BASE/ubus/list")
list_sess=$(curl -s "$BASE/ubus/list/session")
check "GET /ubus/list → 200" "200" "$(status_of "$BASE/ubus/list")"
check "list Content-Type" "application/json" "$(header_of Content-Type "$BASE/ubus/list")"
check "list 是合法 JSON 且对象齐全" "file,luci,session,uci" \
  "$(python3 -c 'import json,sys; print(",".join(sorted(json.loads(sys.argv[1]))))' "$list_all")"
# uhttpd 的类型映射表只有这六个取值，多一个都说明形状跑偏了
check "参数类型只用六种取值" "ok" \
  "$(python3 -c '
import json,sys
ok={"boolean","number","string","array","object","unknown"}
d=json.loads(sys.argv[1])
bad=[(o,m,a,t) for o,ms in d.items() for m,args in ms.items() for a,t in args.items() if t not in ok]
print("ok" if not bad else bad[:1])' "$list_all")"
# GET /ubus/list 里的 <path> 段与 GET /ubus/list/<path> 必须是同一份签名
check "list 内嵌 session 与 list/session 一致" "true" \
  "$(python3 -c 'import json,sys; print("true" if json.loads(sys.argv[1])["session"] == json.loads(sys.argv[2]) else "false")' \
      "$list_all" "$list_sess")"
check "list/session 含 login" "200" \
  "$(python3 -c 'import json,sys; print("200" if "login" in json.loads(sys.argv[1]) else "缺 login")' "$list_sess")"
check "未知对象 → 500" "500" "$(status_of "$BASE/ubus/list/nope")"
check "500 正文是 JSON" "application/json" "$(header_of Content-Type "$BASE/ubus/list/nope")"
check "GET /ubus → 404" "404" "$(status_of "$BASE/ubus")"
check "GET /ubus/<其它> → 404" "404" "$(status_of "$BASE/ubus/nope")"
check "GET /ubus/subscribe/* → 501" "501" "$(status_of "$BASE/ubus/subscribe/foo")"
check "OPTIONS /ubus → 200" "200" "$(status_of -X OPTIONS "$BASE/ubus")"
check "OPTIONS 的 Content-Length 为 0" "0" "$(header_of Content-Length -X OPTIONS "$BASE/ubus")"
# 上游的 ubus 插件只认 GET / POST / OPTIONS，其余一律 400
check "HEAD /ubus → 400" "400" "$(status_of -I "$BASE/ubus")"
# 前缀边界：裸 has_prefix 会把 /ubus-probe.txt 判给 ubus 路由，静态文件就送不出去
check "前缀边界 /ubus-probe.txt → 静态文件" "200" "$(status_of "$BASE/ubus-probe.txt")"

echo
echo "== /ubus 旧式 POST（JSON-RPC 协议层）=="
# 逐条对齐上游 ubus.c：result 恒为 [ret,{...}] 数组；解析/方法/对象/参数四类错误
# 进 error 字段；HTTP 状态码恒为 200（上游在 invoke 之前就把响应头发掉了）。
sid0="00000000000000000000000000000000"
# 「透传探针」：拿一个**还没被 molly 接管**的对象来验 handler 把 object/method/sid/params
# 原样送到了对象。session（P3-2）、uci（P3-3）都已是真实现，所以现在用 file/list——
# P3-4 接管 file 时，这里的落点要换成下一个还是假数据的对象（luci），届时同步改。
legacy_call='{"jsonrpc":"2.0","id":1,"method":"call","params":["'"$sid0"'","file","list",{"path":"/etc/hosts"}]}'
r=$(ubus_post /ubus "$legacy_call")
check "旧式 POST 状态 200" "200" "$(status_of -X POST -d "$legacy_call" "$BASE/ubus")"
check "旧式 POST Content-Type" "application/json" "$(header_of Content-Type -X POST -d "$legacy_call" "$BASE/ubus")"
check "旧式 result 是数组 [0,…]" "0" "$(jq1 "$r" 'd["result"][0]')"
check "旧式回显 object" "luci" "$(jq1 "$r" 'd["result"][1]["echo"]["object"]')"
check "旧式回显 method" "getBoardJSON" "$(jq1 "$r" 'd["result"][1]["echo"]["method"]')"
check "旧式 sid 取 params[0]" "$sid0" "$(jq1 "$r" 'd["result"][1]["echo"]["sid"]')"
check "id 原样回显" "1" "$(jq1 "$r" 'd["id"]')"
check "缺 id 时回 null" "True" \
  "$(jq1 "$(ubus_post /ubus '{"jsonrpc":"2.0","method":"list"}')" 'd["id"] is None')"

# --- 错误码 ---
check "未知对象 → -32000" "-32000" \
  "$(jq1 "$(ubus_post /ubus '{"jsonrpc":"2.0","id":2,"method":"call","params":["","nope","list",{}]}')" 'd["error"]["code"]')"
check "未知方法 → -32601" "-32601" \
  "$(jq1 "$(ubus_post /ubus '{"jsonrpc":"2.0","id":3,"method":"frob"}')" 'd["error"]["code"]')"
check "jsonrpc 非 2.0 → -32700" "-32700" \
  "$(jq1 "$(ubus_post /ubus '{"jsonrpc":"1.0","id":4,"method":"list"}')" 'd["error"]["code"]')"
check "params 不足四项 → -32700" "-32700" \
  "$(jq1 "$(ubus_post /ubus '{"jsonrpc":"2.0","id":5,"method":"call","params":["","session","list"]}')" 'd["error"]["code"]')"
check "params 带 ubus_rpc_session → -32602" "-32602" \
  "$(jq1 "$(ubus_post /ubus '{"jsonrpc":"2.0","id":6,"method":"call","params":["","session","list",{"ubus_rpc_session":"x"}]}')" 'd["error"]["code"]')"
check "正文非法 JSON → -32700" "-32700" \
  "$(jq1 "$(ubus_post /ubus '{oops')" 'd["error"]["code"]')"
check "正文是标量 → -32700" "-32700" \
  "$(jq1 "$(ubus_post /ubus '42')" 'd["error"]["code"]')"

# --- method:"list"（上游 uh_ubus_send_list）---
check "list 无 params → 路径数组" "file,luci,session,uci" \
  "$(jq1 "$(ubus_post /ubus '{"jsonrpc":"2.0","id":7,"method":"list"}')" '",".join(d["result"])')"
check "list 带 params → 详细表（查不到的忽略）" "session,uci" \
  "$(jq1 "$(ubus_post /ubus '{"jsonrpc":"2.0","id":8,"method":"list","params":["session","uci","nope"]}')" '",".join(sorted(d["result"]))')"

# --- 批请求：数组正文 ---
check "数组正文 → 批响应" "0,file,luci,session,uci" \
  "$(jq1 "$(ubus_post /ubus '[{"jsonrpc":"2.0","id":9,"method":"call","params":["","uci","configs",{}]},{"jsonrpc":"2.0","id":10,"method":"list"}]')" \
    '",".join([str(d[0]["result"][0])] + d[1]["result"])')"
check "空数组正文 → []" "[]" "$(ubus_post /ubus '[]')"

echo
echo "== /ubus 新式 POST /ubus/call/<path>（JSON-RPC）=="
# method 直接是 ubus 方法名；会话来自 `Authorization: Bearer <sid>` 头，
# **不是** Ubus-Session 头（上游 uh_ubus_get_auth，ubus.c:120-137）。
r=$(ubus_post /ubus/call/luci '{"jsonrpc":"2.0","id":11,"method":"getBoardJSON","params":{}}')
check "新式状态 200" "200" \
  "$(status_of -X POST -d '{"jsonrpc":"2.0","id":11,"method":"getBoardJSON"}' "$BASE/ubus/call/luci")"
check "新式 result 是对象（无外层数组）" "luci" "$(jq1 "$r" 'd["result"]["echo"]["object"]')"
check "新式 method 就是 ubus 方法名" "getBoardJSON" "$(jq1 "$r" 'd["result"]["echo"]["method"]')"
check "无 Authorization → 哨兵 sid" "$sid0" "$(jq1 "$r" 'd["result"]["echo"]["sid"]')"
check "Bearer 头进 sid" "3653e6abc" \
  "$(jq1 "$(ubus_post /ubus/call/luci '{"jsonrpc":"2.0","id":12,"method":"getBoardJSON"}' -H 'Authorization: Bearer 3653e6abc')" 'd["result"]["echo"]["sid"]')"
check "无 params → 空参数表" "{}" \
  "$(jq1 "$(ubus_post /ubus/call/luci '{"jsonrpc":"2.0","id":13,"method":"getBoardJSON"}')" 'json.dumps(d["result"]["echo"]["params"],sort_keys=True)')"
check "对象不存在 → -32000" "-32000" \
  "$(jq1 "$(ubus_post /ubus/call/nope '{"jsonrpc":"2.0","id":14,"method":"frob"}')" 'd["error"]["code"]')"
check "未知方法 → ubus 返回码 3" "3" \
  "$(jq1 "$(ubus_post /ubus/call/uci '{"jsonrpc":"2.0","id":15,"method":"frob"}')" 'd["error"]["code"]')"
check "params 非表 → -32602" "-32602" \
  "$(jq1 "$(ubus_post /ubus/call/uci '{"jsonrpc":"2.0","id":16,"method":"configs","params":[1,2]}')" 'd["error"]["code"]')"
check "params 为 null → -32602" "-32602" \
  "$(jq1 "$(ubus_post /ubus/call/uci '{"jsonrpc":"2.0","id":17,"method":"configs","params":null}')" 'd["error"]["code"]')"
check "对象不存在优先于参数错误" "-32000" \
  "$(jq1 "$(ubus_post /ubus/call/nope '{"jsonrpc":"2.0","id":18,"method":"configs","params":[1]}')" 'd["error"]["code"]')"
check "正文非法 JSON → -32700" "-32700" \
  "$(jq1 "$(ubus_post /ubus/call/uci '{oops')" 'd["error"]["code"]')"

echo
echo "== /ubus POST 路由边界 =="
check "POST /ubus/nope → 404" "404" "$(status_of -X POST -d '{}' "$BASE/ubus/nope")"
check "POST /ubus/call（无路径）→ 404" "404" "$(status_of -X POST -d '{}' "$BASE/ubus/call")"
check "PUT /ubus → 400" "400" "$(status_of -X PUT -d '' "$BASE/ubus")"
# GET list 的 500 正文是 ubus 自己的错误码，不是 JSON-RPC 码（ubus.c:210-213）
check "GET list 500 正文 code=4" "4" \
  "$(jq1 "$(curl -s "$BASE/ubus/list/nope")" 'd["code"]')"

echo
echo "== /cgi-bin/luci dispatcher（菜单树 + 路径解析）=="
# 语义复刻上游 modules/luci-base/ucode/dispatcher.uc：menu.d → 树 → 逐段下降；
# firstchild 选权重最小的可展示子节点；depends.fs / depends.uci 决定 satisfied；
# depends.acl 只展示不执行（P2 不做 ACL）。
# fixture 见 tests/fixtures/menu.d/（luci-base.json 先于 luci-probe.json 处理）。
check "裸前缀 /cgi-bin/luci → 200" "200" "$(status_of "$BASE/cgi-bin/luci")"
check "带尾斜杠 /cgi-bin/luci/ → 200" "200" "$(status_of "$BASE/cgi-bin/luci/")"
check "占位页 Content-Type" "text/html; charset=utf-8" "$(header_of Content-Type "$BASE/cgi-bin/luci/")"
# root 的 firstchild 必须跳过 depends.fs 未命中的 hidden（order 1，权重最小）
check "root firstchild 跳过 unsatisfied" "Overview" "$(h1_of "$BASE/cgi-bin/luci/")"
check "指定路径命中" "Overview" "$(h1_of "$BASE/cgi-bin/luci/admin/status/overview")"
check "查询串被剥掉" "200" "$(status_of "$BASE/cgi-bin/luci/admin/status/overview?v=1")"
check "占位页有 ACL 未实施横幅" "1" \
  "$(curl -s "$BASE/cgi-bin/luci/admin/status/overview" | grep -c 'ACL 未实施')"
# depends.acl 原样展示但不参与 satisfied（它出现在页面上，路径仍然 200）
check "depends.acl 展示不执行" "1" \
  "$(curl -s "$BASE/cgi-bin/luci/admin/status/overview" | grep -c 'luci-base')"

# --- 中间层的 firstchild ---
check "/admin/status 走 firstchild" "Overview" "$(h1_of "$BASE/cgi-bin/luci/admin/status")"
check "/admin/system 走 firstchild" "Reboot" "$(h1_of "$BASE/cgi-bin/luci/admin/system")"
# 同一路径被两个文件定义 → **逐键**合并（dispatcher.uc:406-408 只拷 spec 里出现的键）：
# base 给 title/order/cbi，probe 只给 action，于是 title 仍是 "Reboot"、order 仍是 10
check "同路径逐键合并且未出现的键保留" "Reboot" \
  "$(h1_of "$BASE/cgi-bin/luci/admin/system/reboot")"
check "同路径逐键合并：probe 给的 action 生效" "system/reboot" \
  "$(view_of "$BASE/cgi-bin/luci/admin/system/reboot")"

# --- action.type 分流 ---
check "action.type=cbi → 501" "501" "$(status_of "$BASE/cgi-bin/luci/admin/status/routes")"
# 501 正文必须带命中信息（设备上就此定位到底是哪个 action 类型，实测踩过）
check "501 正文带 action.type" "not implemented: action.type=cbi view=status/routes menu=/admin/status/routes" \
  "$(curl -s "$BASE/cgi-bin/luci/admin/status/routes")"

# --- 通配段（dispatcher.uc:410-414 / :1010-1011）---
check "通配段收下剩余段" "200" "$(status_of "$BASE/cgi-bin/luci/admin/status/logs/syslog")"
check "通配段的 request_args 进页面" "syslog" \
  "$(curl -s "$BASE/cgi-bin/luci/admin/status/logs/syslog" | grep -o '<dd>[^<]*</dd>' | tail -1 | sed 's/<[^>]*>//g')"
# base 路径（admin/status/logs）与通配路径（admin/status/logs/*）各自留一份 action
check "通配节点无剩余段 → 用 base action" "status/logs-base" \
  "$(view_of "$BASE/cgi-bin/luci/admin/status/logs")"
check "通配节点有剩余段 → 用 wildcardaction" "status/logs-arg" \
  "$(view_of "$BASE/cgi-bin/luci/admin/status/logs/syslog")"

# --- depends.fs（dispatcher.uc:171-196 + :279-292）---
check "depends.fs file 命中 → 200" "200" "$(status_of "$BASE/cgi-bin/luci/present")"
check "depends.fs file 未命中 → 404" "404" "$(status_of "$BASE/cgi-bin/luci/hidden")"
check "depends.fs absent 且确实不存在 → 200" "200" "$(status_of "$BASE/cgi-bin/luci/fsabsent")"
check "depends.fs object 需全部条目成立 → 404" "404" "$(status_of "$BASE/cgi-bin/luci/fsand")"
check "depends.fs array 任一备选成立 → 200" "200" "$(status_of "$BASE/cgi-bin/luci/fsarray")"
check "depends.fs directory 且非空 → 200" "200" "$(status_of "$BASE/cgi-bin/luci/fsdir")"
check "depends.fs 要求 directory 但是文件 → 404" "404" "$(status_of "$BASE/cgi-bin/luci/fskind")"
check "depends.fs executable 命中 → 200" "200" "$(status_of "$BASE/cgi-bin/luci/fsexec")"
check "depends.fs executable 无执行位 → 404" "404" "$(status_of "$BASE/cgi-bin/luci/fsexecmiss")"
check "depends.fs 非 object 备选 → 忽略（满足）" "200" "$(status_of "$BASE/cgi-bin/luci/fsstrform")"

# --- depends.uci（dispatcher.uc:198-276；macOS 上走 src/backend/darwin.odin 的假配置）---
check "depends.uci 具名 section → 200" "200" "$(status_of "$BASE/cgi-bin/luci/ucipage")"
check "depends.uci section 不存在 → 404" "404" "$(status_of "$BASE/cgi-bin/luci/ucimissing")"
check "depends.uci true（config 有 section）→ 200" "200" "$(status_of "$BASE/cgi-bin/luci/ucitrue")"
check "depends.uci config 存在但无 section → 404" "404" "$(status_of "$BASE/cgi-bin/luci/uciemptycfg")"
check "depends.uci config 不存在 → 404" "404" "$(status_of "$BASE/cgi-bin/luci/ucicfgmissing")"
check "depends.uci @type 命中匿名 section → 200" "200" "$(status_of "$BASE/cgi-bin/luci/uciaftype")"
check "depends.uci option 值精确匹配 → 200" "200" "$(status_of "$BASE/cgi-bin/luci/uciopt")"
check "depends.uci option 值不符 → 404" "404" "$(status_of "$BASE/cgi-bin/luci/ucioptmiss")"
check "depends.uci object 需全部 config 成立 → 404" "404" "$(status_of "$BASE/cgi-bin/luci/uciand")"
check "depends.uci 非 object 备选 → 忽略（满足）" "200" "$(status_of "$BASE/cgi-bin/luci/ucistrform")"

# --- schema 白名单（dispatcher.uc:406-408 是**逐键**处理）---
check "白名单外的键只忽略该键 → 200" "200" "$(status_of "$BASE/cgi-bin/luci/badfield")"
# badfield 的 order 写成 string（真实样本 7 例的情形）→ 该键被忽略、节点用默认权重 9999；
# 若它被当成 1，root firstchild 会变成 "Bad field kept"
check "类型不符的键被忽略（root firstchild 仍是 Overview）" "Overview" \
  "$(h1_of "$BASE/cgi-bin/luci/")"

# --- 路由边界 ---
check "未命中路径 → 404" "404" "$(status_of "$BASE/cgi-bin/luci/nope")"
check "/cgi-bin/luci/<未知> → 404" "404" "$(status_of "$BASE/cgi-bin/luci/admin/nope")"
check "dispatcher 上的 POST → 405" "405" "$(status_of -X POST -d '' "$BASE/cgi-bin/luci/admin/status/overview")"
check "HEAD 有完整头无 body" "0" \
  "$(curl -s -I "$BASE/cgi-bin/luci/admin/status/overview" | awk 'BEGIN{b=0} /^\r?$/{f=1;next} f{b+=length($0)+1} END{print b}')"

echo
echo "== 路径逃逸（安全边界）=="
# 必须 --path-as-is：否则 curl 会自己把 /../ 折叠掉，测不到服务端
check "/../etc/passwd → 403" "403" "$(status_of --path-as-is "$BASE/../etc/passwd")"
check "/a/../../etc/passwd → 403" "403" "$(status_of --path-as-is "$BASE/a/../../etc/passwd")"
check "/%2e%2e/etc/passwd → 403" "403" "$(status_of "$BASE/%2e%2e/etc/passwd")"
check "编码非法 %zz → 400" "400" "$(status_of --path-as-is "$BASE/bad%zz")"
check "%00 → 400" "400" "$(status_of --path-as-is "$BASE/%00")"
check "查询串被剥掉" "200" "$(status_of "$BASE/index.html?v=1")"

echo
echo "== 管道请求（body 消费记账）=="
# 一条连接上 POST(带 body) 紧跟一个 GET，两个响应都要回来。
# 这条直接盯第 2 步踩过的坑：conn.consumed 算错会让第二个请求解析时越界。
pipelined=$(python3 - "$PORT" <<'PY'
import socket, sys
s = socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=5)
s.sendall(b"POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello"
          b"GET /index.html HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
data = b""
while True:
    chunk = s.recv(4096)
    if not chunk:
        break
    data += chunk
s.close()
print(data.count(b"HTTP/1.1 "))
PY
)
check "POST(body) 后接 GET 都得到响应" "2" "$pipelined"

echo
echo "== 并发上限 =="
# 32 个连接占满后第 33 个应拿 503。用慢读客户端占住槽位。
# ponytail: 这里只验证上限存在（能拿到 503 或全部 200 都算通过），
#           精确的 503 计数需要在真机上用 sysctl 调低 fd 上限来压。
hold_pids=()
for _ in $(seq 1 40); do
  (exec 3<>"/dev/tcp/127.0.0.1/$PORT" && printf 'GET / HTTP/1.1\r\nHost: x\r\n\r\n' >&3 && sleep 2) &
  hold_pids+=($!)
done
sleep 0.6
check "超额连接得到 503 或 200" "ok" \
  "$(code=$(status_of --max-time 2 "$BASE/"); [[ "$code" == 503 || "$code" == 200 || "$code" == 000 ]] && echo ok || echo "$code")"
wait "${hold_pids[@]}" 2>/dev/null

echo
echo "== 服务器存活 =="
check "压测后仍能服务" "200" "$(status_of "$BASE/")"

# ---------------------------------------------------------------------------
# P3-2：session 对象（molly 自己提供的 ubus 对象，darwin 上走真实现）
#   语义依据 rpcd session.c；断言里带行号，改契约前先回去看那一行
# ---------------------------------------------------------------------------
echo
echo "== P3-2 session 对象 =="

# jget '<python 表达式后缀>'：从 stdin 的 JSON 里取值（表达式经 argv 传，避免被 shell 吃掉）
jget() { python3 -c 'import sys,json; d=json.load(sys.stdin); print(eval("d"+sys.argv[1]))' "$1" ; }

SID=$(curl -s -X POST "$BASE/ubus/call/session" \
  -d '{"jsonrpc":"2.0","id":1,"method":"login","params":{"username":"root","password":"test1234"}}' \
  | jget '["result"]["ubus_rpc_session"]')
check "login 返回 32 位 sid" "32" "${#SID}"
check "login 写入 data.username" "root" \
  "$(curl -s -X POST "$BASE/ubus/call/session" \
       -d '{"jsonrpc":"2.0","id":1,"method":"login","params":{"username":"root","password":"test1234"}}' \
     | jget '["result"]["data"]["username"]')"
check "login timeout 默认 300" "300" \
  "$(curl -s -X POST "$BASE/ubus/call/session" \
       -d '{"jsonrpc":"2.0","id":1,"method":"login","params":{"username":"root","password":"test1234"}}' \
     | jget '["result"]["timeout"]')"
check "login 显式 timeout 生效" "60" \
  "$(curl -s -X POST "$BASE/ubus/call/session" \
       -d '{"jsonrpc":"2.0","id":1,"method":"login","params":{"username":"root","password":"test1234","timeout":60}}' \
     | jget '["result"]["timeout"]')"
check "密码错误 → code 6（PERMISSION_DENIED）" "6" \
  "$(curl -s -X POST "$BASE/ubus/call/session" \
       -d '{"jsonrpc":"2.0","id":1,"method":"login","params":{"username":"root","password":"nope"}}' \
     | jget '["error"]["code"]')"

sess() { # sess <方法> <params JSON>
  curl -s -X POST "$BASE/ubus/call/session" -H "Authorization: Bearer $SID" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"$1\",\"params\":$2}"
}

check "get 回 values.username" "root" "$(sess get '{}' | jget '["result"]["values"]["username"]')"
check "set 无回复数据（result null）" "None" "$(sess set '{"values":{"token":"abc"}}' | jget '["result"]')"
check "get(keys) 只回命中的键" "abc" \
  "$(sess get '{"keys":["token","nope"]}' | jget '["result"]["values"]["token"]')"
check "grant 后 access=true（fnmatch file/* 命中 read）" "True" \
  "$(sess grant '{"objects":[["file","*"]]}' >/dev/null; sess access '{"object":"file","function":"read"}' | jget '["result"]["access"]')"
check "未授权的方法 access=false" "False" \
  "$(sess access '{"object":"uci","function":"set"}' | jget '["result"]["access"]')"
check "access 不给 object → 回 ACL 表（scope→object→[function]）" "True" \
  "$(sess access '{}' | jget '["result"]["ubus"]["file"] == ["*"]')"
check "unset 后键消失" "None" \
  "$(sess unset '{"keys":["token"]}' >/dev/null; sess get '{"keys":["token"]}' | jget '["result"]["values"].get("token")')"
check "list 带 sid → 单个会话 dump" "$SID" "$(sess list '{}' | jget '["result"]["ubus_rpc_session"]')"
# 无 Authorization 时上游注入哨兵 sid（ubus.c 的 UBUS_DEFAULT_SID），HTTP 上永远走不到
# 「缺 sid」分支——那条分支由 src/backend/session_test.odin 的单测覆盖。
check "无 Authorization → 走哨兵会话（values 是空表）" "True" \
  "$(curl -s -X POST "$BASE/ubus/call/session" -d '{"jsonrpc":"2.0","id":3,"method":"get","params":{}}' \
     | jget '["result"]["values"] == {}')"
check "未知方法 → code 3（METHOD_NOT_FOUND）" "3" "$(sess nope '{}' | jget '["error"]["code"]')"

sess destroy '{}' >/dev/null
check "destroy 后 get → code 4（NOT_FOUND）" "4" "$(sess get '{}' | jget '["error"]["code"]')"
check "默认会话不可销毁 → code 6" "6" \
  "$(curl -s -X POST "$BASE/ubus/call/session" \
       -H 'Authorization: Bearer 00000000000000000000000000000000' \
       -d '{"jsonrpc":"2.0","id":4,"method":"destroy","params":{}}' \
     | jget '["error"]["code"]')"

echo
echo "== P3-3 uci 对象（S1 configs/get；S2 delta；S3 写操作；S4 apply 系）=="
# 契约：rpcd@e37ed9d8 的 uci.c（configs :1382-1408、get/getcommon :600-662）。
# 读权限是 session 的 ACL：session.access("uci", <config 名>, "read")（uci.c:311-337）——
# 所以这里新 login 一个会话（P3-2 段那个已经 destroy 了）：先验「未授权被拒」，
# 再 grant 一组读权限后放行。S2 补上 delta 相关：changes（枚举 saved_delta）、state（已提交态）、commit/revert
# （写盘/丢弃 delta）。写路径按决策只在 linux 上实现，所以 darwin 上 state/commit/revert
# 都回 NOT_SUPPORTED(8)——**接管到设备上也不会动 /etc/config**（写操作属 S3）。

USID=$(curl -s -X POST "$BASE/ubus/call/session" \
  -d '{"jsonrpc":"2.0","id":1,"method":"login","params":{"username":"root","password":"test1234"}}' \
  | jget '["result"]["ubus_rpc_session"]')

uci0() { curl -s -X POST "$BASE/ubus/call/uci" -d "$1"; }                                  # 无 Authorization → 哨兵会话
uci1() { curl -s -X POST "$BASE/ubus/call/uci" -H "Authorization: Bearer $USID" -d "$1"; }
usid1() { curl -s -X POST "$BASE/ubus/call/session" -H "Authorization: Bearer $USID" -d "$1"; }

check "未授权（哨兵会话）读 → code 6" "6" \
  "$(uci0 '{"jsonrpc":"2.0","id":2,"method":"get","params":{"config":"network"}}' | jget '["error"]["code"]')"

# configs 上游不做 ACL 检查（它是方法表里唯一没有策略的）
cfg0=$(uci0 '{"jsonrpc":"2.0","id":3,"method":"configs"}')
check "configs 不检查 ACL（哨兵也能列）" "True" "$(jq1 "$cfg0" 'len(d["result"]["configs"]) > 0')"
check "configs 列出 config 名（假数据含 rpcd/empty-config 两个 fixture）" "empty-config,network,rpcd,system" "$(jq1 "$cfg0" '",".join(sorted(d["result"]["configs"]))')"

usid1 '{"jsonrpc":"2.0","id":4,"method":"grant","params":{"scope":"uci","objects":[["network","read"]]}}' >/dev/null
# ACL 是按 config 名逐条授权的：只给了 network，读 system 照样被拒
check "只 grant 了 network：读 system → code 6" "6" \
  "$(uci1 '{"jsonrpc":"2.0","id":14,"method":"get","params":{"config":"system"}}' | jget '["error"]["code"]')"

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
# 上游顺序是「先 ACL、后 uci_load」（uci.c:614-623）：没授权的 config 名**不存在**也先回 6
check "未授权且 config 不存在 → 仍是 code 6（ACL 先于 load）" "6" \
  "$(uci1 '{"jsonrpc":"2.0","id":12,"method":"get","params":{"config":"nope"}}' | jget '["error"]["code"]')"
# 放开读权限（'*' 走 fnmatch），这才轮到 uci_load 报 4
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
# state 要读权限（已给），但 darwin 没有 /var/state 这条已提交态 → 8
check "state → code 8（darwin 无已提交态读取）" "8" \
  "$(uci1 '{"jsonrpc":"2.0","id":24,"method":"state","params":{"config":"network"}}' | jget '["error"]["code"]')"
# 写权限是**另一条** ACL：还没授权时 commit 是 6（ACL 先于平台能力，与上游顺序一致）
check "未授权写：commit → code 6" "6" \
  "$(uci1 '{"jsonrpc":"2.0","id":25,"method":"commit","params":{"config":"network"}}' | jget '["error"]["code"]')"
usid1 '{"jsonrpc":"2.0","id":26,"method":"grant","params":{"scope":"uci","objects":[["*","write"]]}}' >/dev/null
check "授权写之后 commit → code 8（按决策写路径只在 linux 上实现）" "8" \
  "$(uci1 '{"jsonrpc":"2.0","id":27,"method":"commit","params":{"config":"network"}}' | jget '["error"]["code"]')"
check "revert 同理 → code 8" "8" \
  "$(uci1 '{"jsonrpc":"2.0","id":28,"method":"revert","params":{"config":"network"}}' | jget '["error"]["code"]')"

# --- S3：set / add 已实现（参数校验 → ACL → 平台能力）---
# 此时读与写权限都已授予（上面两条 grant），所以走到的就是「平台能力」这一步：
# darwin 没有写事务 → 8（linux 上会写进该会话的 delta 文件，commit 之后才落 /etc/config）
check "set（已授权）→ code 8（darwin 无写事务）" "8" \
  "$(uci1 '{"jsonrpc":"2.0","id":30,"method":"set","params":{"config":"network","section":"lan","values":{"proto":"static"}}}' | jget '["error"]["code"]')"
check "add（已授权）→ code 8" "8" \
  "$(uci1 '{"jsonrpc":"2.0","id":31,"method":"add","params":{"config":"network","type":"interface","name":"molly0"}}' | jget '["error"]["code"]')"
# 参数校验在 ACL 与平台能力**之前**：缺 values 一律 2（跟有没有权限无关）
check "set 缺 values → code 2（校验先于一切）" "2" \
  "$(uci1 '{"jsonrpc":"2.0","id":32,"method":"set","params":{"config":"network","section":"lan"}}' | jget '["error"]["code"]')"
check "add 缺 type → code 2" "2" \
  "$(uci1 '{"jsonrpc":"2.0","id":33,"method":"add","params":{"config":"network"}}' | jget '["error"]["code"]')"
# 没授权的会话：set 应该先撞 ACL → 6（用哨兵会话，它没有任何 ACL）
check "未授权会话 set → code 6" "6" \
  "$(uci0 '{"jsonrpc":"2.0","id":34,"method":"set","params":{"config":"network","section":"lan","values":{"proto":"static"}}}' | jget '["error"]["code"]')"

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
# 语法校验在 ACL 之后：同一份非法请求，哨兵会话先撞 6
check "未授权会话 delete（含非法 section）→ code 6" "6" \
  "$(uci0 '{"jsonrpc":"2.0","id":46,"method":"delete","params":{"config":"network","section":"lan[0]"}}' | jget '["error"]["code"]')"

# --- S4：apply 系（apply / confirm / rollback / reload_config）---
# 没有待确认的 apply 时 confirm/rollback 都是 5（NO_DATA）；apply 因为该会话没有 delta 目录 → 4；
# reload_config 要 fork/exec /sbin/reload_config，darwin 不做 → 8
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

echo
echo "== P3-4 file 对象（第一批：路径/权限核心 + read）=="
# 契约 rpcd@e37ed9d8 的 file.c：路径先做**文本**规范化（折掉 //、/./、/../），
# 按文本路径查 ACL，再用 realpath 解析符号链接、对解析后的路径**再查一遍**
# （file.c:261-359）——不做第三步的话，目录里放个符号链接就能绕过授权。
# 权限是 session 的 ACL：session.access("file", <路径>, "read"/"write")。
FILE_USID=$(curl -s -X POST "$BASE/ubus/call/session" \
  -d '{"jsonrpc":"2.0","id":1,"method":"login","params":{"username":"root","password":"test1234"}}' \
  | jget '["result"]["ubus_rpc_session"]')

file0() { curl -s -X POST "$BASE/ubus/call/file" -d "$1"; }
file1() { curl -s -X POST "$BASE/ubus/call/file" -H "Authorization: Bearer $FILE_USID" -d "$1"; }
fsid1() { curl -s -X POST "$BASE/ubus/call/session" -H "Authorization: Bearer $FILE_USID" -d "$1"; }

check "无 file 权限读 → code 6" "6" \
  "$(file1 '{"jsonrpc":"2.0","id":2,"method":"read","params":{"path":"/etc/hosts"}}' | jget '["error"]["code"]')"
check "缺 path → code 2" "2" \
  "$(file0 '{"jsonrpc":"2.0","id":3,"method":"read","params":{}}' | jget '["error"]["code"]')"

# 只授权 /tmp 下的读（fnmatch 前缀）
fsid1 '{"jsonrpc":"2.0","id":4,"method":"grant","params":{"scope":"file","objects":[["/private/tmp/*","read"],["/private/tmp/*","write"]]}}' >/dev/null
check "授权后读 /tmp → 4（文件不存在）" "4" \
  "$(file1 '{"jsonrpc":"2.0","id":5,"method":"read","params":{"path":"/private/tmp/molly-not-exist"}}' | jget '["error"]["code"]')"
check "授权范围外（/etc/hosts）→ code 6" "6" \
  "$(file1 '{"jsonrpc":"2.0","id":6,"method":"read","params":{"path":"/etc/hosts"}}' | jget '["error"]["code"]')"

# /tmp/../etc/hosts 会被**文本**规范化成 /etc/hosts → 落到授权范围外 → 6
check "路径规范化：/tmp/../etc/hosts → code 6" "6" \
  "$(file1 '{"jsonrpc":"2.0","id":7,"method":"read","params":{"path":"/tmp/../etc/hosts"}}' | jget '["error"]["code"]')"

# 真读一个授权内的文件
# 注：macOS 上 /tmp 是指向 /private/tmp 的符号链接，而 file 的 ACL 复查（realpath）会把
# 授权范围换成解析后的真实路径——所以这里用 /private/tmp（设备上 /tmp 是真目录，不受影响）。
printf 'molly-p3-4\n' > /private/tmp/molly-file-probe.txt
check "读授权内的文件 → data" "molly-p3-4" \
  "$(jq1 "$(file1 '{"jsonrpc":"2.0","id":8,"method":"read","params":{"path":"/private/tmp/molly-file-probe.txt"}}')" 'd["result"]["data"].strip()')"
check "base64 读出同一个文件" "bW9sbHktcDMtNAo=" \
  "$(jq1 "$(file1 '{"jsonrpc":"2.0","id":9,"method":"read","params":{"path":"/private/tmp/molly-file-probe.txt","base64":true}}')" 'd["result"]["data"].strip()')"

# 符号链接复查：链接本身在授权目录里，但指向授权范围外 → 必须 6
rm -f /private/tmp/molly-file-link
ln -s /etc/hosts /private/tmp/molly-file-link
check "符号链接指向授权外 → code 6（复查 realpath）" "6" \
  "$(file1 '{"jsonrpc":"2.0","id":10,"method":"read","params":{"path":"/private/tmp/molly-file-link"}}' | jget '["error"]["code"]')"

# 未实现的方法：一律 8（绝不半成品地改文件系统）
for m in write list lstat stat md5 remove exec; do
  fbody=$(printf '{"jsonrpc":"2.0","id":11,"method":"%s","params":{"path":"/private/tmp/molly-file-probe.txt"}}' "$m")
  check "file.$m 待实现 → code 8" "8" "$(file1 "$fbody" | jget '["error"]["code"]')"
done
rm -f /private/tmp/molly-file-probe.txt /private/tmp/molly-file-link

echo
echo "通过 ${PASS}，失败 ${FAIL}"
[[ "$FAIL" -eq 0 ]]