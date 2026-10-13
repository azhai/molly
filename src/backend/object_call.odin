package backend

// object_call —— backend ↔ handler 之间的**唯一窄接口**里的「自有对象进程内调用」部分
// （对齐 internal/backend/internal_objects.go 的 callOwnObject / injectRPCSession）。
//
// molly 自有的五个对象（session / uci / file / luci-rpc / molly.probe）逻辑平台无关，
// 已在 backend.odin 的注册表里（Register_Object / Dispatch）。darwin 与 linux 两个 provider
// 都**先**调本文件的 call_own_object；handled==false 才轮到各自的外部对象路径
// （darwin 假对象表，linux 真 ubus 往返）。这样两个平台跑的是同一份 handler 逻辑。
//
// `luci`（rpcd-mod-luci 的 26 方法对象）不是注册对象：molly 只抢前端启动必调的
// getFeatures 一条，其余交回 provider（整机抢过来会把没实现的方法从「rpcd 真实现」变成
// 「MethodNotFound」，前端大面积失效）。注意它与 `luci-rpc` 是两个对象，别合并。

import "core:encoding/json"
import "core:mem"

// Backend_Session_Access / Backend_Session_Self_Service —— handler 侧调的会话鉴权入口（对齐
// Go 的 Backend.SessionAccessUbus / SessionSelfService）。非桥接态（内置接管）走
// 进程内 ACL；桥接态（session_on_bus）改问总线上的 rpcd（与自有对象内部 ACL 同源同判）。
// handler 只认这两个名字，切换桥接不用改 handler。
Backend_Session_Access :: proc(sid, object, function: string) -> bool {
	if session_on_bus {
		return rpcd_session_access(sid, "ubus", object, function)
	}
	return Session_Access_Ubus(sid, object, function)
}

Backend_Session_Self_Service :: proc(sid, method: string) -> bool {
	if session_on_bus {
		// s4e：桥接态对「读改自己会话」的方法按 sid 形态放行，真正有效性交给被转发的 rpcd 兜底。
		switch method {
		case "get", "set", "unset", "destroy":
			return sid != "" && sid != Sess_Default_ID
		}
		return false
	}
	return Session_Self_Service(sid, method)
}

// Set_Session_On_Bus —— 记录桥接态（main 起任何线程 / HTTP 之前调一次）。darwin 无总线可接，
// 传什么都无所谓（值恒被 provider 的 session 判定读取，仅影响 linux）。桥接态下把自有对象内部
// ACL 的转问 rpcd 靠注入 session_access_bridge 完成（与 HTTP 前置 ACL 同源）；卸桥时置 nil，
// 行为退回纯进程内存储（非桥接接管态，与 Go 非桥接态完全一致）。
Set_Session_On_Bus :: proc(on: bool) {
	session_on_bus = on
	if on {
		session_access_bridge = rpcd_session_access_pair
	} else {
		session_access_bridge = nil
	}
}

// rpcd_session_access —— 桥接态下把一道 ACL 判断交给总线上的 rpcd：session.access(scope/object/function)。
// 传输失败或 rpcd 报错一律按拒绝（fail-closed），与 :80 同源同判。复用 Call_Object（桥接态下 session
// 已转发到总线），不另立 plumbing。见 Go 的 rpcdSessionAccess。
rpcd_session_access :: proc(sid, scope, object, function: string) -> bool {
	backing: [8192]u8
	ar: mem.Arena
	mem.arena_init(&ar, backing[:])
	alloc := mem.arena_allocator(&ar)

	params := make(json.Object, 3, alloc)
	params["scope"] = json.String(scope)
	params["object"] = json.String(object)
	params["function"] = json.String(function)
	res := Call_Object("session", "access", json_unparse(json.Value(params)), sid, alloc)
	if res.outcome != .Ok || res.ret != 0 {
		return false
	}
	v, err := json.parse_string(res.reply, .JSON, true, alloc)
	if err != nil {
		return false
	}
	o, ok := v.(json.Object)
	if !ok {
		return false
	}
	b, has := o["access"].(json.Boolean)
	return has && bool(b)
}

// rpcd_session_access_pair —— 桥接函数适配器：桥接态总是「已处理」（由 Set_Session_On_Bus 装/卸）。
rpcd_session_access_pair :: proc(sid, scope, object, function: string) -> (bool, bool) {
	return rpcd_session_access(sid, scope, object, function), true
}

// inject_rpc_session —— 把 sid 追加成 params 里的 ubus_rpc_session（等价 linux 侧那句
// blobmsg_add_string）。入参非 JSON 对象或解析失败时，退化成「只有 ubus_rpc_session」的对象。
// 落调用方 alloc（每请求 arena）。
inject_rpc_session :: proc(params_json, sid: string, alloc: mem.Allocator) -> string {
	obj: json.Object
	if len(params_json) > 0 {
		if v, err := json.parse_string(params_json, .JSON, true, alloc); err == nil {
			if o, ok := v.(json.Object); ok {
				obj = o
			}
		}
	}
	if obj == nil {
		obj = make(json.Object, 0, alloc)
	}
	obj["ubus_rpc_session"] = json.String(sid)
	return json_unparse(json.Value(obj))
}

// Uci_Config_Sections —— 窄接口的第三个 proc（docs/interfaces.md §6）：一个 config 的全部
// section，是菜单 depends.uci 的唯一数据来源。判定逻辑不在数据层：ok==false 只表示「读不到」，
// 「0 个 section」（config 存在但空）是 ok==true + 空切片，语义交给 src/luci。
// 数据源经平台钩子 hook_uci_sections（darwin 假数据 / linux 真 libuci），故这里是跨平台单份：
// 先确保钩子就绪（session_ensure_store 幂等），再把解析结果落调用方 alloc（每请求 arena 或建树 arena）。
Uci_Config_Sections :: proc(config: string, alloc: mem.Allocator) -> (sections: []Uci_Section, ok: bool) {
	session_ensure_store()
	return hook_uci_sections(config, alloc)
}

// luci_get_features —— `luci` 对象里前端启动必调的那一条；值按目标设备事实：
// ImmortalWrt 25.12 用 uci、不用 sysrepo → luci-sysrepo 为 false。
// （其余方法仍归总线，见 call_own_object 对 "luci" 的处理。）
luci_get_features :: proc() -> (reply: string, status: i32) {
	return `{"features":{"luci-sysrepo":false}}`, Status_OK
}

// call_own_object —— 对自有对象做一次进程内调用。handled==false 表示 obj 不是自有对象
// （或 "luci" 的非 getFeatures 方法），调用方（provider）按自己的方式处理。
// 注入语义对齐 Go：sid 为空则原样传参（不注入）；否则 inject_rpc_session。
// molly.probe / "luci" 都不读 ubus_rpc_session，注入对它们无副作用。
call_own_object :: proc(obj, method, params_json, sid: string, alloc: mem.Allocator) -> (reply: string, status: i32, handled: bool) {
	// luci：只抢 getFeatures 这一条，其余交回总线（与 Go 的 case "luci" 同构）。
	if obj == "luci" {
		if method == "getFeatures" {
			r, s := luci_get_features()
			return r, s, true
		}
		return "", 0, false
	}

	// 注册表里的自有对象（session / uci / file / luci-rpc / molly.probe）：注入 sid 后走 Dispatch。
	ensure_registry(alloc)
	if reg.objects[obj] == nil {
		return "", 0, false
	}
	inj := params_json
	if sid != "" {
		inj = inject_rpc_session(params_json, sid, alloc)
	}
	status, reply = Dispatch(alloc, obj, method, inj)
	return reply, status, true
}
