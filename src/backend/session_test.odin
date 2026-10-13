package backend

import "core:testing"
import "core:mem"
import "core:fmt"
import "core:encoding/json"

// 取 reply（JSON 对象）里的一个字符串字段；失败返回 ("", false)。
reply_str_field :: proc(t: ^testing.T, alloc: mem.Allocator, reply: string, field: string) -> (string, bool) {
	v, err := json.parse_string(reply, .JSON, true, alloc)
	if err != nil {
		testing.expectf(t, false, "reply 不是合法 JSON: %s", reply)
		return "", false
	}
	o, ok := v.(json.Object)
	if !ok {
		return "", false
	}
	fv, has := o[field]
	if !has {
		return "", false
	}
	s, is_str := fv.(json.String)
	return string(s), is_str
}

// session 触及进程级全局（store / registry / bus），与其余 @(test) 合并到单线程跑（ODIN_TEST_THREADS=1）。
@(test)
test_session :: proc(t: ^testing.T) {
	backing: [262144]u8
	ar: mem.Arena
	mem.arena_init(&ar, backing[:])
	old := context.allocator
	context.allocator = mem.arena_allocator(&ar)
	defer context.allocator = old
	alloc := context.allocator

	st: i32
	reply: string

	// ---- login：错误密码被拒 ----
	st, reply = Dispatch(alloc, "session", "login", `{"username":"root","password":"wrong"}`)
	testing.expect_value(t, st, Status_Permission_Denied)

	// ---- login：成功（宿主假凭据 $p$root ⇔ test1234）----
	st, reply = Dispatch(alloc, "session", "login", `{"username":"root","password":"test1234","timeout":300}`)
	testing.expect_value(t, st, Status_OK)
	sid, ok := reply_str_field(t, alloc, reply, "ubus_rpc_session")
	testing.expect(t, ok, "login reply 应带 ubus_rpc_session")
	testing.expect_value(t, len(sid), 32)

	// data.username == "root"，data.token 是字符串（登录可用性的硬要求）
	vv, _ := json.parse_string(reply, .JSON, true, alloc)
	data_obj, _ := vv.(json.Object)
	dv := data_obj["data"]
	data, is_data := dv.(json.Object)
	testing.expect(t, is_data, "login reply 应带 data 对象")
	uname, is_uname := data["username"].(json.String)
	testing.expect(t, is_uname && string(uname) == "root", "data.username 应为 root")
	_, is_tok := data["token"].(json.String)
	testing.expect(t, is_tok, "data.token 应为字符串")

	// ---- create / set / get / destroy 往返 ----
	st, reply = Dispatch(alloc, "session", "create", `{"timeout":300}`)
	testing.expect_value(t, st, Status_OK)
	csid, cok := reply_str_field(t, alloc, reply, "ubus_rpc_session")
	testing.expect(t, cok, "create reply 应带 ubus_rpc_session")

	// 注：下面用 fmt.tprintf 拼参数串，字面量花括号必须写成 {{ }} 以免被当作 {} 格式化槽。
	set_params := fmt.tprintf(`{{"ubus_rpc_session":"%s","values":{{"foo":"bar"}}}}`, csid)
	st, reply = Dispatch(alloc, "session", "set", set_params)
	testing.expect_value(t, st, Status_OK)

	get_params := fmt.tprintf(`{{"ubus_rpc_session":"%s","keys":["foo"]}}`, csid)
	st, reply = Dispatch(alloc, "session", "get", get_params)
	testing.expect_value(t, st, Status_OK)
	gv, _ := json.parse_string(reply, .JSON, true, alloc)
	gobj, _ := gv.(json.Object)
	wo, _ := gobj["values"].(json.Object)
	foo, is_foo := wo["foo"].(json.String)
	testing.expect(t, is_foo && string(foo) == "bar", "get 应回 values.foo=bar")

	// ---- self-service ----
	testing.expect(t, Session_Self_Service(csid, "get"), "有效会话可自服务 get")
	testing.expect(t, !Session_Self_Service(csid, "login"), "login 不属自服务范围")
	testing.expect(t, !Session_Self_Service(Sess_Default_ID, "get"), "默认会话不属自服务")

	// ---- destroy ----
	destroy_params := fmt.tprintf(`{{"ubus_rpc_session":"%s"}}`, csid)
	st, reply = Dispatch(alloc, "session", "destroy", destroy_params)
	testing.expect_value(t, st, Status_OK)
	st, reply = Dispatch(alloc, "session", "get", get_params)
	testing.expect_value(t, st, Status_Not_Found)

	// 默认会话不可销毁
	st, reply = Dispatch(alloc, "session", "destroy", fmt.tprintf(`{{"ubus_rpc_session":"%s"}}`, Sess_Default_ID))
	testing.expect_value(t, st, Status_Permission_Denied)

	// ---- access 形态（返回布尔）----
	st, reply = Dispatch(alloc, "session", "access", fmt.tprintf(`{{"ubus_rpc_session":"%s","object":"file","function":"read"}}`, sid))
	testing.expect_value(t, st, Status_OK)
	av, aerr := json.parse_string(reply, .JSON, true, alloc)
	testing.expect(t, aerr == nil, "access 应回合法 JSON")
	aobj, _ := av.(json.Object)
	_, has_access := aobj["access"]
	testing.expect(t, has_access, "access 回包含 access 键")
}
