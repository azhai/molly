package backend

import "encoding/json"

// molly **自有** ubus 对象（session / uci / file / luci-rpc / molly.probe）的进程内调用。
//
// 这五个对象的方法逻辑是平台无关的（session.go / uci_object.go / file_object.go /
// luci_object.go），linux 与 darwin 两个 provider 都直接用这份实现——linux 上**不**做
// ubus 往返（可观测结果与 Odin 的往返一致，因为跑的是同一份 handler 逻辑；但避免
// 「同 ctx 跨线程 invoke」与 uloop poll 冲突，见计划「M5 实现设计」）。
//
// 外部对象（netifd / service / network.* …）才算 ubus 往返，见 linux.go。

// callOwnObject 对自有对象做一次调用。handled == false 表示 objPath 不是自有对象，
// 调用方按自己的方式处理（darwin 走假对象表，linux 走 ubus 往返）。
func callOwnObject(objPath, method, paramsJSON, sid string) (reply string, status int, handled bool) {
	inject := func() string {
		if sid == "" {
			return paramsJSON
		}
		return injectRPCSession(paramsJSON, sid)
	}

	switch objPath {
	case "session":
		r, s := SessionCall(method, inject())
		return r, s, true
	case "file":
		r, s := callFile(method, inject())
		return r, s, true
	case "uci":
		r, s := callUCI(method, inject())
		return r, s, true
	case "luci-rpc":
		r, s := callLuciRPC(method, inject())
		return r, s, true
	case "luci":
		// `luci` 是 rpcd-mod-luci 的对象（26 个方法：getVersion / getInitList /
		// getMountPoints / getCPUInfo …），molly 只实现其中前端**启动必调**的
		// getFeatures，其余一律 handled=false 交回总线代理——整机抢过来会把没实现的那
		// 二十来个方法从「rpcd 的真实现」变成「MethodNotFound」，前端大面积失效。
		// 注意与 `luci-rpc`（上面那个 case）是两个对象，方法表不同，别合并。
		if method == "getFeatures" {
			r, s := luciGetFeatures()
			return r, s, true
		}
		return "", 0, false
	case "molly.probe":
		switch method {
		case "notify":
			// linux 侧 Odin 是 ubus_notify(ctx, &molly.probe, "ping", …)；进程内等价物
			// 就是往事件总线推一条——订阅者收到的帧同形（event: ping + {"hello":"world"}）。
			Publish("molly.probe", "ping", `{"hello":"world"}`)
			return `{"notified":"molly.probe"}`, StatusOK, true
		case "ping":
			return `{"pong":"molly"}`, StatusOK, true
		}
		return "", StatusMethodNotFound, true
	}
	return "", 0, false
}

// injectRPCSession 把 sid 追加进对象调用的 params（等价于 linux 里那句
// blobmsg_add_string）。入参不是 JSON 对象或解析失败时，退回「只有 ubus_rpc_session」的对象。
func injectRPCSession(paramsJSON, sid string) string {
	obj := map[string]json.RawMessage{}
	if len(paramsJSON) > 0 {
		if err := json.Unmarshal([]byte(paramsJSON), &obj); err != nil {
			obj = map[string]json.RawMessage{}
		}
	}
	obj["ubus_rpc_session"] = json.RawMessage(quoteJSON(sid))
	return string(marshalRaw(obj))
}

func marshalRaw(v any) []byte {
	b, err := json.Marshal(v)
	if err != nil {
		return []byte("{}")
	}
	return b
}
