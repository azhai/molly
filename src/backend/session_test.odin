package backend

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:testing"

// 单元测试：session 对象（P3-2）。语义依据 rpcd `session.c`（行号写在 session.odin 每处实现旁）。
//
// 运行：odin test -collection:molly=src src/backend   （或 ./tests/unit.sh）
//
// 验证边界：login 的密码校验走 darwin 的测试替身（`session_verify_password`：`$p$root` →
// "test1234"）。设备上 /etc/shadow + crypt() 的那条路只能在真机上验（第 7 步）。
//
// 注意：`session_call` 操作的是包级 store，且 `odin test` 默认 4 线程并行跑用例，
// 所以每个用例都用自己 create/login 出来的 sid，不假设 store 是空的。

@(private)
t_call :: proc(method, params: string, alloc: mem.Allocator) -> (string, int) {
	return session_call(method, params, alloc)
}

// 从回复里取一个顶层字段；取不到就返回空串（测试里用 expect 判空来发现结构不符）。
@(private)
t_field :: proc(reply, key: string, alloc: mem.Allocator) -> string {
	doc: json.Value
	if err := json.unmarshal(transmute([]byte)(reply), &doc, .JSON, alloc); err != nil {
		return ""
	}
	obj, is_obj := doc.(json.Object)
	if !is_obj {
		return ""
	}
	raw, found := obj[key]
	if !found {
		return ""
	}
	if s, ok := raw.(json.String); ok {
		return string(s)
	}
	if _, ok := raw.(json.Integer); ok {
		return "int"
	}
	if _, ok := raw.(json.Object); ok {
		return "object"
	}
	if _, ok := raw.(json.Array); ok {
		return "array"
	}
	if _, ok := raw.(json.Boolean); ok {
		return "bool"
	}
	if _, ok := raw.(json.Null); ok {
		return "null"
	}
	if _, ok := raw.(json.Float); ok {
		return "float"
	}
	return ""
}

// 登录并返回 sid（失败时空串）
@(private)
t_login :: proc(user, pass: string, alloc: mem.Allocator) -> string {
	params := fmt.aprintf(`{{"username":"%s","password":"%s"}}`, user, pass, allocator = alloc)
	reply, status := t_call("login", params, alloc)
	if status != 0 {
		return ""
	}
	doc: json.Value
	if err := json.unmarshal(transmute([]byte)(reply), &doc, .JSON, alloc); err != nil {
		return ""
	}
	obj, is_obj := doc.(json.Object)
	if !is_obj {
		return ""
	}
	if v, found := obj["ubus_rpc_session"]; found {
		if s, is_str := v.(json.String); is_str {
			return string(s)
		}
	}
	return ""
}

@(private)
t_sid_params :: proc(sid: string, rest := "") -> string {
	if len(rest) == 0 {
		return fmt.aprintf(`{{"ubus_rpc_session":"%s"}}`, sid, allocator = context.temp_allocator)
	}
	return fmt.aprintf(`{{"ubus_rpc_session":"%s",%s}}`, sid, rest, allocator = context.temp_allocator)
}

// ---------------------------------------------------------------------------
// login 与数据面（session.c:657-791、1152-1214）
// ---------------------------------------------------------------------------

@(test)
test_session_login :: proc(t: ^testing.T) {
	alloc, ar := mk_arena()
	defer drop_arena(ar)

	// 正确凭据（darwin 替身约定：$p$root → "test1234"）
	sid := t_login("root", "test1234", alloc)
	testing.expect(t, len(sid) == SESSION_SID_LEN, "sid 必须是 32 位")
	for i in 0 ..< len(sid) {
		c := sid[i]
		is_hex := (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')
		if !is_hex {
			testing.expectf(t, false, "sid 含非十六进制字符：%s", sid)
			break
		}
	}

	// 错误密码 → PERMISSION_DENIED(6)（session.c:1181-1184）
	_, bad := t_call("login", `{"username":"root","password":"nope"}`, alloc)
	testing.expect_value(t, bad, SESSION_STATUS_PERMISSION_DENIED)

	// 未知用户 → 同样拒绝（/etc/config/rpcd 里没有匹配的 login section）
	_, unknown := t_call("login", `{"username":"admin","password":"test1234"}`, alloc)
	testing.expect_value(t, unknown, SESSION_STATUS_PERMISSION_DENIED)

	// 缺参数 → INVALID_ARGUMENT(2)（session.c:1166-1168）
	_, missing := t_call("login", `{"username":"root"}`, alloc)
	testing.expect_value(t, missing, SESSION_STATUS_INVALID_ARGUMENT)

	// 登录后 data.username 已写入（session.c:1206）
	reply, status := t_call("get", t_sid_params(sid), alloc)
	testing.expect_value(t, status, SESSION_STATUS_OK)
	testing.expect(t, len(reply) > 0)
	testing.expect(t, t_field(reply, "values", alloc) == "object")
}

@(test)
test_session_set_get_unset :: proc(t: ^testing.T) {
	alloc, ar := mk_arena()
	defer drop_arena(ar)

	sid := t_login("root", "test1234", alloc)
	testing.expect(t, len(sid) > 0)

	// set：无回复（上游不回数据）
	reply: string
	status: int
	reply, status = t_call("set", t_sid_params(sid, `"values":{"token":"abc","count":7}`), alloc)
	testing.expect_value(t, status, SESSION_STATUS_OK)
	testing.expect_value(t, reply, "")

	// get：全部值
	reply, _ = t_call("get", t_sid_params(sid), alloc)  // 复用上面的 reply
	testing.expect(t, t_field(reply, "values", alloc) == "object")

	// get + keys：只挑出现的键（session.c:729-742）
	reply, _ = t_call("get", t_sid_params(sid, `"keys":["token","nope"]`), alloc)
	testing.expect(t, t_field(reply, "values", alloc) == "object")

	// set 缺 values → INVALID_ARGUMENT
	_, s2 := t_call("set", t_sid_params(sid), alloc)
	testing.expect_value(t, s2, SESSION_STATUS_INVALID_ARGUMENT)

	// unset 指定键：同样无回复
	unset_reply, u2 := t_call("unset", t_sid_params(sid, `"keys":["count"]`), alloc)
	testing.expect_value(t, u2, SESSION_STATUS_OK)
	testing.expect_value(t, unset_reply, "")

	// unset 不给 keys → 清空（session.c:772-776）
	_, u3 := t_call("unset", t_sid_params(sid), alloc)
	testing.expect_value(t, u3, SESSION_STATUS_OK)

	// 不存在的会话 → NOT_FOUND(4)
	_, nf := t_call("get", `{"ubus_rpc_session":"0123456789abcdef0123456789abcdef"}`, alloc)
	testing.expect_value(t, nf, SESSION_STATUS_NOT_FOUND)

	// 缺 sid → INVALID_ARGUMENT(2)
	_, inv := t_call("get", `{}`, alloc)
	testing.expect_value(t, inv, SESSION_STATUS_INVALID_ARGUMENT)
}

@(test)
test_session_destroy_and_default :: proc(t: ^testing.T) {
	alloc, ar := mk_arena()
	defer drop_arena(ar)

	sid := t_login("root", "test1234", alloc)
	testing.expect(t, len(sid) > 0)

	// destroy 自己的会话 → 无回复，随后查不到
	reply, status := t_call("destroy", t_sid_params(sid), alloc)
	testing.expect_value(t, status, SESSION_STATUS_OK)
	testing.expect_value(t, reply, "")

	_, gone := t_call("get", t_sid_params(sid), alloc)
	testing.expect_value(t, gone, SESSION_STATUS_NOT_FOUND)

	// 默认会话（32 个 0）不可销毁（session.c:806-807）
	_, denied := t_call("destroy", t_sid_params(SESSION_DEFAULT_ID), alloc)
	testing.expect_value(t, denied, SESSION_STATUS_PERMISSION_DENIED)

	// 默认会话本身存在（session.c:1380-1390），且 timeout = 0（永不过期）
	default_reply, ok := t_call("get", t_sid_params(SESSION_DEFAULT_ID), alloc)
	testing.expect_value(t, ok, SESSION_STATUS_OK)
	testing.expect(t, t_field(default_reply, "values", alloc) == "object")
}

// ---------------------------------------------------------------------------
// ACL：grant / revoke / access（session.c:432-654）
// ---------------------------------------------------------------------------

@(test)
test_session_acl_grant_revoke_access :: proc(t: ^testing.T) {
	alloc, ar := mk_arena()
	defer drop_arena(ar)

	// **故意不用 t_login**：darwin fixture 的 root login section 列了 `read/write = '*'`
	// （与真机 `rpcd.config` 的默认值一致），P3-6 起 acl.d 会在登录时全量加载，于是
	// **测试专用的 smoke-full 组**（`"ubus": {"*": ["*"]}`）也生效——那样任何 access 都是
	// true，"未授权→false" 的断言就失去意义。这里直接建会话 + 只按 luci-base 的窄列表
	// 加载 acl.d，测的是 acl.d 驱动的**初始 ACL**（登录→acl.d 的整链路由
	// test_session_login_test_permission / test_session_load_acls_from_fixtures 覆盖）。
	ses := session_new(SESSION_DEFAULT_TIMEOUT)
	testing.expect(t, ses != nil)
	if ses == nil {
		return
	}
	login := acl_test_login([]string{"luci-base"}, []string{}, alloc)
	session_load_acls(ses, &login, session_store_allocator())
	sid := ses.id
	reply, _ := t_call("access", t_sid_params(sid, `"object":"uci","function":"get"`), alloc)
	testing.expect(t, reply == `{"access":true}`, reply)

	// 同一 scope 下没被 acl.d 授予的函数仍是 false（后面 grant/revoke 用它做往返）
	reply, _ = t_call("access", t_sid_params(sid, `"object":"uci","function":"state"`), alloc)
	testing.expect(t, reply == `{"access":false}`, reply)

	// grant：[[object, function], …]（session.c:571-592）
	_, g := t_call("grant", t_sid_params(sid, `"objects":[["uci","state"],["file","*"]]`), alloc)
	testing.expect_value(t, g, SESSION_STATUS_OK)

	// 精确命中
	reply, _ = t_call("access", t_sid_params(sid, `"object":"uci","function":"state"`), alloc)
	testing.expect(t, reply == `{"access":true}`, reply)

	// 同 scope 下的其它方法不命中
	reply, _ = t_call("access", t_sid_params(sid, `"object":"uci","function":"frob"`), alloc)
	testing.expect(t, reply == `{"access":false}`, reply)

	// fnmatch 通配：file/*
	reply, _ = t_call("access", t_sid_params(sid, `"object":"file","function":"read"`), alloc)
	testing.expect(t, reply == `{"access":true}`, reply)

	// 不存在的 scope → false（session.c:604-611）
	reply, _ = t_call("access", t_sid_params(sid, `"scope":"nope","object":"uci","function":"get"`), alloc)
	testing.expect(t, reply == `{"access":false}`, reply)

	// 不给 object/function → 回整个 ACL 表（session.c:646-649）
	reply, _ = t_call("access", t_sid_params(sid), alloc)
	testing.expect(t, reply != "" && reply[0] == '{', reply)

	// revoke 单个条目
	_, r := t_call("revoke", t_sid_params(sid, `"objects":[["file","*"]]`), alloc)
	testing.expect_value(t, r, SESSION_STATUS_OK)
	reply, _ = t_call("access", t_sid_params(sid, `"object":"file","function":"read"`), alloc)
	testing.expect(t, reply == `{"access":false}`, reply)

	// revoke 不给 objects → 清空整个 scope（session.c:496-502）
	_, r2 := t_call("revoke", t_sid_params(sid), alloc)
	testing.expect_value(t, r2, SESSION_STATUS_OK)
	reply, _ = t_call("access", t_sid_params(sid, `"object":"uci","function":"state"`), alloc)
	testing.expect(t, reply == `{"access":false}`, reply)

	// grant 不给 objects → INVALID_ARGUMENT（session.c:568-569）
	_, g2 := t_call("grant", t_sid_params(sid), alloc)
	testing.expect_value(t, g2, SESSION_STATUS_INVALID_ARGUMENT)

	// 不存在的会话 → NOT_FOUND
	_, nf := t_call("grant", `{"ubus_rpc_session":"0123456789abcdef0123456789abcdef","objects":[["a","b"]]}`, alloc)
	testing.expect_value(t, nf, SESSION_STATUS_NOT_FOUND)
}

// ---------------------------------------------------------------------------
// 匹配与工具函数
// ---------------------------------------------------------------------------

@(test)
test_session_fnmatch :: proc(t: ^testing.T) {
	testing.expect(t, fnmatch("*", "anything"))
	testing.expect(t, fnmatch("file", "file"))
	testing.expect(t, !fnmatch("file", "file2"))
	testing.expect(t, fnmatch("?ile", "file"))
	testing.expect(t, !fnmatch("?ile", "f"))
	testing.expect(t, fnmatch("[fa]ile", "file"))
	testing.expect(t, fnmatch("[a-z]ile", "file"))
	testing.expect(t, !fnmatch("[!f]ile", "file"))
	testing.expect(t, fnmatch("a*b", "ab"))
	testing.expect(t, fnmatch("a*b", "axxxb"))
	testing.expect(t, !fnmatch("a*b", "axxxc"))
	// 未闭合的 '[' 按字面量
	testing.expect(t, fnmatch("[abc", "[abc"))
}

@(test)
test_session_acl_id_len :: proc(t: ^testing.T) {
	testing.expect_value(t, acl_id_len("file"), 4)
	testing.expect_value(t, acl_id_len("file*"), 4)
	testing.expect_value(t, acl_id_len("a?b"), 1)
	testing.expect_value(t, acl_id_len("*"), 0)
	testing.expect_value(t, acl_id_len(""), 0)
}

@(test)
test_session_unknown_method :: proc(t: ^testing.T) {
	alloc, ar := mk_arena()
	defer drop_arena(ar)

	_, status := t_call("nope", `{}`, alloc)
	testing.expect_value(t, status, SESSION_STATUS_METHOD_NOT_FOUND)
}

@(test)
test_session_create_timeout :: proc(t: ^testing.T) {
	alloc, ar := mk_arena()
	defer drop_arena(ar)

	// create：timeout 可指定，默认 300（session.c:380-397）
	reply, status := t_call("create", `{"timeout":60}`, alloc)
	testing.expect_value(t, status, SESSION_STATUS_OK)

	doc: json.Value
	testing.expect(t, json.unmarshal(transmute([]byte)(reply), &doc, .JSON, alloc) == nil)
	obj, is_obj := doc.(json.Object)
	testing.expect(t, is_obj)
	if is_obj {
		if v, found := obj["timeout"]; found {
			if n, is_int := v.(json.Integer); is_int {
				testing.expect_value(t, i64(n), i64(60))
			} else {
				testing.expect(t, false, "timeout 必须是整数")
			}
		} else {
			testing.expect(t, false, "回复里必须有 timeout")
		}
		// expires 是剩余秒数（session.c:233），刚创建的必须 <= timeout
		if v, found := obj["expires"]; found {
			if n, is_int := v.(json.Integer); is_int {
				testing.expect(t, i64(n) <= 60)
			}
		}
	}
}

// ---------------------------------------------------------------------------
// P3-6：acl.d 加载与权限组判定
// ---------------------------------------------------------------------------

// login section 的列表选项就是权限组清单；这里手工构造，不依赖 fixtures 里的 rpcd 配置。
// 分配走调用方给的 alloc（测试自己的 arena）——**不要**用 context.allocator：那样每个调用点
// 都要手工 delete，漏一个就是一条 `leak` 警告（P3-6 时踩过）。
@(private)
acl_test_login :: proc(read_groups: []string, write_groups: []string, alloc: mem.Allocator) -> Uci_Section {
	// 定长 2、按需填（Odin 的 slice make 没有 cap 参数）
	opts := make([]Uci_Option, 2, alloc)
	n := 0
	if len(read_groups) > 0 {
		opts[n] = Uci_Option{name = "read", is_list = true, values = read_groups}
		n += 1
	}
	if len(write_groups) > 0 {
		opts[n] = Uci_Option{name = "write", is_list = true, values = write_groups}
		n += 1
	}
	return Uci_Section {
		name = "login",
		type_name = "login",
		options = opts[:n],
	}
}

@(test)
test_session_login_test_permission :: proc(t: ^testing.T) {
	alloc, ar := mk_arena()
	defer drop_arena(ar)

	// login == NULL（默认/哨兵会话）只认 unauthenticated
	testing.expect(t, session_login_test_permission(nil, "read", "unauthenticated"))
	testing.expect(t, !session_login_test_permission(nil, "read", "luci-base"))

	// 列表里列出的组
	login := acl_test_login([]string{"luci-base"}, []string{"!luci-base", "luci-write"}, alloc)
	testing.expect(t, session_login_test_permission(&login, "read", "luci-base"))
	testing.expect(t, !session_login_test_permission(&login, "read", "other-group"))

	// fnmatch：`luci-n*` 匹配 luci-network
	login2 := acl_test_login([]string{"luci-n*"}, []string{}, alloc)
	testing.expect(t, session_login_test_permission(&login2, "read", "luci-network"))
	testing.expect(t, !session_login_test_permission(&login2, "read", "luci-base"))

	// write 蕴含 read：write 列表里的组，问 read 也允许
	testing.expect(t, session_login_test_permission(&login, "read", "luci-write"))

	// 取反优先：write 列表里的 `!luci-base` 即使 read 列表有它，问 write 也被拒
	testing.expect(t, !session_login_test_permission(&login, "write", "luci-base"))
}

@(test)
test_session_load_acls_from_fixtures :: proc(t: ^testing.T) {
	alloc, ar := mk_arena()
	defer drop_arena(ar)

	// 只授 read 的 luci-base：表的 ubus 形态、数组的 uci 形态都该生效
	// （options 分配在本用例的 arena 上，函数尾 drop_arena 一起回收）
	login := acl_test_login([]string{"luci-base"}, []string{}, alloc)

	ses := new(Session, session_store_allocator())
	ses.id = "test-acl-session"
	ses.data = make(map[string]string, 0, session_store_allocator())
	ses.acls = make(map[string][dynamic]Acl_Entry, 0, session_store_allocator())
	session_load_acls(ses, &login, session_store_allocator())

	// 表形态：ubus.uci 的 read 函数
	testing.expect(t, session_acl_allowed(ses, "ubus", "uci", "changes"))
	testing.expect(t, session_acl_allowed(ses, "ubus", "uci", "get"))
	// 数组形态：scope "uci" 的对象列表 + 函数名=权限名
	testing.expect(t, session_acl_allowed(ses, "uci", "system", "read"))
	// 数组形态的顶层 scope（cgi-io 在 write 里，本次没授 write）
	testing.expect(t, !session_acl_allowed(ses, "ubus", "uci", "set"))
	testing.expect(t, !session_acl_allowed(ses, "cgi-io", "upload", "write"))
	// 元 scope：access-group
	testing.expect(t, session_acl_allowed(ses, "access-group", "luci-base", "read"))
	testing.expect(t, !session_acl_allowed(ses, "access-group", "luci-base", "write"))
	// 未授的组一个条目都没有
	testing.expect(t, !session_acl_allowed(ses, "ubus", "session", "login"))

	// 授 write：write 条目与 cgi-io 数组形态都生效
	login2 := acl_test_login([]string{}, []string{"luci-base"}, alloc)
	ses2 := new(Session, session_store_allocator())
	ses2.id = "test-acl-session-2"
	ses2.data = make(map[string]string, 0, session_store_allocator())
	ses2.acls = make(map[string][dynamic]Acl_Entry, 0, session_store_allocator())
	session_load_acls(ses2, &login2, session_store_allocator())
	testing.expect(t, session_acl_allowed(ses2, "ubus", "uci", "set"))
	testing.expect(t, session_acl_allowed(ses2, "cgi-io", "upload", "write"))
	// 只授 write 时，read 表**也会**被加载：rpc_login_test_permission 对 read 查询
	// 会递归问 write（write 蕴含 read，session.c:973-975）
	testing.expect(t, session_acl_allowed(ses2, "ubus", "uci", "changes"))
	testing.expect(t, session_acl_allowed(ses2, "access-group", "luci-base", "read"))
}

@(test)
test_session_default_session_acls :: proc(t: ^testing.T) {
	// 哨兵会话只加载 unauthenticated 组（session.c:1385）
	session_ensure_default()
	ses := session_get(SESSION_DEFAULT_ID)
	testing.expect(t, ses != nil)
	if ses != nil {
		testing.expect(t, session_acl_allowed(ses, "ubus", "session", "access"))
		testing.expect(t, session_acl_allowed(ses, "ubus", "session", "login"))
		testing.expect(t, !session_acl_allowed(ses, "ubus", "uci", "get"))
		testing.expect(t, session_acl_allowed(ses, "access-group", "unauthenticated", "read"))
	}
}
