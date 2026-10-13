package handlers

// ubus_http_test —— /ubus handler 纯逻辑层（rpc_legacy/rpc_rest/invoke 的门序与信封、
// legacy_list/list_paths_json、auth_sid、JSON 小工具）的单元测试。
//
// 只在 darwin（host）上验「JSON-RPC 信封形状 + backend 接缝调用序」这条链；provider 的真实
// 往返交回 backend 的 object_provider_test。host 无 ACL 目录 → 未认证哨兵会话对**任何**
// 已知对象都 fail-closed（-32002），未知对象在更早的存在性预检处 -32000——这两条是本机可
// 稳定断言的门序；成功回复信封（result / [0,reply] 形状）由 provider 接缝与 s5 的 smoke 覆盖。
//
// 断言只盯结构标记（错误码、键、数组/对象边界），不钉死整串，避免 sig 排版微调把测试打挂。

import "core:testing"
import "core:mem"
import "core:strings"
import "core:encoding/json"
import "molly:http"

// has_rpc_code —— 回复里 error.code 是否等于某 JSON-RPC 错误码。
has_rpc_code :: proc(t: ^testing.T, body: string, code: i64) -> bool {
	v, err := json.parse_string(body, .JSON, true, context.allocator)
	testing.expectf(t, err == nil, "回复应为合法 JSON：%q", body)
	o, ok := v.(json.Object)
	if ! ok {
		testing.expectf(t, false, "回复应为 JSON 对象：%q", body)
		return false
	}
	er, is_obj := o["error"].(json.Object)
	if ! is_obj {
		return false
	}
	c, is_int := er["code"].(json.Integer)
	return is_int && c == json.Integer(code)
}

@(test)
test_ubus_auth_sid :: proc(t: ^testing.T) {
	backing: [262144]u8
	ar: mem.Arena
	mem.arena_init(&ar, backing[:])
	context.allocator = mem.arena_allocator(&ar)

	// Bearer 前缀（大小写不敏感）→ 取其后原样（不 trim）。
	rq: http.Request
	rq.method = "POST"
	append(&rq.headers, http.Header{"Authorization", "Bearer abc123"})
	testing.expect_value(t, auth_sid(&rq), "abc123")

	rq2: http.Request
	rq2.method = "POST"
	append(&rq2.headers, http.Header{"authorization", "bearer XYZ"})
	testing.expect_value(t, auth_sid(&rq2), "XYZ")

	// 非 Bearer / 缺失 → 32 个 0 的哨兵。
	rq3: http.Request
	rq3.method = "POST"
	append(&rq3.headers, http.Header{"Authorization", "token abc"})
	testing.expect_value(t, auth_sid(&rq3), ubus_default_sid)

	rq4: http.Request
	rq4.method = "POST"
	testing.expect_value(t, auth_sid(&rq4), ubus_default_sid)
}

@(test)
test_ubus_rpc_legacy_parse :: proc(t: ^testing.T) {
	backing: [262144]u8
	ar: mem.Arena
	mem.arena_init(&ar, backing[:])
	context.allocator = mem.arena_allocator(&ar)

	// 非 JSON → parse error(-32700)。
	out := rpc_legacy("not json")
	testing.expectf(t, has_rpc_code(t, out, -32700), "非法 JSON 应 -32700：%q", out)

	// 顶层是数字（非对象/数组）→ parse error。
	out = rpc_legacy("42")
	testing.expectf(t, has_rpc_code(t, out, -32700), "标量入参应 -32700：%q", out)

	// 批请求：数组元素逐个处理，边界是 [ ]，非对象元素各回 parse error。
	out = rpc_legacy("[1,2]")
	testing.expectf(t, strings.has_prefix(out, "[") && strings.has_suffix(out, "]"), "批回复应是数组：%q", out)

	// jsonrpc 版本不对 → parse error（-32700，非 -32600）。
	out = rpc_legacy(`{"jsonrpc":"1.0","id":7,"method":"foo"}`)
	testing.expectf(t, has_rpc_code(t, out, -32700), "版本非 2.0 应 -32700：%q", out)

	// 版本对、method 未知（非 call/list）→ method not found(-32601)，id 原样回。
	out = rpc_legacy(`{"jsonrpc":"2.0","id":"x","method":"foo"}`)
	testing.expectf(t, has_rpc_code(t, out, -32601), "未知 method 应 -32601：%q", out)
	testing.expectf(t, strings.contains(out, `"id":"x"`), "id 应原样回：%q", out)

	// call 的 params 不是四元数组 → parse error。
	out = rpc_legacy(`{"jsonrpc":"2.0","id":1,"method":"call","params":["a","b"]}`)
	testing.expectf(t, has_rpc_code(t, out, -32700), "params 不足四元应 -32700：%q", out)
}

@(test)
test_ubus_rpc_legacy_list :: proc(t: ^testing.T) {
	backing: [262144]u8
	ar: mem.Arena
	mem.arena_init(&ar, backing[:])
	context.allocator = mem.arena_allocator(&ar)

	// 无 params → result 是全部对象路径数组（darwin 假表：file/luci/luci-rpc/molly.probe/session/uci）。
	out := rpc_legacy(`{"jsonrpc":"2.0","id":2,"method":"list"}`)
	testing.expectf(t, strings.contains(out, `"result":[`), "list 无参 result 应是数组：%q", out)
	testing.expectf(t, strings.contains(out, `"uci"`), "路径数组应含 uci：%q", out)
	testing.expectf(t, strings.contains(out, `"molly.probe"`), "路径数组应含 molly.probe：%q", out)

	// params 是数组 → result 是详细表 {path: sig}；命中的嵌入原样，未知路径忽略。
	out = rpc_legacy(`{"jsonrpc":"2.0","id":3,"method":"list","params":["uci","does-not-exist"]}`)
	testing.expectf(t, strings.contains(out, `"result":{"uci":`), "详细表应含 uci：%q", out)
	testing.expectf(t, !strings.contains(out, "does-not-exist"), "未知路径应被忽略：%q", out)
}

@(test)
test_ubus_invoke_gate :: proc(t: ^testing.T) {
	backing: [262144]u8
	ar: mem.Arena
	mem.arena_init(&ar, backing[:])
	context.allocator = mem.arena_allocator(&ar)

	// 门 1：对象不存在 → -32000（早于 ACL）。
	out := rpc_legacy(`{"jsonrpc":"2.0","id":1,"method":"call","params":["","does-not-exist","get",{}]}`)
	testing.expectf(t, has_rpc_code(t, out, -32000), "未知对象应 -32000：%q", out)

	// 门 2：对象存在但未授权（host 无 ACL 目录，哨兵会话恒 fail-closed）→ -32002。
	out = rpc_legacy(`{"jsonrpc":"2.0","id":1,"method":"call","params":["","uci","get",{}]}`)
	testing.expectf(t, has_rpc_code(t, out, -32002), "未授权应 -32002：%q", out)

	// 新式同理：/ubus/call/<未知> → -32000；<已知> → -32002。
	out = rpc_rest("does-not-exist", ubus_default_sid, `{"jsonrpc":"2.0","id":9,"method":"get"}`)
	testing.expectf(t, has_rpc_code(t, out, -32000), "新式未知对象应 -32000：%q", out)

	out = rpc_rest("uci", ubus_default_sid, `{"jsonrpc":"2.0","id":9,"method":"get"}`)
	testing.expectf(t, has_rpc_code(t, out, -32002), "新式未授权应 -32002：%q", out)
}

@(test)
test_ubus_json_helpers :: proc(t: ^testing.T) {
	backing: [65536]u8
	ar: mem.Arena
	mem.arena_init(&ar, backing[:])
	context.allocator = mem.arena_allocator(&ar)

	// json_quote_string：引号/反斜杠/控制符转义，首尾带引号。
	testing.expect_value(t, json_quote_string(`a"b\c`), `"a\"b\\c"`)
	testing.expect_value(t, json_quote_string("x\ny"), `"x\ny"`)

	// ubus_code_message：{"code":N,"message":"…"}（ubus 码非 JSON-RPC 码表）。
	m := ubus_code_message(4)
	testing.expectf(t, strings.contains(m, `"code":4`), "应含 code:4：%q", m)
	testing.expectf(t, strings.contains(m, "Not found"), "应含 ubus 文案：%q", m)

	// envelope_result / envelope_error 的基本形状。
	r := envelope_result("null", `{"ok":1}`)
	testing.expect_value(t, r, `{"jsonrpc":"2.0","id":null,"result":{"ok":1}}`)
	e := envelope_error("5", `{"code":-32000,"message":"Object not found"}`)
	testing.expect_value(t, e, `{"jsonrpc":"2.0","id":5,"error":{"code":-32000,"message":"Object not found"}}`)
}
