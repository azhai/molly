package backend

// object_provider_test —— backend↔handler 窄接口接缝（object_call + darwin provider）的单元测试。
//
// 只在 darwin（host）上验「HTTP 层 → provider → 自有对象/回显」这条链的形状；linux 的真 ubus
// 往返只能交叉编译 + 设备验证。刻意避开 session/uci/file 这些会写全局 store 的对象，只用无状态的
// molly.probe / luci，保证本测试可隔离单跑（不受全量套件的跨测试污染影响）。

import "core:testing"
import "core:mem"
import "core:strings"
import "core:encoding/json"

obj_str :: proc(t: ^testing.T, alloc: mem.Allocator, text, key: string) -> string {
	v, err := json.parse_string(text, .JSON, true, alloc)
	testing.expectf(t, err == nil, "回复应为合法 JSON：%q", text)
	o, ok := v.(json.Object)
	testing.expectf(t, ok, "回复应为 JSON 对象：%q", text)
	if s, is := o[key].(json.String); is {
		return string(s)
	}
	return ""
}

@(test)
test_object_inject_rpc_session :: proc(t: ^testing.T) {
	backing: [262144]u8
	ar: mem.Arena
	mem.arena_init(&ar, backing[:])
	context.allocator = mem.arena_allocator(&ar)
	alloc := context.allocator

	// 保留原有键，追加 ubus_rpc_session。
	s := inject_rpc_session(`{"config":"network"}`, "abc123", alloc)
	testing.expect_value(t, obj_str(t, alloc, s, "config"), "network")
	testing.expect_value(t, obj_str(t, alloc, s, "ubus_rpc_session"), "abc123")

	// 入参非对象 → 退化成「只有 ubus_rpc_session」。
	s = inject_rpc_session(`[1,2,3]`, "sid1", alloc)
	testing.expect_value(t, obj_str(t, alloc, s, "ubus_rpc_session"), "sid1")
	testing.expectf(t, !strings.contains(s, "1,2,3"), "非对象入参应被丢弃：%q", s)

	// 空 params + 有 sid → 只有 sid。
	s = inject_rpc_session("", "sid9", alloc)
	testing.expect_value(t, obj_str(t, alloc, s, "ubus_rpc_session"), "sid9")
}

@(test)
test_object_call_own :: proc(t: ^testing.T) {
	backing: [262144]u8
	ar: mem.Arena
	mem.arena_init(&ar, backing[:])
	context.allocator = mem.arena_allocator(&ar)
	alloc := context.allocator

	// luci 只抢 getFeatures 这一条。
	reply, status, handled := call_own_object("luci", "getFeatures", "{}", "", alloc)
	testing.expect_value(t, handled, true)
	testing.expect_value(t, status, Status_OK)
	testing.expect_value(t, reply, `{"features":{"luci-sysrepo":false}}`)

	// luci 的其它方法交回 provider（handled=false）。
	_, _, handled = call_own_object("luci", "getVersion", "{}", "", alloc)
	testing.expect_value(t, handled, false)

	// molly.probe 是注册对象：ping 无状态。
	reply, status, handled = call_own_object("molly.probe", "ping", "{}", "", alloc)
	testing.expect_value(t, handled, true)
	testing.expect_value(t, status, Status_OK)
	testing.expect_value(t, reply, `{"pong":"molly"}`)

	// 非自有对象（如 netifd）→ handled=false，交回 provider。
	_, _, handled = call_own_object("network", "status", "{}", "", alloc)
	testing.expect_value(t, handled, false)
}

@(test)
test_object_list_and_external :: proc(t: ^testing.T) {
	backing: [262144]u8
	ar: mem.Arena
	mem.arena_init(&ar, backing[:])
	context.allocator = mem.arena_allocator(&ar)
	alloc := context.allocator

	// 全量 list：含自有对象签名。
	j, err, ok := List_Objects("", alloc)
	testing.expect_value(t, ok, true)
	testing.expect_value(t, err, 0)
	testing.expectf(t, strings.contains(j, `"uci":`), "list 应含 uci：%q", j)
	testing.expectf(t, strings.contains(j, `"molly.probe":`), "list 应含 molly.probe")

	// 单对象：未知路径 → NOT_FOUND（handler 据此回 500 + {"code":4}）。
	_, err, ok = List_Objects("does-not-exist", alloc)
	testing.expect_value(t, ok, false)
	testing.expect_value(t, err, Status_Not_Found)

	// 外部对象不在假表里 → Object_Not_Found。
	res := Call_Object("network", "status", "{}", "", alloc)
	testing.expect_value(t, res.outcome, .Object_Not_Found)

	// luci 的未知方法（在假签名里找不到 "getVersion":）→ Ok + Method_Not_Found。
	res = Call_Object("luci", "getVersion", "{}", "", alloc)
	testing.expect_value(t, res.outcome, .Ok)
	testing.expect_value(t, res.ret, Status_Method_Not_Found)

	// luci 的已知方法（getInitList 在 luci_sig 里）→ 回显（provider echo，非自有对象路径）。
	res = Call_Object("luci", "getInitList", `{"name":"dnsmasq"}`, "sidX", alloc)
	testing.expect_value(t, res.outcome, .Ok)
	testing.expect_value(t, res.ret, 0)
	testing.expectf(t, strings.contains(res.reply, `"echo"`), "外部已知方法应回显：%q", res.reply)
	v, _ := json.parse_string(res.reply, .JSON, true, alloc)
	inner, _ := v.(json.Object)["echo"].(json.Object)
	testing.expect_value(t, string(inner["method"].(json.String)), "getInitList")
	testing.expect_value(t, string(inner["sid"].(json.String)), "sidX")
}
