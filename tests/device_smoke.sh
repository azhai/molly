#!/usr/bin/env bash
# 真机验收（P3 的每一步都有「在设备上跑一次」这一条，这个脚本就是那一跑的载体）。
#
# 在**设备上**跑（设备自带 ubus/uci/curl）：
#   ./tests/device_smoke.sh                       # 只用 molly.probe + 四对象 + HTTP 面
#   ./tests/device_smoke.sh --pass 'xxx'          # 多跑「真实 /etc/shadow + crypt」登录
#   ./tests/device_smoke.sh --uci-write           # 多跑 uci 写路径（**只碰自建的 mollytest**）
#   ./tests/device_smoke.sh --golden /tmp/golden  # 与 rpcd 的 golden 样本逐字段对比
#   ./tests/device_smoke.sh --rss 200             # 顺带报一次 RSS（P2 风险 R6 的观察项）
#
# 也可以从能同时访问 ubus 与 molly 的机器上跑（--molly 指向 molly 的 URL）。
#
# 前置：**先 `/etc/init.d/rpcd stop` 再起 molly**，否则四个对象还是 rpcd 提供的：
# 脚本会明确提示这一点（那是接管没做完，不是失败）。
set -uo pipefail
cd "$(dirname "$0")/.."

MOLLY="http://127.0.0.1:8081"
PASSWD=""
GOLDEN=""
RSS_N=0
UCI_WRITE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
  --molly) MOLLY="$2"; shift 2 ;;
  --pass) PASSWD="$2"; shift 2 ;;
  --golden) GOLDEN="$2"; shift 2 ;;
  --rss) RSS_N="$2"; shift 2 ;;
  --uci-write) UCI_WRITE=1; shift ;;
  -h | --help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "未知参数：$1" >&2; exit 2 ;;
  esac
done

PASS=0
FAIL=0
SKIP=0
check() { # check <名字> <期望> <实际>
  if [[ "$2" == "$3" ]]; then
    printf '  ok   %-48s %s\n' "$1" "$3"
    PASS=$((PASS + 1))
  else
    printf '  FAIL %-48s 期望 %s，实际 %s\n' "$1" "$2" "$3"
    FAIL=$((FAIL + 1))
  fi
}
skip() { printf '  --   %-48s %s\n' "$1" "$2"; SKIP=$((SKIP + 1)); }
has() { command -v "$1" >/dev/null 2>&1; }

echo "== 0. 前置 =="
if ! has ubus; then
  echo "没有 ubus 命令：这个脚本要在设备上（或能访问 ubus 的机器上）跑" >&2
  exit 2
fi
molly_list=$(curl -sS -m 5 "$MOLLY/ubus/list" 2>/dev/null || true)
check "molly 在 $MOLLY 上应答" "200" "$(curl -sS -m 5 -o /dev/null -w '%{http_code}' "$MOLLY/ubus/list" 2>/dev/null)"

echo
echo "== 1. molly 提供的 ubus 对象（P3-1…P3-5）=="
# P3-1 的设备验收判据就是这一条：molly.probe 出现在全量对象表里
check "ubus list 里有 molly.probe" "1" \
  "$(ubus -v list 2>/dev/null | grep -c '^molly\.probe')"
check "molly.probe ping（经 ubus 总线）" '{"pong":"molly"}' \
  "$(ubus -v call molly.probe ping 2>/dev/null | tr -d ' \n')"
for obj in session uci file luci-rpc; do
  # 四对象在 ubus 里一定在（rpcd 或 molly 提供的）；「是谁提供的」由第 2 节的
  # HTTP 面（molly 自己的实现）判断——rpcd 还占着时 molly 注册会失败并打日志。
  check "ubus list 里有 $obj" "1" "$(ubus -v list 2>/dev/null | grep -c "^$obj\$")"
done

echo
echo "== 2. molly 的 HTTP 面（P2 的 /ubus + P3-6 的 ACL）=="
check "/ubus/list 是 JSON" "application/json" \
  "$(curl -sS -m 5 -D- -o /dev/null "$MOLLY/ubus/list" | tr -d '\r' | sed -n 's/^Content-Type: //p')"
check "molly 的 list 含四个对象" "4" \
  "$(printf '%s' "$molly_list" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(sum(1 for k in ("session","uci","file","luci-rpc") if k in d))')"
check "/ubus/call/session list → 200" "200" \
  "$(curl -sS -m 5 -o /dev/null -w '%{http_code}' -X POST -d '{"jsonrpc":"2.0","id":1,"method":"list","params":{}}' "$MOLLY/ubus/call/session")"
check "哨兵调 uci → -32002（P3-6 前置 ACL）" "-32002" \
  "$(curl -sS -m 5 -X POST -d '{"jsonrpc":"2.0","id":1,"method":"configs","params":{}}' "$MOLLY/ubus/call/uci" \
     | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("error",{}).get("code","none"))' 2>/dev/null)"
check "无 cookie 访问 ACL 门控页 → 404（P3-6 裁树）" "404" \
  "$(curl -sS -m 5 -o /dev/null -w '%{http_code}' "$MOLLY/cgi-bin/luci/admin/status/overview")"
check "未知菜单路径 → 404" "404" \
  "$(curl -sS -m 5 -o /dev/null -w '%{http_code}' "$MOLLY/cgi-bin/luci/nope")"
check "dispatcher 上的 POST → 405" "405" \
  "$(curl -sS -m 5 -o /dev/null -w '%{http_code}' -X POST -d '' "$MOLLY/cgi-bin/luci/")"

echo
echo "== 3. 真实会话：/etc/shadow + crypt（P3-2）=="
if [[ -n "$PASSWD" ]]; then
  # 走 molly 的对象（不是 rpcd 的）：这样验的才是 molly 的 crypt 路径。
  # 这里要显式密码 hash 由 /etc/config/rpcd 的 `$p$root` → /etc/shadow（session.c:850）。
  sid=$(curl -sS -m 5 -X POST \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"login\",\"params\":{\"username\":\"root\",\"password\":\"$PASSWD\"}}" \
    "$MOLLY/ubus/call/session" |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["ubus_rpc_session"])' 2>/dev/null)
  check "root 登录（经 molly）拿到 32 位 sid" "32" "${#sid}"
  check "错误密码 → 6（PERMISSION_DENIED）" "6" \
    "$(curl -sS -m 5 -X POST \
       -d '{"jsonrpc":"2.0","id":1,"method":"login","params":{"username":"root","password":"definitely-wrong"}}' \
       "$MOLLY/ubus/call/session" |
       python3 -c 'import json,sys; print(json.load(sys.stdin)["error"]["code"])' 2>/dev/null)"
  if [[ ${#sid} -eq 32 ]]; then
    check "登录会话能读 uci（acl.d 的 luci-base 授了 get）" "True" \
      "$(curl -sS -m 5 -H "Authorization: Bearer $sid" -X POST \
         -d '{"jsonrpc":"2.0","id":1,"method":"access","params":{"object":"uci","function":"get"}}' \
         "$MOLLY/ubus/call/session" | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["access"])' 2>/dev/null)"
    echo "$sid" >/tmp/molly-device-sid
    echo "       （sid 存到 /tmp/molly-device-sid，第 4/5 节要用）"
  fi
else
  skip "真实 crypt 登录" "没给 --pass"
fi

echo
echo "== 4. uci 写路径（S3/S4）=="
sid4="$(cat /tmp/molly-device-sid 2>/dev/null || true)"
if [[ "$UCI_WRITE" == "1" ]]; then
  if [[ -z "$sid4" ]]; then
    skip "uci 写路径" "要先给 --pass（写路径需要授权会话，哨兵会被 -32002 拦）"
  else
    # 安全边界：只碰**自建**的 /etc/config/mollytest，跑完删掉；绝不改既有配置。
    printf 'config widget\n\toption name test0\n' >/etc/config/mollytest
    uci_post() {
      curl -sS -m 5 -H "Authorization: Bearer $sid4" -X POST -d "$1" "$MOLLY/ubus/call/uci"
    }
    # 只读的 root 会话写不了 mollytest（acl.d 只授 uci 的 system/luci）→ 先用 grant 补
    curl -sS -m 5 -H "Authorization: Bearer $sid4" -X POST \
      -d '{"jsonrpc":"2.0","id":1,"method":"grant","params":{"scope":"uci","objects":[["mollytest","read"],["mollytest","write"]]}}' \
      "$MOLLY/ubus/call/session" >/dev/null

    check "molly 看到 mollytest 这个 config" "1" \
      "$(uci_post '{"jsonrpc":"2.0","id":1,"method":"configs","params":{}}' | grep -c mollytest)"
    check "set（写进本会话 delta）→ 0" "0" \
      "$(uci_post '{"jsonrpc":"2.0","id":1,"method":"set","params":{"config":"mollytest","section":"test0","values":{"name":"molly"}}}' |
         python3 -c 'import json,sys; print(json.load(sys.stdin)["result"][0])' 2>/dev/null)"
    check "changes 看得到 pending" "1" \
      "$(uci_post '{"jsonrpc":"2.0","id":1,"method":"changes","params":{"config":"mollytest"}}' | grep -c mollytest)"
    check "commit → 0" "0" \
      "$(uci_post '{"jsonrpc":"2.0","id":1,"method":"commit","params":{"config":"mollytest"}}' |
         python3 -c 'import json,sys; print(json.load(sys.stdin)["result"][0])' 2>/dev/null)"
    check "commit 后配置真的落盘" "1" "$(grep -c 'molly' /etc/config/mollytest 2>/dev/null)"
    check "apply 无 delta → 4（NOT_FOUND）" "4" \
      "$(uci_post '{"jsonrpc":"2.0","id":1,"method":"apply","params":{}}' |
         python3 -c 'import json,sys; print(json.load(sys.stdin)["result"][0])' 2>/dev/null)"
    rm -f /etc/config/mollytest
  fi
else
  skip "uci 写路径" "没给 --uci-write（它会在 /etc/config 建临时文件，默认关）"
fi

echo
echo "== 5. /ubus/subscribe（SSE，P3-7）=="
sid="${PASSWD:+$(cat /tmp/molly-device-sid 2>/dev/null || true)}"
auth=()
[[ -n "$sid" ]] && auth=(-H "Authorization: Bearer $sid")
sse_out=$(mktemp)
curl -sN -m 6 "${auth[@]}" "$MOLLY/ubus/subscribe/molly.probe" >"$sse_out" &
sse_pid=$!
sleep 1
# 真机上的触发源：molly.probe 的 notify（内部 ubus_notify → 订阅者的回调 → 管道 → SSE）
ubus -v call molly.probe notify '{}' >/dev/null 2>&1
wait $sse_pid 2>/dev/null
check "SSE 收到 event: ping" "1" "$(grep -c '^event: ping$' "$sse_out")"
check "SSE 帧带 data" "1" "$(grep -c '^data: {"hello":"world"}$' "$sse_out")"
rm -f "$sse_out"

echo
echo "== 6. golden 逐字段对比 =="
if [[ -n "$GOLDEN" ]]; then
  ./tests/golden.sh molly "$MOLLY" >/dev/null 2>&1
  ./tests/golden.sh compare "$GOLDEN" || FAIL=$((FAIL + 1))
else
  skip "golden 对比" "没给 --golden <dir>（先 ./tests/golden.sh device <host> 抓 rpcd 的样本）"
fi

echo
echo "== 7. RSS 观察（P2 风险 R6）=="
if [[ "$RSS_N" -gt 0 ]]; then
  i=0
  while [[ $i -lt "$RSS_N" ]]; do
    curl -sS -m 5 -o /dev/null "$MOLLY/ubus/list" || true
    i=$((i + 1))
  done
  pid=$(pidof molly 2>/dev/null | head -1 || true)
  if [[ -n "$pid" ]]; then
    rss=$(awk '/VmRSS/{print $2" kB"}' "/proc/$pid/status" 2>/dev/null)
    echo "  $RSS_N 次请求后：molly RSS = $rss（目标 <2MB，只报不判）"
  else
    echo "  找不到 molly 的 pid（换名字跑的？）"
  fi
else
  skip "RSS 观察" "没给 --rss <次数>"
fi

echo
echo "通过 ${PASS}，失败 ${FAIL}，跳过 ${SKIP}"
[[ "$FAIL" -eq 0 ]]
