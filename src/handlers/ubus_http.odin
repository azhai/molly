package handlers

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:slice"
import "core:strings"

import "molly:backend"
import "molly:http"

// /ubus —— HTTP 侧的 ubus 转发，对应上游 uhttpd 的 ubus 插件（`ubus.c`）。
//
// P2 只做转发（计划决策 7）：molly 不注册任何 ubus 对象，session / uci / file /
// luci 仍是设备上 rpcd 提供的。因此这里**没有**上游那道 `session.access` 前置
// ACL 校验（`uh_ubus_allowed`），ACL 留到 P3 换成 molly 自持的 acl.d。
//
// 本文件覆盖的协议面（全部逐条对齐 `/tmp/uhttpd-ubus.c`）：
//   GET  /ubus/list、/ubus/list/<path>     列对象/签名
//   GET  /ubus/subscribe/*                 501（决策 8，要 uloop 事件线程，留到 P3）
//                                          POST 同一个前缀走「/ubus/<非 call>」→ 404（同上游）
//   POST /ubus                             旧式：body 是 JSON-RPC，method 为 "call"/"list"
//   POST /ubus/call/<path>                 新式：method 直接是 ubus 方法名
//
// 会话来源：新式是 `Authorization: Bearer <sid>` 头（`ubus.c:120-137`），
// 旧式是 params[0]；两者都没有时回退到 32 个 0。**不是** `Ubus-Session` 头。
//
// 错误一律走 HTTP 200 + JSON-RPC 信封（上游在 invoke 之前就把 200 头和
// Content-Type 发出去了：`ubus.c:851`、`:874`）。唯一的例外是 GET list 的
// 500，那条回的是 ubus 自己的错误码而不是 JSON-RPC 码（`ubus.c:315-317`）。

UBUS_PATH             :: "/ubus"
UBUS_LIST_PATH        :: "/ubus/list"
UBUS_LIST_PREFIX      :: "/ubus/list/"
UBUS_CALL_PREFIX      :: "/ubus/call/"
UBUS_SUBSCRIBE_PREFIX :: "/ubus/subscribe/"

// 上游 `ubus.c:38` 的 UH_UBUS_DEFAULT_SID：未认证会话的哨兵值。
UBUS_DEFAULT_SID :: "00000000000000000000000000000000"

// ---------------------------------------------------------------------------
// JSON-RPC 错误码
// ---------------------------------------------------------------------------

// 上游 `ubus.c:80-106` 的 json_errors 表。只列 P2 会回的六个——session / access /
// timeout 要等 P3 接管 rpcd 的 session 对象与 ACL 才有意义。
@(private)
Rpc_Error :: enum {
	Parse,    // -32700
	Request,  // -32600
	Method,   // -32601
	Params,   // -32602
	Internal, // -32603
	Object,   // -32000
}

@(private)
Rpc_Error_Def :: struct {
	code: int,
	msg:  string,
}

// 下标必须与 Rpc_Error 的顺序一一对应。
@(private)
RPC_ERRORS := [Rpc_Error]Rpc_Error_Def{
	.Parse    = {-32700, "Parse error"},
	.Request  = {-32600, "Invalid request"},
	.Method   = {-32601, "Method not found"},
	.Params   = {-32602, "Invalid parameters"},
	.Internal = {-32603, "Internal error"},
	.Object   = {-32000, "Object not found"},
}

// 旧式与新式的 result 形状不同，所以调用侧要说明自己是谁（上游靠 `du->legacy`）。
@(private)
Rpc_Shape :: enum {
	Legacy, // result 恒为 [ret, {...}] 数组（`ubus.c:474-491`）
	Rest,   // result 是回复表本身，无数据时为 null（`ubus.c:504-514`）
}

// 失败时 500 的正文。上游 `uh_ubus_ubus_error`（`ubus.c:210-213`）回的是
// `{"code":<ubus errno>,"message":<ubus_strerror>}` —— 注意这里**不是** JSON-RPC
// 错误码，而是 ubus 自己的 enum ubus_msg_status。文案表在 backend 里。
//
// 注意所有 JSON 格式串里的花括号都要写两遍：Odin 的 fmt 把单个 '{' 当动词起始符
// （`core/fmt/fmt.odin:702-734`），单写会输出 `%!(MISSING CLOSE BRACE)`。
@(private)
ubus_error_body :: proc(err: int, alloc: mem.Allocator) -> string {
	return fmt.aprintf(`{{"code":%d,"message":"%s"}}`, err, backend.ubus_error_message(err, alloc), allocator = alloc)
}

// ---------------------------------------------------------------------------
// 路由
// ---------------------------------------------------------------------------

// 调用约定：path 是 http.normalize_path 的产物（已剥查询串、无 .. 段、尾部 '/'
// 已被压掉）。所以 "/ubus/" 与 "/ubus" 在这里长得一样，与上游「/foo 和 /foo/
// 都算旧式」的处理等价。
serve_ubus :: proc(s: ^http.Server, conn: ^http.Connection, req: ^http.Request, path: string) -> bool {
	switch req.method {
	case .Get:
		return ubus_get(conn, req, path)
	case .Post:
		return ubus_post(conn, req, path)
	case .Options:
		// 上游对 OPTIONS 回 200 + application/json + Content-Length: 0（CORS 预检）
		return http.respond(conn, .OK, "", {
			content_type = "application/json",
			keep_alive   = req.keep_alive,
		})
	case .Head, .Put, .Delete, .Other:
		// 上游的 ubus 插件只认 GET / POST / OPTIONS，其余一律 400
		return http.respond(conn, .Bad_Request, "invalid request\n", {
			keep_alive = req.keep_alive,
		})
	}
	return false
}

@(private)
ubus_get :: proc(conn: ^http.Connection, req: ^http.Request, path: string) -> bool {
	switch {
	case path == UBUS_LIST_PATH:
		// 无 path → 列全部对象（后端 add_object 分支）
		return ubus_list(conn, req, "")
	case strings.has_prefix(path, UBUS_LIST_PREFIX):
		return ubus_list(conn, req, path[len(UBUS_LIST_PREFIX):])
	case strings.has_prefix(path, UBUS_SUBSCRIBE_PREFIX):
		// 计划决策 8：SSE 要一个 uloop 事件线程，与「一连接一线程」不兼容，
		// 留到 P3 和 ubus 对象注册一起解决。
		return not_implemented(conn, req)
	}
	// 上游对 GET /ubus 与其它 /ubus/<x> 都回 404，且不带 body
	return http.respond(conn, .Not_Found, "", {
		keep_alive = req.keep_alive,
	})
}

@(private)
ubus_post :: proc(conn: ^http.Connection, req: ^http.Request, path: string) -> bool {
	alloc := mem.dynamic_arena_allocator(&conn.arena)

	if path == UBUS_PATH {
		return json_response(conn, req, rpc_legacy(req.body, alloc))
	}
	if strings.has_prefix(path, UBUS_CALL_PREFIX) {
		// 会话来自 Authorization 头，不是 body（`ubus.c:920`）
		sid := auth_sid(req)
		return json_response(conn, req, rpc_rest(path[len(UBUS_CALL_PREFIX):], sid, req.body, alloc))
	}
	// 上游：POST /ubus/<非 call> → 404 空正文（`ubus.c:928-931`）
	return http.respond(conn, .Not_Found, "", {
		keep_alive = req.keep_alive,
	})
}

@(private)
ubus_list :: proc(conn: ^http.Connection, req: ^http.Request, path: string) -> bool {
	alloc := mem.dynamic_arena_allocator(&conn.arena)
	body, err, ok := backend.list_objects(path, alloc)
	if !ok {
		return http.respond(conn, .Internal_Server_Error, ubus_error_body(err, alloc), {
			content_type = "application/json",
			keep_alive   = req.keep_alive,
		})
	}
	return json_response(conn, req, body)
}

@(private)
json_response :: proc(conn: ^http.Connection, req: ^http.Request, body: string) -> bool {
	return http.respond(conn, .OK, body, {
		content_type = "application/json",
		keep_alive   = req.keep_alive,
	})
}

// 501 是 P2 的占位，上游没有这个状态码。/ubus/subscribe 一直留在这里直到 P3。
@(private)
not_implemented :: proc(conn: ^http.Connection, req: ^http.Request) -> bool {
	return http.respond(conn, .Not_Implemented, "not implemented\n", {
		keep_alive = req.keep_alive,
	})
}

// ---------------------------------------------------------------------------
// 会话
// ---------------------------------------------------------------------------

// 上游 uh_ubus_get_auth（`ubus.c:120-137`）：只认 authorization 头，且值必须以
// "Bearer " 开头（大小写不敏感）；否则回退到哨兵 sid。不做任何 trim——
// 上游也没有。
@(private)
auth_sid :: proc(req: ^http.Request) -> string {
	v, ok := http.header_value(req, "authorization")
	if ok && len(v) >= 7 && strings.equal_fold(v[:7], "Bearer ") {
		return v[7:]
	}
	return UBUS_DEFAULT_SID
}

// ---------------------------------------------------------------------------
// 旧式 POST /ubus
// ---------------------------------------------------------------------------

// 上游 uh_ubus_data_done（`ubus.c:844-859`）：正文是对象走单请求，是数组走批请求。
@(private)
rpc_legacy :: proc(body: []byte, alloc: mem.Allocator) -> string {
	root: json.Value
	if json.unmarshal(body, &root, .JSON, alloc) != nil {
		// 上游 json_tokener_parse_ex 失败 → jsobj 为空 → ERROR_PARSE（`:856-857`）
		return rpc_error_json(.Parse, "null", alloc)
	}

	// json.Value 的变体很多，这里只关心容器类型；标量与 null 都归到 -32700。
	#partial switch v in root {
	case json.Object:
		return legacy_one(v, alloc)

	case json.Array:
		// 上游 uh_ubus_init_batch（`ubus.c:756-763`）：正文是 [<信封>,…]，
		// 元素之间插 ','（`:203-204` 的 sep）。
		b := strings.builder_make(alloc)
		strings.write_byte(&b, '[')
		for el, i in v {
			if i > 0 {
				strings.write_byte(&b, ',')
			}
			obj, is_obj := el.(json.Object)
			part := is_obj ? legacy_one(obj, alloc) : rpc_error_json(.Parse, "null", alloc)
			strings.write_string(&b, part)
		}
		strings.write_byte(&b, ']')
		return strings.to_string(b)

	case:
		// 上游：既不是对象也不是数组（字符串/数字/null）→ ERROR_PARSE
		return rpc_error_json(.Parse, "null", alloc)
	}
}

// 旧式正文里的一个 JSON-RPC 请求对象。上游 uh_ubus_handle_request_object
// （`ubus.c:771-827`）。
@(private)
legacy_one :: proc(obj: json.Object, alloc: mem.Allocator) -> string {
	id_json := rpc_id_json(obj, alloc)

	method, m_ok := rpc_str(obj, "method")
	ver, v_ok := rpc_str(obj, "jsonrpc")
	// 上游 parse_json_rpc（`ubus.c:696-723`）：jsonrpc 必须是 "2.0"，method 必须存在。
	// 不满足时 err 还是初值 ERROR_PARSE，所以这里回 -32700 而不是 -32600。
	if !m_ok || !v_ok || ver != "2.0" {
		return rpc_error_json(.Parse, id_json, alloc)
	}

	params, _ := obj["params"]
	switch method {
	case "call":
		// 上游 parse_call_params（`ubus.c:725-754`）+ `:794-795`：params 必须是
		// 四元数组 [sid, 对象, 方法, 参数表]，四项缺一即 parse error。
		arr, is_arr := params.(json.Array)
		if !is_arr || len(arr) < 4 {
			return rpc_error_json(.Parse, id_json, alloc)
		}
		sid, s_ok := arr[0].(json.String)
		path, p_ok := arr[1].(json.String)
		func_, f_ok := arr[2].(json.String)
		data, d_ok := arr[3].(json.Object)
		if !s_ok || !p_ok || !f_ok || !d_ok {
			return rpc_error_json(.Parse, id_json, alloc)
		}
		data_value: json.Value = data
		return invoke(string(path), string(func_), true, data_value, string(sid), id_json, .Legacy, alloc)

	case "list":
		return legacy_list(params, id_json, alloc)
	}

	// 上游：method 既不是 "call" 也不是 "list" → ERROR_METHOD（`ubus.c:815-818`）
	return rpc_error_json(.Method, id_json, alloc)
}

// 旧式 method:"list"（上游 uh_ubus_send_list，`ubus.c:658-694`）。
//
// params 不是数组（含没有 params、含 null）→ result 是**对象路径数组**；
// params 是数组 → result 是**详细表** {"<路径>": {"<方法>": {"<参数>": "<类型>"}}}，
// 数组里每个元素当成要查的对象路径，查不到的路径直接忽略（上游根本没看
// ubus_lookup 的返回值，`:682`）。
@(private)
legacy_list :: proc(params: json.Value, id_json: string, alloc: mem.Allocator) -> string {
	arr, is_arr := params.(json.Array)
	if !is_arr {
		return fmt.aprintf(`{{"jsonrpc":"2.0","id":%s,"result":%s}}`, id_json, list_paths_json(alloc), allocator = alloc)
	}

	merged := make(json.Object, len(arr), alloc)
	for el in arr {
		path, is_str := el.(json.String)
		if !is_str {
			// 上游直接把数组元素当 C 字符串用（blobmsg_data），非字符串元素我们跳过
			continue
		}
		sig_text, _, ok := backend.list_objects(string(path), alloc)
		if !ok {
			continue
		}
		sig: json.Value
		if json.unmarshal_string(sig_text, &sig, .JSON, alloc) != nil {
			continue
		}
		table, is_table := sig.(json.Object)
		if !is_table {
			continue
		}
		merged[string(path)] = table
	}

	merged_value: json.Value = merged
	body, err := json.unparse(merged_value, {spec = .JSON, sort_maps_by_key = true}, alloc)
	if err != nil {
		return rpc_error_json(.Internal, id_json, alloc)
	}
	return fmt.aprintf(`{{"jsonrpc":"2.0","id":%s,"result":%s}}`, id_json, body, allocator = alloc)
}

// 全部对象路径，字典序（上游的顺序来自 ubus 的 avl 树，也是有序的）。
@(private)
list_paths_json :: proc(alloc: mem.Allocator) -> string {
	text, _, ok := backend.list_objects("", alloc)
	if !ok {
		// 上游不看 ubus_lookup 的返回值，失败就是空数组
		return "[]"
	}
	root: json.Value
	if json.unmarshal_string(text, &root, .JSON, alloc) != nil {
		return "[]"
	}
	table, is_table := root.(json.Object)
	if !is_table {
		return "[]"
	}

	paths := make([dynamic]string, 0, len(table), alloc)
	for path in table {
		append(&paths, path)
	}
	slice.sort(paths[:])

	arr := make(json.Array, 0, len(paths), alloc)
	for path in paths {
		append(&arr, json.String(path))
	}
	arr_value: json.Value = arr
	body, err := json.unparse(arr_value, {spec = .JSON}, alloc)
	if err != nil {
		return "[]"
	}
	return body
}

// ---------------------------------------------------------------------------
// 新式 POST /ubus/call/<path>
// ---------------------------------------------------------------------------

// 上游 uh_ubus_call（`ubus.c:861-905`）：method 直接就是 ubus 方法名，
// 对象路径来自 URL，params 是参数表（可以完全没有）。
@(private)
rpc_rest :: proc(path, sid: string, body: []byte, alloc: mem.Allocator) -> string {
	root: json.Value
	if json.unmarshal(body, &root, .JSON, alloc) != nil {
		return rpc_error_json(.Parse, "null", alloc)
	}
	obj, is_obj := root.(json.Object)
	if !is_obj {
		return rpc_error_json(.Parse, "null", alloc)
	}
	id_json := rpc_id_json(obj, alloc)

	method, m_ok := rpc_str(obj, "method")
	ver, v_ok := rpc_str(obj, "jsonrpc")
	if !m_ok || !v_ok || ver != "2.0" {
		return rpc_error_json(.Parse, id_json, alloc)
	}

	params, has_params := obj["params"]
	return invoke(path, method, has_params, params, sid, id_json, .Rest, alloc)
}

// ---------------------------------------------------------------------------
// 一次 ubus 调用（旧式与新式共用的尾巴）
// ---------------------------------------------------------------------------

// has_params 要单独传：`unmarshal` 把 JSON 的 null 解析成 nil union，
// 只看 params 的值分不清「没有 params 字段」和「params 是 null」，
// 而这两者在上游里一个是空参数表、一个是 -32602。
@(private)
invoke :: proc(
	path, method: string,
	has_params: bool,
	params: json.Value,
	sid, id_json: string,
	shape: Rpc_Shape,
	alloc: mem.Allocator,
) -> string {
	params_json := ""
	if has_params {
		table, is_table := params.(json.Object)
		if !is_table {
			// 上游 uh_ubus_send_request（`ubus.c:575-576`）：非表一律 -32602。
			// null 也走这条。
			return invalid_params_json(path, id_json, alloc)
		}
		if _, has := table["ubus_rpc_session"]; has {
			// 上游 `ubus.c:578-582`：客户端自带 ubus_rpc_session 直接拒绝，
			// 免得覆盖 molly 追加的那一个（会话固定）。
			return invalid_params_json(path, id_json, alloc)
		}
		table_value: json.Value = table
		body, err := json.unparse(table_value, {spec = .JSON, sort_maps_by_key = true}, alloc)
		if err != nil {
			return rpc_error_json(.Internal, id_json, alloc)
		}
		params_json = body
	}

	res := backend.call_object(path, method, params_json, sid, alloc)
	switch res.outcome {
	case .Object_Not_Found:
		return rpc_error_json(.Object, id_json, alloc)
	case .Internal:
		return rpc_error_json(.Internal, id_json, alloc)
	case .Ok:
	}

	if res.ret != 0 {
		// 上游 uh_ubus_request_cb（`ubus.c:495-503`）：ubus 返回码进 error.code，
		// 文案取 ubus_strerror —— 不是 JSON-RPC 的 -32xxx 表。
		msg := backend.ubus_error_message(res.ret, alloc)
		payload := fmt.aprintf(`"error":{{"code":%d,"message":"%s"}}`, res.ret, msg, allocator = alloc)
		return fmt.aprintf(`{{"jsonrpc":"2.0","id":%s,%s}}`, id_json, payload, allocator = alloc)
	}

	if shape == .Legacy {
		// 旧式 result 恒为数组，空回复也是（`ubus.c:474-491`）
		if len(res.reply) > 0 {
			return fmt.aprintf(`{{"jsonrpc":"2.0","id":%s,"result":[0,%s]}}`, id_json, res.reply, allocator = alloc)
		}
		return fmt.aprintf(`{{"jsonrpc":"2.0","id":%s,"result":[0]}}`, id_json, allocator = alloc)
	}
	if len(res.reply) > 0 {
		return fmt.aprintf(`{{"jsonrpc":"2.0","id":%s,"result":%s}}`, id_json, res.reply, allocator = alloc)
	}
	// 无回复数据：上游加一个 UNSPEC 字段，格式化出来是 null（`ubus.c:512`）
	return fmt.aprintf(`{{"jsonrpc":"2.0","id":%s,"result":null}}`, id_json, allocator = alloc)
}

// 上游的错误优先级：ubus_lookup_id（→ -32000）排在 params 校验（→ -32602）之前
// （`ubus.c:885-895`、`:798-808`）。所以判 params 有问题时要先探一次对象，
// 保证同一份请求在两个实现下回同一个错误码。
@(private)
invalid_params_json :: proc(path, id_json: string, alloc: mem.Allocator) -> string {
	if _, _, ok := backend.list_objects(path, alloc); !ok {
		return rpc_error_json(.Object, id_json, alloc)
	}
	return rpc_error_json(.Params, id_json, alloc)
}

// ---------------------------------------------------------------------------
// JSON 小工具
// ---------------------------------------------------------------------------

@(private)
rpc_error_json :: proc(kind: Rpc_Error, id_json: string, alloc: mem.Allocator) -> string {
	def := RPC_ERRORS[kind]
	payload := fmt.aprintf(`"error":{{"code":%d,"message":"%s"}}`, def.code, def.msg, allocator = alloc)
	return fmt.aprintf(`{{"jsonrpc":"2.0","id":%s,%s}}`, id_json, payload, allocator = alloc)
}

// 从 JSON 对象里取字符串字段。上游用的是 blobmsg 的 STRING 策略，类型不匹配
// 等于「没有这个字段」，所以这里返回 ok == false。
@(private)
rpc_str :: proc(obj: json.Object, key: string) -> (string, bool) {
	val, has := obj[key]
	if !has {
		return "", false
	}
	s, is_str := val.(json.String)
	if !is_str {
		return "", false
	}
	return string(s), true
}

// 上游 uh_ubus_init_json_rpc_response（`ubus.c:217-231`）：有 id 就原样回，
// 没有就补一个格式化出来是 null 的字段。
@(private)
rpc_id_json :: proc(obj: json.Object, alloc: mem.Allocator) -> string {
	val, has := obj["id"]
	// null 会被 unmarshal 解析成 nil union，与「没有 id」在这里等价（都是 null）
	if !has || val == nil {
		return "null"
	}
	body, err := json.unparse(val, {spec = .JSON}, alloc)
	if err != nil {
		return "null"
	}
	return body
}