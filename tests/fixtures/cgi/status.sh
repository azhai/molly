#!/bin/sh
# CGI 桩：非 200 + 额外响应头（Status / Location / Set-Cookie 都要能透传）。
# 上游 ucode dispatcher 的登录跳转就是 302 + Location + Set-Cookie 这条路径。
printf 'Status: 302 Found\r\n'
printf 'Content-Type: text/html; charset=utf-8\r\n'
printf 'Location: /cgi-bin/luci/\r\n'
printf 'Set-Cookie: sysauth=deadbeef; path=/cgi-bin/luci\r\n'
printf 'Cache-Control: no-store\r\n'
printf '\r\n'
printf '<p>redirecting</p>\n'
