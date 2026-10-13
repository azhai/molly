package backend

// object_provider_darwin —— macOS（开发机）上的外部对象 provider（对齐 internal/backend/darwin.go）。
//
// 目的不是模拟 ubus 语义，而是让「HTTP 层 → 路由 → JSON 信封」这条链路在没有设备的情况下
// 也能端到端验收。**它不代表设备契约**：真机形状以 `ubus list -v` 抓的样本为准。
// 自有对象（session/uci/file/luci-rpc/molly.probe + luci 的 getFeatures）由 call_own_object
// 走平台无关真实现；本文件只补「外部对象」那部分：假签名表 + 回显入参。
//
// 文件名后缀 _darwin 让 Odin 只在 darwin 目标编本文件（linux 走 object_provider_linux.odin）。
//
// 签名串里冒号后不留空格：Call_Object 用 `"<方法名>":` 做子串判断来伪造「未知方法」，
// 格式一变那个判断就失效。

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:strings"

session_sig :: `{"access":{"ubus_rpc_session":"string","object":"string","function":"string","scope":"string"},` +
	`"create":{"*":"object"},` +
	`"destroy":{"ubus_rpc_session":"string"},` +
	`"exists":{"ubus_rpc_session":"string"},` +
	`"get":{"ubus_rpc_session":"string"},` +
	`"grant":{"ubus_rpc_session":"string","scope":"string","objects":"array"},` +
	`"list":{"*":"object"},` +
	`"login":{"username":"string","password":"string","timeout":"number"},` +
	`"revoke":{"ubus_rpc_session":"string","scope":"string","objects":"array"},` +
	`"set":{"ubus_rpc_session":"string","*":"object"},` +
	`"unset":{"ubus_rpc_session":"string","*":"object"},` +
	`"update":{"ubus_rpc_session":"string","*":"object"}}`

uci_sig :: `{"add":{"config":"string","type":"string","*":"object"},` +
	`"changes":{"config":"string"},` +
	`"commit":{"config":"string"},` +
	`"configs":{},` +
	`"delete":{"config":"string","section":"string","option":"string"},` +
	`"get":{"config":"string","section":"string","option":"string","type":"string"},` +
	`"order":{"config":"string","sections":"array"},` +
	`"rename":{"config":"string","section":"string","option":"string","name":"string"},` +
	`"set":{"config":"string","section":"string","type":"string","values":"object"},` +
	`"state":{"config":"string","section":"string","option":"string","type":"string","default":"string"}}`

file_sig :: `{"exec":{"command":"string","params":"array","env":"object"},` +
	`"list":{"path":"string"},` +
	`"read":{"path":"string","base64":"boolean","data":"string"},` +
	`"remove":{"path":"string"},` +
	`"stat":{"path":"string"},` +
	`"write":{"path":"string","data":"string","append":"boolean","base64":"boolean","mode":"number"}}`

luci_sig :: `{"getBlockInfo":{"name":"string","extended":"boolean"},` +
	`"getBoardJSON":{},` +
	`"getDHCPLeases":{},` +
	`"getInitList":{"name":"string"},` +
	`"getLocaltime":{},` +
	`"getNetworkDevices":{},` +
	`"getRealtimeStats":{},` +
	`"getTimezones":{},` +
	`"getUSBDevices":{},` +
	`"setInitAction":{"name":"string","action":"string"},` +
	`"setLocaltime":{"zonename":"string","time":"number"},` +
	`"setPassword":{"user":"string","password":"string"}}`

// molly 自持的 luci-rpc（6 方法）。假对象表里必须有它，否则 /ubus 的「对象存在性」预检
// 会把它判成不存在 → -32000。
luci_rpc_sig :: `{"getBoardJSON":{},` +
	`"getDHCPLeases":{"family":"number"},` +
	`"getDUIDHints":{},` +
	`"getHostHints":{},` +
	`"getNetworkDevices":{},` +
	`"getWirelessDevices":{}}`

// molly.probe：linux 上由 ubus 线程真注册（ping + notify）；darwin 放一份，
// 让 `ubus call molly.probe …` 形态在 macOS 上也能被判存在。
probe_sig :: `{"notify":{},"ping":{}}`

// GET /ubus/list 的全量正文：把各段拼进一层对象名，顺序按路径排（模仿 ubus 的 avl 有序输出）。
fake_list :: `{"file":` + file_sig +
	`,"luci":` + luci_sig +
	`,"luci-rpc":` + luci_rpc_sig +
	`,"molly.probe":` + probe_sig +
	`,"session":` + session_sig +
	`,"uci":` + uci_sig +
	`}`

// fake_sig —— 对象路径 → 签名（未知返回 ""）。
fake_sig :: proc(path: string) -> string {
	switch path {
	case "file":        return file_sig
	case "luci":        return luci_sig
	case "luci-rpc":    return luci_rpc_sig
	case "molly.probe": return probe_sig
	case "session":     return session_sig
	case "uci":         return uci_sig
	}
	return ""
}

// List_Objects —— GET /ubus/list[/<path>]。path=="" 列全部，否则列该对象；未知 → Status_Not_Found
// （真机 ubus_lookup 对不存在路径回 NOT_FOUND，handler 于是 500 + {"code":4,...}）。
List_Objects :: proc(path: string, alloc: mem.Allocator) -> (json_text: string, err: i32, ok: bool) {
	_ = alloc
	if path == "" {
		return fake_list, 0, true
	}
	if sig := fake_sig(path); sig != "" {
		return sig, 0, true
	}
	return "", Status_Not_Found, false
}

// Call_Object —— POST /ubus 与 /ubus/call/<path> 的调用部分。自有对象交 call_own_object；
// 其余按假签名表判存在性/方法，再回显入参证明 obj/method/sid/params 四值确实传到这一层。
Call_Object :: proc(obj, method, params_json, sid: string, alloc: mem.Allocator) -> Call_Result {
	if reply, status, handled := call_own_object(obj, method, params_json, sid, alloc); handled {
		if status != 0 {
			return Call_Result{outcome = .Ok, ret = status}
		}
		return Call_Result{outcome = .Ok, ret = 0, reply = reply}
	}

	sig := fake_sig(obj)
	if sig == "" {
		return Call_Result{outcome = .Object_Not_Found}
	}
	// 方法在不在，用假数据自己的签名做子串判断就够了。真机上这个判断发生在 ubusd/rpcd 那边，
	// 未知方法回 Status_Method_Not_Found。needle 是动态串（含 method）→ 用 tprintf 造。
	needle := fmt.tprintf("\"%s\":", method)
	if !strings.contains(sig, needle) {
		return Call_Result{outcome = .Ok, ret = Status_Method_Not_Found}
	}

	p := params_json
	if p == "" {
		p = "{}"
	}
	reply, ok := marshal_echo(obj, method, sid, p, alloc)
	if !ok {
		return Call_Result{outcome = .Internal}
	}
	return Call_Result{outcome = .Ok, ret = 0, reply = reply}
}

// marshal_echo —— 回显 {"echo":{"object":…,"method":…,"sid":…,"params":<raw>}}。
// params 作为原始 JSON 值嵌入（不是字符串），与 Go 的 json.RawMessage 同形；解析失败退化成 null。
marshal_echo :: proc(obj, method, sid, params: string, alloc: mem.Allocator) -> (string, bool) {
	inner := make(json.Object, 0, alloc)
	inner["object"] = json.String(obj)
	inner["method"] = json.String(method)
	inner["sid"]    = json.String(sid)
	if v, err := json.parse_string(params, .JSON, true, alloc); err == nil {
		inner["params"] = v
	} else {
		inner["params"] = json.Value(make(json.Object, 0, alloc))
	}
	outer := make(json.Object, 0, alloc)
	outer["echo"] = json.Value(inner)
	return json_unparse(json.Value(outer)), true
}

// ---------------------------------------------------------------------------
// 平台侧空操作（macOS 无总线可接；linux 文件有同名另一份，行为见 object_provider_linux.odin）
// ---------------------------------------------------------------------------

Set_Ubus_Socket :: proc(path: string) { _ = path }

Start_Server :: proc(socket_path: string) -> i32 { _ = socket_path; return 0 }
