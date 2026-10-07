#!/bin/sh
# 段错误定位：按用户现场的真实调用序列循环打 session 对象，开 core dump 抓崩溃现场。
# 设备侧运行：sh /tmp/stress_core.sh
ulimit -c unlimited
rm -f /tmp/*.core
LOG=/tmp/mcore.log
: > $LOG

round=1
while [ $round -le 15 ]; do
	/tmp/molly-sym --listen 0.0.0.0:8081 --docroot /www --menu-dir /usr/share/luci/menu.d \
		--luci-cgi /www/cgi-bin/luci >>$LOG 2>&1 &
	PID=$!
	sleep 1

	# 1) 默认哨兵会话的 rollback 探测（dispatcher.uc:766）
	ubus call session get '{"ubus_rpc_session":"00000000000000000000000000000000","keys":["rollback"]}' >/dev/null 2>&1
	# 2) 登录拿真实 sid
	SID=$(ubus call session login "$(cat /tmp/login.json)" 2>/dev/null | sed -n 's/.*"ubus_rpc_session": *"\([0-9a-f]*\)".*/\1/p')
	if [ -z "$SID" ]; then
		echo "第 $round 轮 login 没拿到 sid，molly 可能已死"
		kill -9 $PID 2>/dev/null
		wait $PID 2>/dev/null
		break
	fi

	i=1
	while [ $i -le 30 ]; do
		kill -0 $PID 2>/dev/null || break
		# 3) session_retrieve（dispatcher.uc:471）
		ubus call session get "{\"ubus_rpc_session\":\"$SID\"}" >/dev/null 2>&1
		# 4) 无 object 的 access → 整个 ACL dump
		ubus call session access "{\"ubus_rpc_session\":\"$SID\"}" >/dev/null 2>&1
		# 5-7) luci.js 2712 的逐条前置校验
		ubus call session access "{\"ubus_rpc_session\":\"$SID\",\"object\":\"uci\",\"function\":\"get\"}" >/dev/null 2>&1
		ubus call session access "{\"ubus_rpc_session\":\"$SID\",\"object\":\"file\",\"function\":\"list\"}" >/dev/null 2>&1
		ubus call session access "{\"ubus_rpc_session\":\"$SID\",\"object\":\"uci\",\"function\":\"changes\"}" >/dev/null 2>&1
		i=$((i + 1))
	done

	if ! kill -0 $PID 2>/dev/null; then
		wait $PID
		echo "第 $round 轮：molly 退出码=$?"
		echo "core 文件：$(ls -l /tmp/*.core 2>/dev/null)"
		break
	fi
	kill -9 $PID 2>/dev/null
	wait $PID 2>/dev/null
	round=$((round + 1))
	echo "第 $round 轮…（上一轮存活）"
done

echo "=== dmesg 尾部"
dmesg | tail -6
echo "=== 日志尾部"
tail -12 $LOG