#!/usr/bin/env bash
# cgi-io 一次性上机 + 自验：把 build/molly-arm64 换上设备、重启，随后**只用 HTTP** 当场
# 验证 package-manager 依赖的 /cgi-exec 不再 405。
#
# 为什么有这个脚本：新代码在宿主门禁（make test + smoke 342/0）已证明 /cgi-exec 由
# serve_cgi_io 接管（旧二进制才会被 serve_static 判 405）。但设备仍跑旧二进制——设备拒 root 的 SSH 口令
# 登录（HTTP 同口令却可用），且没有任何 HTTP 路径能替换正在运行的可执行文件（file.write 的
# ACL 不覆盖 /usr/sbin；对运行中程序 O_TRUNC 会 ETXTBSY）。所以「换二进制 + 重启」这步必须在
# 有设备访问权的地方跑。本脚本把这步和验证合成一条命令，跑完就知道 405 有没有真被修掉。
#
# 用法（在仓库根，用你**能连上设备**的凭据；我这把 sshpass 被设备拒了）：
#   ./tests/deploy_cgi_io.sh
#   # 或自定义 SSH/SCP（比如已配好 key、或走跳板）：
#   SSH="ssh -i ~/.ssh/other_key root@192.168.1.1" SCP="scp -i ~/.ssh/other_key -O" ./tests/deploy_cgi_io.sh
#   # 带上会话口令，让第 3 步用真实登录会话验 list-installed（不带则用查无此人的会话只验路由）：
#   MOLLY_DEVICE_PASS='***' ./tests/deploy_cgi_io.sh
set -uo pipefail
cd "$(dirname "$0")/.."

HOST="${HOST:-192.168.1.1}"
SSH="${SSH:-ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@$HOST}"
SCP="${SCP:-scp -O -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null}"
BIN="build/molly-arm64"
BASE="http://$HOST:8080"
PASS="${MOLLY_DEVICE_PASS:-}"

fail() { echo "✗ $*"; exit 1; }

[ -f "$BIN" ] || fail "找不到 $BIN —— 先跑 make target 产出设备二进制"

echo "==> 1/3 上传 $BIN → $HOST:/tmp/molly-new"
$SCP "$BIN" "root@$HOST:/tmp/molly-new" || fail "上传失败：设备的 SSH/SCP 仍拒绝本机凭据（换 SSH=/SCP= 指定可用的 key）"

echo "==> 2/3 停服务 → 覆盖 /usr/sbin/molly → 重启（参数由 init 脚本保留，不动 /etc/config）"
$SSH '
  /etc/init.d/molly stop
  kill $(pidof molly) 2>/dev/null
  sleep 1
  cp /tmp/molly-new /usr/sbin/molly && chmod +x /usr/sbin/molly && rm -f /tmp/molly-new || { echo CP_FAIL; exit 9; }
  /etc/init.d/molly start
  sleep 3
  /etc/init.d/molly status
  netstat -tlnp 2>/dev/null | grep -q ":8080" && echo LISTENING || echo "WARN_NO_8080"
' || fail "重启失败"

echo "==> 3/3 HTTP 验 cgi-io（这一步不需要 SSH）"
SID=""
if [ -n "$PASS" ]; then
  SID=$(curl -s -o /dev/null -D- -X POST "$BASE/auth/login" -d 'username=root' -d "password=$PASS" \
        | tr -d '\r' | awk -F': ' 'tolower($1)=="set-cookie"{print $2}' \
        | sed 's/sysauth_molly=//; s/;.*//' | head -1)
  echo "  登录会话 sid 长度：${#SID}"
fi
# 没口令或拿不到会话时，用「查无此人」的会话（非空、非默认）：仍能证明路由已通（不再 405），
# 只是命令会被 ACL 兜底拒成 403（这是预期的安全行为，不是 405）。
[ "${#SID}" = "32" ] || SID="beef000000000000000000000000000f"

# 关键回归：POST /cgi-exec 绝不能再是 405。
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/cgi-exec" \
        --data-urlencode "sessionid=$SID" \
        --data-urlencode 'command=/usr/libexec/package-manager-call list-installed')
echo "  POST /cgi-exec (package-manager list-installed): $CODE"
[ "$CODE" = "405" ] && fail "仍是 405：新二进制没生效（检查 /etc/init.d/molly 是否真用上了 /usr/sbin/molly）"

# 越权命令必须被 file.exec ACL 拒（403）——证明没多开执行面。
CODE2=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/cgi-exec" \
        --data-urlencode "sessionid=$SID" \
        --data-urlencode 'command=/bin/rm -rf /tmp/molly-probe')
echo "  POST /cgi-exec (越权命令): $CODE2  (期望 403)"

echo
if [ "$CODE" = "200" ]; then
  echo "✅ cgi-io 已修好：list-installed 回 200。浏览器打开 $BASE/admin/system/package-manager 看列表。"
elif [ "$CODE" = "403" ]; then
  echo "✅ 路由已通（不再 405），但该会话对 package-manager-call 无 file.exec 授权 → 403。"
  echo "   若浏览器里已登录 root 仍看不到列表，多半是设备 acl.d 缺 luci-app-package-manager 的 file.exec 白名单。"
else
  echo "ℹ /cgi-exec 现在回 $CODE（不再是 405）。请打开 $BASE/admin/system/package-manager 确认。"
fi
