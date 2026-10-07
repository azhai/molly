#!/bin/sh
# 压力复现：连续打 session 对象，记录 molly 是否死亡、当时的可用内存。
# 设备侧运行：sh /tmp/stress.sh
LOG=/tmp/mstress.log
/tmp/molly-sym --listen 0.0.0.0:8081 --docroot /www --menu-dir /usr/share/luci/menu.d \
	--luci-cgi /www/cgi-bin/luci >$LOG 2>&1 &
PID=$!
sleep 2

SID=$(ubus call session login "$(cat /tmp/login.json)" 2>/dev/null | sed -n 's/.*"ubus_rpc_session": *"\([0-9a-f]*\)".*/\1/p')
echo "SID=$SID"
echo "起始 MemAvailable: $(sed -n 's/^MemAvailable: *//p' /proc/meminfo)"

i=1
while [ $i -le 25 ]; do
	if ! kill -0 $PID 2>/dev/null; then
		echo "第 $i 轮开始前 molly 已死"
		break
	fi
	ubus call session access "{\"ubus_rpc_session\":\"$SID\",\"object\":\"uci\",\"function\":\"get\"}" >/dev/null 2>&1 \
		|| echo "第 $i 轮 uci.get 失败"
	ubus call session access "{\"ubus_rpc_session\":\"$SID\",\"object\":\"file\",\"function\":\"list\"}" >/dev/null 2>&1 \
		|| echo "第 $i 轮 file.list 失败"
	ubus call session get "{\"ubus_rpc_session\":\"$SID\"}" >/dev/null 2>&1 \
		|| echo "第 $i 轮 get 失败"
	i=$((i + 1))
done

echo "结束 MemAvailable: $(sed -n 's/^MemAvailable: *//p' /proc/meminfo)"
if kill -0 $PID 2>/dev/null; then
	echo "molly 仍存活，手杀"
	kill $PID
	wait $PID
else
	wait $PID
	echo "molly 退出码=$?"
fi
echo "=== 日志尾部"
tail -8 $LOG