#!/bin/sh
# CGI 桩：先读完整个请求体再回响应，报告收到的字节数。
# 用途：64KB 请求体 + 响应，验证「写 body 的线程」确实避开了管道写满的死锁
# （macOS 管道缓冲 16KB、Linux 64KB；同步写会在子进程先回响应时卡死）。
tmp=$(mktemp) || exit 1
cat > "$tmp"
printf 'Content-Type: text/plain\r\n'
printf '\r\n'
printf 'len=%s\n' "$(wc -c < "$tmp" | tr -d ' ')"
rm -f "$tmp"
