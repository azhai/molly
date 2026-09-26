#!/bin/sh
# CGI 桩程序：把 molly 构造的 CGI 环境与请求体原样吐回来，供 tests/cgi_smoke.sh 断言。
# 它替代设备上的 ucode dispatcher（macOS 上没有 ucode），验证的是**桥接**本身：
# 环境变量名/取值、方法、PATH_INFO/QUERY_STRING 切分、请求体透传、响应头解析。
printf 'Content-Type: text/plain\r\n'
printf '\r\n'
printf 'method=%s\n' "$REQUEST_METHOD"
printf 'protocol=%s\n' "$SERVER_PROTOCOL"
printf 'gateway=%s\n' "$GATEWAY_INTERFACE"
printf 'script=%s\n' "$SCRIPT_NAME"
printf 'path=%s\n' "$PATH_INFO"
printf 'query=%s\n' "$QUERY_STRING"
printf 'request_uri=%s\n' "$REQUEST_URI"
printf 'docroot=%s\n' "$DOCUMENT_ROOT"
printf 'remote=%s\n' "$REMOTE_ADDR"
printf 'clen=%s\n' "$CONTENT_LENGTH"
printf 'ctype=%s\n' "$CONTENT_TYPE"
printf 'xtest=%s\n' "$HTTP_X_TEST"
printf 'host=%s\n' "$HTTP_HOST"
printf 'body=%s' "$(cat)"
