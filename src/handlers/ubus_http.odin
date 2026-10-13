package handlers

// ubus_http —— /ubus 的 HTTP 侧 ubus 转发（逐条对齐 internal/handlers/ubus.go，即上游
// uhttpd 的 ubus 插件 ubus.c）。Odin 版刻意把「纯 JSON-RPC 逻辑」与「socket I/O」拆开：
// 纯函数（rpc_legacy/rpc_rest/invoke/legacy_list/list_paths_json/rpc_error_json/auth_sid）
// 只吃字符串/Request 视图、用 context.allocator 调 backend 接缝，能脱离监听套接字在 host 单测；
// Serve_Ubus 及其下的 ubus_get/ubus_post/ubus_list 只做 I/O 粘合。
//
// 协议面：
//	GET  /ubus/list[/<path>]   列对象/签名（失败 500 + ubus 码，非 JSON-RPC 码）
//	GET  /ubus/subscribe/<path>  SSE —— 留 s4e（此处先按上游其它 GET 的 404 空正文占位）
//	POST /ubus                 旧式：body 是 JSON-RPC，method ∈ {call, list}
//	POST /ubus/call/<path>     新式：method 直接是 ubus 方法名，会话来自 Authorization 头
//	OPTIONS                    200 + application/json + Content-Length:0（CORS 预检）
//	其它                       400 text/plain
//
// 会话来源：新式取 `Authorization: Bearer <sid>`；旧式取 params[0]；都没有 → 32 个 0 的哨兵。
// 错误一律 HTTP 200 + JSON-RPC 信封（上游在 invoke 前就发 200 头）；例外是 GET list 的 500。

import "core:strings"
import "core:fmt"
import "core:sort"
import "core:encoding/json"
import "molly:http"
import "molly:backend"

// ---- 路径与常量（对齐 ubus.go:30-45）----
UBUS_Prefix        :: "/ubus"
ubus_list_path     :: "/ubus/list"
ubus_list_prefix   :: "/ubus/list/"
ubus_call_prefix   :: "/ubus/call/"
ubus_subscribe_pfx :: "/ubus/subscribe/"

// 上游 ubus.c:38 的 UH_UBUS_DEFAULT_SID：未认证会话的哨兵值（32 个 0）。
ubus_default_sid :: "00000000000000000000000000000000"

// 上游 ubus.c:382 的伪方法名：订阅权限点与 call 方法名不在同一命名空间（留 s4e 用）。
ubus_subscribe_fn :: ":subscribe"

// JSON-RPC 错误码表（上游 ubus.c:80-106 的 json_errors），下标与 Rpc_Kind 一一对应。
Rpc_Kind :: enum {
	Parse,    // -32700
	Request,  // -32600
	Method,   // -32601
	Params,   // -32602
	Internal, // -32603
	Object,   // -32000
	Access,   // -32002
}

rpc_codes := [7]i32{ -32700, -32600, -32601, -32602, -32603, -32000, -32002 }
rpc_msgs  := [7]string{
	"Parse error",
	"Invalid request",
	"Method not found",
	"Invalid parameters",
	"Internal error",
	"Object not found",
	"Access denied",
}

json_opts := json.Marshal_Options{spec = .JSON, sort_maps_by_key = true}

// ---------------------------------------------------------------------------
// I/O 薄层
// ---------------------------------------------------------------------------

// Serve_Ubus —— /ubus 入口。path 是路由 normalize 后的安全路径（已剥查询串、压掉尾斜杠）。
Serve_Ubus :: proc(res: ^http.Response, req: ^http.Request, path: string) {
	switch req.method {
	case "GET":
		ubus_get(res, req, path)
	case "POST":
		ubus_post(res, req, path)
	case "OPTIONS":
		// 上游对 OPTIONS 回 200 + application/json + Content-Length:0（CORS 预检）
		http.Respond(res, 200, "", "application/json")
	case:
		// 上游 ubus 插件只认 GET/POST/OPTIONS，其余一律 400
		http.Respond(res, 400, "invalid request\n", "text/plain; charset=utf-8")
	}
}

ubus_get :: proc(res: ^http.Response, req: ^http.Request, path: string) {
	if path == ubus_list_path {
		ubus_list(res, "")
		return
	}
	if strings.has_prefix(path, ubus_list_prefix) {
		ubus_list(res, path[len(ubus_list_prefix):])
		return
	}
	if strings.has_prefix(path, ubus_subscribe_pfx) {
		// ACL `:subscribe` → 订阅 → text/event-stream（见 ubus_sse.odin 的 ubus_subscribe）。
		ubus_subscribe(res, req, path[len(ubus_subscribe_pfx):])
		return
	}
	// 上游对 GET /ubus 与其它 /ubus/<x> 都回 404，且不带 body
	http.Respond(res, 404, "", "")
}

ubus_list :: proc(res: ^http.Response, path: string) {
	body, err_code, ok := backend.List_Objects(path, context.allocator)
	if ! ok {
		// 上游 ubus.c:210-213：500 + {"code":<ubus errno>,"message":<ubus_strerror>}
		// ——不是 JSON-RPC 码，而是 ubus 自己的状态码。
		http.Respond(res, 500, ubus_code_message(err_code), "application/json")
		return
	}
	json_response(res, body)
}

ubus_post :: proc(res: ^http.Response, req: ^http.Request, path: string) {
	body := string(req.body)
	if path == UBUS_Prefix {
		json_response(res, rpc_legacy(body))
		return
	}
	if strings.has_prefix(path, ubus_call_prefix) {
		// 会话来自 Authorization 头，不是 body（ubus.c:920）
		sid := auth_sid(req)
		json_response(res, rpc_rest(path[len(ubus_call_prefix):], sid, body))
		return
	}
	// 上游：POST /ubus/<非 call> → 404 空正文（ubus.c:928-931）
	http.Respond(res, 404, "", "")
}

json_response :: proc(res: ^http.Response, body: string) {
	http.Respond(res, 200, body, "application/json")
}

// auth_sid —— 对齐上游 uh_ubus_get_auth（ubus.c:120-137）：只认 authorization 头，
// 值须以 "Bearer " 开头（大小写不敏感）；否则回哨兵 sid。不做 trim。
auth_sid :: proc(req: ^http.Request) -> string {
	v, ok := http.Header_Get(req, "authorization")
	if ok && len(v) >= 7 {
		if strings.to_lower(v[0:7]) == "bearer " {
			return v[7:]
		}
	}
	return ubus_default_sid
}

// ---------------------------------------------------------------------------
// 旧式 POST /ubus（纯逻辑，host 可测）
// ---------------------------------------------------------------------------

// rpc_legacy —— 对齐上游 uh_ubus_data_done（ubus.c:844-859）：正文是对象走单请求，
// 是数组走批请求（元素间插 ','），其它（字符串/数字/null/解析失败）一律 parse error。
rpc_legacy :: proc(body: string) -> string {
	v, err := json.parse_string(body, .JSON, true, context.allocator)
	if err != nil {
		return rpc_error_json(.Parse, "null")
	}
	if o, is_obj := v.(json.Object); is_obj {
		return legacy_one(o)
	}
	if arr, is_arr := v.(json.Array); is_arr {
		out: [dynamic]u8
		defer delete(out)
		append(&out, "[")
		for i := 0; i < len(arr); i += 1 {
			if i > 0 {
				append(&out, ",")
			}
			if o, is_obj := arr[i].(json.Object); is_obj {
				append(&out, legacy_one(o))
			} else {
				append(&out, rpc_error_json(.Parse, "null"))
			}
		}
		append(&out, "]")
		return finalize_string(&out)
	}
	// 既不是对象也不是数组 → parse error
	return rpc_error_json(.Parse, "null")
}

// legacy_one —— 旧式正文里的一个 JSON-RPC 请求对象（上游 uh_ubus_handle_request_object，
// ubus.c:771-827）。jsonrpc 必须 "2.0"、method 必须存在，否则回 parse error（-32700，非 -32600）。
legacy_one :: proc(o: json.Object) -> string {
	id_json := rpc_id_json(o)

	method, m_ok := rpc_str(o, "method")
	ver, v_ok := rpc_str(o, "jsonrpc")
	if ! m_ok || ! v_ok || ver != "2.0" {
		return rpc_error_json(.Parse, id_json)
	}

	switch method {
	case "call":
		// 上游 parse_call_params（ubus.c:725-754）：params 必须是四元数组
		// [sid, 对象, 方法, 参数表]，前三项是串、末项是对象，缺一即 parse error。
		praw, has := o["params"]
		if ! has {
			return rpc_error_json(.Parse, id_json)
		}
		arr, is_arr := praw.(json.Array)
		if ! is_arr || len(arr) < 4 {
			return rpc_error_json(.Parse, id_json)
		}
		sid, s_ok := as_str(arr[0])
		path, p_ok := as_str(arr[1])
		fn, f_ok := as_str(arr[2])
		_, t_ok := arr[3].(json.Object)
		if ! s_ok || ! p_ok || ! f_ok || ! t_ok {
			return rpc_error_json(.Parse, id_json)
		}
		return invoke(path, fn, true, arr[3], sid, id_json, true)

	case "list":
		praw, has := o["params"]
		return legacy_list(praw, has, id_json)
	}
	// method 既不是 call 也不是 list → method not found（ubus.c:815-818）
	return rpc_error_json(.Method, id_json)
}

// legacy_list —— 旧式 method:"list"（上游 uh_ubus_send_list，ubus.c:658-694）。
// params 非数组（含缺失/含 null）→ result 是对象路径数组；params 是数组 → result 是详细表
// {"<路径>":{"<方法>":{…}}}，数组里查不到的路径直接忽略（上游不看 ubus_lookup 返回值）。
legacy_list :: proc(praw: json.Value, has: bool, id_json: string) -> string {
	if ! has {
		return envelope_result(id_json, list_paths_json())
	}
	arr, is_arr := praw.(json.Array)
	if ! is_arr {
		return envelope_result(id_json, list_paths_json())
	}

	// 详细表：逐元素取路径 → List_Objects → 命中的原样嵌入（保持上游 sig 的排版），键按路径排序。
	sigs := make(map[string]string)
	for el in arr {
		path, ok := as_str(el)
		if ! ok {
			continue
		}
		sig_text, _, lok := backend.List_Objects(path, context.allocator)
		if ! lok || ! starts_with_obj(sig_text) {
			continue
		}
		sigs[path] = sig_text
	}

	keys: [dynamic]string
	defer delete(keys)
	for k, _ in sigs {
		append(&keys, k)
	}
	sort.quick_sort(keys[:])

	out: [dynamic]u8
	defer delete(out)
	append(&out, `{"jsonrpc":"2.0","id":`)
	append(&out, id_json)
	append(&out, `,"result":{`)
	for i := 0; i < len(keys); i += 1 {
		if i > 0 {
			append(&out, ",")
		}
		append(&out, json_quote_string(keys[i]))
		append(&out, ":")
		append(&out, sigs[keys[i]])
	}
	append(&out, "}}")
	return finalize_string(&out)
}

// list_paths_json —— 全部对象路径，字典序（上游顺序来自 ubus 的 avl 树，也有序）。
list_paths_json :: proc() -> string {
	text, _, ok := backend.List_Objects("", context.allocator)
	if ! ok {
		return "[]"
	}
	v, err := json.parse_string(text, .JSON, true, context.allocator)
	if err != nil {
		return "[]"
	}
	obj, is_obj := v.(json.Object)
	if ! is_obj {
		return "[]"
	}
	paths: [dynamic]string
	defer delete(paths)
	for k, _ in obj {
		append(&paths, k)
	}
	sort.quick_sort(paths[:])

	// 手工拼字符串数组（quick_sort 已排好序，逐条 json 转义）。
	out: [dynamic]u8
	defer delete(out)
	append(&out, "[")
	for i := 0; i < len(paths); i += 1 {
		if i > 0 {
			append(&out, ",")
		}
		append(&out, json_quote_string(paths[i]))
	}
	append(&out, "]")
	return finalize_string(&out)
}

// ---------------------------------------------------------------------------
// 新式 POST /ubus/call/<path>（纯逻辑，host 可测）
// ---------------------------------------------------------------------------

// rpc_rest —— 对齐上游 uh_ubus_call（ubus.c:861-905）：method 直接是 ubus 方法名，
// 对象路径来自 URL，params 是参数表（可以完全没有）。jsonrpc 必须 "2.0"。
rpc_rest :: proc(path, sid, body: string) -> string {
	v, err := json.parse_string(body, .JSON, true, context.allocator)
	if err != nil {
		return rpc_error_json(.Parse, "null")
	}
	o, is_obj := v.(json.Object)
	if ! is_obj {
		return rpc_error_json(.Parse, "null")
	}
	id_json := rpc_id_json(o)

	method, m_ok := rpc_str(o, "method")
	ver, v_ok := rpc_str(o, "jsonrpc")
	if ! m_ok || ! v_ok || ver != "2.0" {
		return rpc_error_json(.Parse, id_json)
	}

	praw, has := o["params"]
	return invoke(path, method, has, praw, sid, id_json, false)
}

// ---------------------------------------------------------------------------
// 一次 ubus 调用（旧式与新式共用的尾巴）
// ---------------------------------------------------------------------------

// invoke —— 上游顺序：1) 对象不存在 → -32000；2) 前置 ACL → -32002；3) 参数表校验 → -32602。
// has_params 单独传：JSON null 与「没有 params 字段」要分开——前者 -32602，后者空参数表。
// legacy 决定 result 形状（旧式恒为 [ret,{…}] 数组）。
invoke :: proc(path, method: string, has_params: bool, params: json.Value,
	sid, id_json: string, legacy: bool) -> string {

	// 1) 对象必须存在（上游 ubus_lookup_id）
	if _, _, ok := backend.List_Objects(path, context.allocator); ! ok {
		return rpc_error_json(.Object, id_json)
	}

	// 2) 前置 ACL（uhttpd 的 uh_ubus_allowed → session.access）：scope "ubus"、
	//    object=对象名、function=方法名；不过 → -32002，fail-closed。
	//    例外：session 对自己的会话是「自服务」（get/set/unset/destroy 由对象按 sid 鉴权）——
	//    不放行则登录后读不到自己的会话。
	self_service := path == "session" && backend.Backend_Session_Self_Service(sid, method)
	if ! self_service && ! backend.Backend_Session_Access(sid, path, method) {
		return rpc_error_json(.Access, id_json)
	}

	// 3) 参数表校验
	params_json := ""
	if has_params {
		table, is_obj := params.(json.Object)
		if ! is_obj {
			// 上游 uh_ubus_send_request（ubus.c:575-576）：非表一律 -32602（含 null）。
			return rpc_error_json(.Params, id_json)
		}
		if _, has := table["ubus_rpc_session"]; has {
			// 上游 ubus.c:578-582：客户端自带 ubus_rpc_session 直接拒绝，防会话固定。
			return rpc_error_json(.Params, id_json)
		}
		params_json = json_unparse(json.Value(table))
	}

	res := backend.Call_Object(path, method, params_json, sid, context.allocator)
	switch res.outcome {
	case .Object_Not_Found:
		return rpc_error_json(.Object, id_json)
	case .Internal:
		return rpc_error_json(.Internal, id_json)
	case .Ok:
	}

	if res.ret != 0 {
		// 上游 uh_ubus_request_cb（ubus.c:495-503）：ubus 返回码进 error.code，文案取
		// ubus_strerror —— 不是 JSON-RPC 的 -32xxx 表。
		return envelope_error(id_json, ubus_code_message(res.ret))
	}

	if legacy {
		// 旧式 result 恒为数组，空回复也是（ubus.c:474-491）
		if len(res.reply) > 0 {
			return envelope_result(id_json, build([]string{"[0,", res.reply, "]"}))
		}
		return envelope_result(id_json, "[0]")
	}
	if len(res.reply) > 0 {
		return envelope_result(id_json, res.reply)
	}
	// 无回复数据：上游加一个 UNSPEC 字段，格式化出来是 null（ubus.c:512）
	return envelope_result(id_json, "null")
}

// ---------------------------------------------------------------------------
// JSON / 字符串小工具
// ---------------------------------------------------------------------------

// rpc_error_json —— {"jsonrpc":"2.0","id":ID,"error":{"code":C,"message":M}}
rpc_error_json :: proc(k: Rpc_Kind, id_json: string) -> string {
	obj := make(json.Object)
	obj["code"] = json.Integer(cast(i64)rpc_codes[cast(int)k])
	obj["message"] = json.String(rpc_msgs[cast(int)k])
	return envelope_error(id_json, json_unparse(json.Value(obj)))
}

// ubus_code_message —— {"code":N,"message":"…"}（键升序：code 在 message 前）。
// 用于 GET list 的 500 与 invoke 里非 0 ubus 返回码（非 JSON-RPC 码表）。
ubus_code_message :: proc(code: i32) -> string {
	obj := make(json.Object)
	obj["code"] = json.Integer(cast(i64)code)
	obj["message"] = json.String(backend.Ubus_Error_Message(code))
	return json_unparse(json.Value(obj))
}

// rpc_str —— 从对象取字符串字段；类型不匹配等于「没有这个字段」。
rpc_str :: proc(o: json.Object, key: string) -> (string, bool) {
	v, has := o[key]
	if ! has {
		return "", false
	}
	return as_str(v)
}

as_str :: proc(v: json.Value) -> (string, bool) {
	s, is_str := v.(json.String)
	return string(s), is_str
}

// rpc_id_json —— 有 id 就原样回（json 转义），没有（或 null）补一个格式化为 null 的字段。
rpc_id_json :: proc(o: json.Object) -> string {
	v, has := o["id"]
	if ! has {
		return "null"
	}
	if _, is_null := v.(json.Null); is_null {
		return "null"
	}
	return json_unparse(v)
}

// starts_with_obj —— 跳过前导空白后首字节是 '{'（对齐 Go firstByte 的容器判定）。
starts_with_obj :: proc(s: string) -> bool {
	for i := 0; i < len(s); i += 1 {
		c := s[i]
		if c == ' ' || c == '\t' || c == '\r' || c == '\n' {
			continue
		}
		return c == '{'
	}
	return false
}

// ---- 信封拼装（避免 fmt.tprintf 花括号转义坑，直接字符串拼接）----

envelope_error :: proc(id_json, payload: string) -> string {
	return build([]string{`{"jsonrpc":"2.0","id":`, id_json, `,"error":`, payload, "}"})
}

envelope_result :: proc(id_json, result: string) -> string {
	return build([]string{`{"jsonrpc":"2.0","id":`, id_json, `,"result":`, result, "}"})
}

json_unparse :: proc(v: json.Value) -> string {
	s, err := json.unparse(v, json_opts, context.allocator)
	if err != nil {
		return "null"
	}
	return s
}

// json_quote_string —— 把一段文本转成合法的 JSON 字符串字面量（含首尾引号）。
json_quote_string :: proc(s: string) -> string {
	out: [dynamic]u8
	defer delete(out)
	append(&out, `"`)
	for i := 0; i < len(s); i += 1 {
		c := s[i]
		switch c {
		case '"': append(&out, "\\\"")
		case '\\': append(&out, "\\\\")
		case '\n': append(&out, "\\n")
		case '\r': append(&out, "\\r")
		case '\t': append(&out, "\\t")
		case:
			if c < 0x20 {
				append(&out, fmt.tprintf("\\u%04x", cast(int)c))
			} else {
				append(&out, c)
			}
		}
	}
	append(&out, `"`)
	return finalize_string(&out)
}

// build —— 把若干段字符串并成一块（context.allocator 分配，随请求 arena 回收）。
build :: proc(parts: []string) -> string {
	buf: [dynamic]u8
	defer delete(buf)
	for p in parts {
		append(&buf, p)
	}
	return finalize_string(&buf)
}

// finalize_string —— 把 [dynamic]u8 拷成定长 string（脱离动态缓冲的生命周期）。
finalize_string :: proc(buf: ^[dynamic]u8) -> string {
	out := make([]u8, len(buf^))
	copy(out, buf^[:])
	return string(out)
}
