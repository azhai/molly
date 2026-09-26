#!/bin/sh
# CGI 桩：只给 body、不给 Content-Type。CGI 规范视为脚本错误 → molly 回 500。
printf 'hello without content type\n'
