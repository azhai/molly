#!/usr/bin/env bash
# /cgi-bin/luci 子进程桥接（P3-8″-T1，ADR 0003）的验收：起真 molly，用桩 CGI 验证
#   - CGI 环境构造（方法 / SCRIPT_NAME / PATH_INFO / QUERY_STRING / HTTP_* / CONTENT_*）
#   - 请求体透传（含 64KB：验证写 body 的线程确实避开管道写满的死锁）
#   - 响应头解析与透传（Status / Location / Set-Cookie / Cache-Control）与 Content-Type 缺失 → 500
#   - HEAD 有头无体、keep-alive 复用
# 设备上的等价验收：把 --luci-cgi 换成 "/usr/bin/ucode /usr/share/ucode/luci/uhttpd.uc"。
#
# 用法：./tests/cgi_smoke.sh
set -uo pipefail
cd "$(dirname "$0")/.."

BIN="build/molly-host"
[ -x "$BIN" ] || { echo "先跑 ./build.sh --host" >&2; exit 1; }

ECHO_PWD="$PWD/tests/fixtures/cgi"
PASS=0
FAIL=0
SERVER_PIDS=()

check() { # check <用例名> <期望> <实际>
  if [[ "$2" == "$3" ]]; then
    printf '  ok   %-46s %s\n' "$1" "$3"
    PASS=$((PASS + 1))
  else
    printf '  FAIL %-46s 期望 %s，实际 %s\n' "$1" "$2" "$3"
    FAIL=$((FAIL + 1))
  fi
}

status_of() { curl -s -o /dev/null -w '%{http_code}' "$@"; }

header_of() { # header_of <头名> <curl 参数...>
  local name="$1"; shift
  curl -sD- -o /dev/null "$@" | tr -d '\r' | sed -n "s/^${name}: //p"
}

body_of() { curl -s "$@"; }

wait_port() { # wait_port <port>
  for _ in $(seq 1 30); do
    curl -s -o /dev/null "http://127.0.0.1:$1/cgi-bin/luci" && return 0
    sleep 0.1
  done
  echo "端口 $1 上的 molly 没起来" >&2
  return 1
}

start_molly() { # start_molly <port> <cgi 脚本>
  "$BIN" --listen "127.0.0.1:$1" --docroot tests/fixtures/www \
    --menu-dir tests/fixtures/menu.d --luci-cgi "$2" >"/tmp/molly-cgi-$1.log" 2>&1 &
  SERVER_PIDS+=($!)
  wait_port "$1"
}

stop_all() {
  for pid in "${SERVER_PIDS[@]:-}"; do kill "$pid" 2>/dev/null; done
  for pid in "${SERVER_PIDS[@]:-}"; do wait "$pid" 2>/dev/null; done
}
trap stop_all EXIT

P1=18091 # echo.sh
P2=18092 # status.sh
P3=18093 # broken.sh
P4=18094 # noctype.sh
P5=18095 # sizeprobe.sh

start_molly "$P1" "$ECHO_PWD/echo.sh"
start_molly "$P2" "$ECHO_PWD/status.sh"
start_molly "$P3" "$ECHO_PWD/broken.sh"
start_molly "$P4" "$ECHO_PWD/noctype.sh"
start_molly "$P5" "$ECHO_PWD/sizeprobe.sh"

B1="http://127.0.0.1:$P1"
B2="http://127.0.0.1:$P2"
B3="http://127.0.0.1:$P3"
B4="http://127.0.0.1:$P4"
B5="http://127.0.0.1:$P5"

echo "== CGI 环境构造 =="
out=$(body_of "$B1/cgi-bin/luci")
check "裸前缀 200" "200" "$(status_of "$B1/cgi-bin/luci")"
check "方法是 GET" "method=GET" "$(printf '%s\n' "$out" | grep '^method=')"
check "脚本名是 /cgi-bin/luci" "script=/cgi-bin/luci" "$(printf '%s\n' "$out" | grep '^script=')"
check "裸前缀的 PATH_INFO 为空" "path=" "$(printf '%s\n' "$out" | grep '^path=')"
check "QUERY_STRING 为空" "query=" "$(printf '%s\n' "$out" | grep '^query=')"
check "GATEWAY_INTERFACE" "gateway=CGI/1.1" "$(printf '%s\n' "$out" | grep '^gateway=')"
check "DOCUMENT_ROOT 透传" "docroot=tests/fixtures/www" "$(printf '%s\n' "$out" | grep '^docroot=')"
check "REMOTE_ADDR 是回环地址" "remote=127.0.0.1" "$(printf '%s\n' "$out" | grep '^remote=')"

out=$(body_of "$B1/cgi-bin/luci/admin/status/overview?v=1&x=2")
check "PATH_INFO 是前缀之后的路径" "path=/admin/status/overview" "$(printf '%s\n' "$out" | grep '^path=')"
check "QUERY_STRING 保留原样" "query=v=1&x=2" "$(printf '%s\n' "$out" | grep '^query=')"
check "REQUEST_URI 含查询串" "request_uri=/cgi-bin/luci/admin/status/overview?v=1&x=2" \
  "$(printf '%s\n' "$out" | grep '^request_uri=')"

echo
echo "== 请求头与请求体 =="
out=$(body_of -H 'X-Test: abc' -H 'Host: router.lan' "$B1/cgi-bin/luci")
check "普通头映射成 HTTP_*" "xtest=abc" "$(printf '%s\n' "$out" | grep '^xtest=')"
check "Host 也映射" "host=router.lan" "$(printf '%s\n' "$out" | grep '^host=')"

out=$(body_of -X POST -d 'hello' "$B1/cgi-bin/luci/admin/x")
check "POST 方法" "method=POST" "$(printf '%s\n' "$out" | grep '^method=')"
check "CONTENT_LENGTH 是 body 长度" "clen=5" "$(printf '%s\n' "$out" | grep '^clen=')"
check "body 原样透传" "body=hello" "$(printf '%s\n' "$out" | grep '^body=')"

out=$(body_of -X POST -H 'Content-Type: application/json' -d '{}' "$B1/cgi-bin/luci")
check "CONTENT_TYPE 单独给（不做成 HTTP_*）" "ctype=application/json" "$(printf '%s\n' "$out" | grep '^ctype=')"

big=$(python3 -c 'print("a"*65536)')
check "64KB body 完整到达（无死锁）" "len=65536" "$(body_of -X POST --data-binary "$big" "$B5/cgi-bin/luci")"

echo
echo "== 响应头解析与透传 =="
check "Status: 302 透传" "302" "$(status_of "$B2/cgi-bin/luci")"
check "Location 透传" "/cgi-bin/luci/" "$(header_of Location "$B2/cgi-bin/luci")"
check "Set-Cookie 透传（登录要用）" "sysauth=deadbeef; path=/cgi-bin/luci" "$(header_of Set-Cookie "$B2/cgi-bin/luci")"
check "Cache-Control 透传" "no-store" "$(header_of Cache-Control "$B2/cgi-bin/luci")"
check "Content-Type 用脚本给的" "text/html; charset=utf-8" "$(header_of Content-Type "$B2/cgi-bin/luci")"
check "Content-Length 由 molly 重算" "19" "$(header_of Content-Length "$B2/cgi-bin/luci")"

echo
echo "== 错误路径与协议语义 =="
check "脚本无输出 → 500" "500" "$(status_of "$B3/cgi-bin/luci")"
check "缺 Content-Type → 500（CGI 规范）" "500" "$(status_of "$B4/cgi-bin/luci")"
check "HEAD 有头无体" "0" \
  "$(curl -s -I "$B1/cgi-bin/luci" | awk 'BEGIN{b=0} /^\r?$/{f=1;next} f{b+=length($0)+1} END{print b}')"
check "HEAD 仍带真实 Content-Length" "1" \
  "$(cl=$(header_of Content-Length -I "$B1/cgi-bin/luci"); [[ "${cl:-0}" -gt 0 ]] && echo 1 || echo 0)"
check "keep-alive 复用同一连接" "1" \
  "$(curl -sv "$B1/cgi-bin/luci" "$B1/cgi-bin/luci" 2>&1 | grep -ci 'Re-using existing connection')"
check "两次请求都成功" "200" "$(status_of "$B1/cgi-bin/luci")"

echo
echo "通过 ${PASS}，失败 ${FAIL}"
[[ "$FAIL" -eq 0 ]]
