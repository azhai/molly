#!/bin/sh
# 复现设备上的会话崩溃：按 ucode dispatcher（rollback_pending / session_retrieve）
# 与 luci.js（probeSystemFeatures 的 access 探测）的真实调用序列打 molly 的 session 对象。
# 设备侧运行：sh /tmp/session_repro.sh
# 密码取自 /tmp/login.json（不在本脚本里硬编码）。

echo "== 0 login"
SID=$(ubus call session login "$(cat /tmp/login.json)" | sed -n 's/.*"ubus_rpc_session": *"\([0-9a-f]*\)".*/\1/p')
echo "SID=$SID"
if [ -z "$SID" ]; then
	echo "!! login 没拿到 sid，后续跳过"
	exit 1
fi

echo "== 1 get 哨兵 + keys rollback（dispatcher.uc:766 rollback_pending）"
ubus call session get '{"ubus_rpc_session":"00000000000000000000000000000000","keys":["rollback"]}'

echo "== 2 get 真实 sid（dispatcher.uc:472 session_retrieve）"
ubus call session get "{\"ubus_rpc_session\":\"$SID\"}"

echo "== 3 access 无 object/function（dispatcher.uc:473 session_retrieve）"
ubus call session access "{\"ubus_rpc_session\":\"$SID\"}"

echo "== 4 access uci.get（luci.js setupDOM 的 -32002 拦截器）"
ubus call session access "{\"ubus_rpc_session\":\"$SID\",\"object\":\"uci\",\"function\":\"get\"}"

echo "== 5 access file.list"
ubus call session access "{\"ubus_rpc_session\":\"$SID\",\"object\":\"file\",\"function\":\"list\"}"

echo "== 6 access uci.changes"
ubus call session access "{\"ubus_rpc_session\":\"$SID\",\"object\":\"uci\",\"function\":\"changes\"}"

echo "== 7 再来一轮（看是否稳定复现）"
ubus call session get "{\"ubus_rpc_session\":\"$SID\"}"
ubus call session access "{\"ubus_rpc_session\":\"$SID\"}"
ubus call session access "{\"ubus_rpc_session\":\"$SID\",\"object\":\"uci\",\"function\":\"changes\"}"

echo "== done"