package handlers

// auth_test —— auth 面「决策」的 host 单测（对齐 static/ubus 的可测切分：只测纯函数与
// 无套接字的粘合，不驱动 Serve_Auth 的 I/O）。
// 覆盖：路径归属、sid 白名单收窄、跳转目标（含开放重定向拦截）、错误跳转的分隔符、
// 表单取值/首个非空、会话 cookie 串的构造与解析、登录参数 JSON 的正确转义。
// 改密的真机分支（openssl + /etc/shadow）在 darwin 上是桩（恒 no_hasher），其成功路径留给阶段5 smoke。

import "core:testing"
import "core:mem"
import "core:strings"
import "core:encoding/json"
import "molly:http"

@(test)
test_auth_paths :: proc(t: ^testing.T) {
	backing: [262144]u8
	ar: mem.Arena
	mem.arena_init(&ar, backing[:])
	context.allocator = mem.arena_allocator(&ar)

	testing.expect_value(t, Auth_Paths("/auth"), true)
	testing.expect_value(t, Auth_Paths("/auth/"), true)
	testing.expect_value(t, Auth_Paths("/auth/login"), true)
	testing.expect_value(t, Auth_Paths("/auth/logout"), true)
	testing.expect_value(t, Auth_Paths("/auth/password"), true)
	// 边界前缀：不能把 /auth.html / /author / /ubus 也算进来。
	testing.expect_value(t, Auth_Paths("/auth.html"), false)
	testing.expect_value(t, Auth_Paths("/author"), false)
	testing.expect_value(t, Auth_Paths("/ubus"), false)
	testing.expect_value(t, Auth_Paths("/"), false)
}

@(test)
test_auth_sanitize_sid :: proc(t: ^testing.T) {
	backing: [262144]u8
	ar: mem.Arena
	mem.arena_init(&ar, backing[:])
	context.allocator = mem.arena_allocator(&ar)

	sid32 := "a1b2c3d4e5f60718293a4b5c6d7e8f90"
	testing.expect_value(t, sanitize_sid(sid32), sid32)

	// 只截前 32 位（合法形态就是 32 hex）：32 之后的字符（哪怕也合法）被丢弃。
	longer := build([]string{sid32, "ffeeddccbbaa9876"})
	testing.expect_value(t, sanitize_sid(longer), sid32)

	// 非 hex 字符：整串丢弃（不做「截断到第一个非法字符」的猜测）。
	testing.expect_value(t, sanitize_sid("ab<cd"), "")
	testing.expect_value(t, sanitize_sid("abcdefg"), "") // 'g' 不是 hex
	testing.expect_value(t, sanitize_sid(""), "")

	// 短串原样返回（长度不强制到 32）。
	testing.expect_value(t, sanitize_sid("abc"), "abc")
}

@(test)
test_auth_next_and_error_redirect :: proc(t: ^testing.T) {
	backing: [262144]u8
	ar: mem.Arena
	mem.arena_init(&ar, backing[:])
	context.allocator = mem.arena_allocator(&ar)

	// 缺省 / 非法 next → "/"。
	testing.expect_value(t, auth_next(nil), "/")
	testing.expect_value(t, auth_next([]http.KV{{"next", "//evil.com"}}), "/") // 协议相对 → 挡掉
	testing.expect_value(t, auth_next([]http.KV{{"next", "http://evil.com"}}), "/") // 非绝对路径 → 挡掉
	testing.expect_value(t, auth_next([]http.KV{{"next", " /path "}}), "/path") // 去空白

	// 错误跳转：next 无 '?' 用 '?'，已含 '?' 用 '&'。
	testing.expect_value(t,
		auth_error_redirect(nil, "bad_request"), "/?auth_error=bad_request")
	testing.expect_value(t,
		auth_error_redirect([]http.KV{{"next", "/x"}}, "bad_credentials"),
		"/x?auth_error=bad_credentials")
	testing.expect_value(t,
		auth_error_redirect([]http.KV{{"next", "/x?a=1"}}, "weak_password"),
		"/x?a=1&auth_error=weak_password")
}

@(test)
test_auth_form_and_first_non_empty :: proc(t: ^testing.T) {
	backing: [262144]u8
	ar: mem.Arena
	mem.arena_init(&ar, backing[:])
	context.allocator = mem.arena_allocator(&ar)

	// first_non_empty：兼容 username/luci_username 两套字段名。
	testing.expect_value(t, first_non_empty([]string{"", "", "x"}), "x")
	testing.expect_value(t, first_non_empty([]string{"", ""}), "")

	// form_value：取同名键的首个值；缺失回空串。
	form := []http.KV{{"password", "p1"}, {"password", "p2"}, {"username", "root"}}
	testing.expect_value(t, form_value(form, "password"), "p1")
	testing.expect_value(t, form_value(form, "username"), "root")
	testing.expect_value(t, form_value(form, "next"), "")
}

@(test)
test_auth_cookie_build_and_parse :: proc(t: ^testing.T) {
	backing: [262144]u8
	ar: mem.Arena
	mem.arena_init(&ar, backing[:])
	context.allocator = mem.arena_allocator(&ar)

	sid32 := "a1b2c3d4e5f60718293a4b5c6d7e8f90"

	// 下发串：Path=/ + HttpOnly + SameSite=Strict。
	ck := build_session_cookie(sid32, false)
	testing.expect_value(t, ck, "sysauth_molly=a1b2c3d4e5f60718293a4b5c6d7e8f90; Path=/; HttpOnly; SameSite=Strict")

	// 清除串：空值 + Max-Age=-1。
	clr := build_session_cookie("", true)
	testing.expect_value(t, clr, "sysauth_molly=; Path=/; HttpOnly; SameSite=Strict; Max-Age=-1")

	// 解析：molly 专属名优先于上游两个名。
	req := http.Request{}
	append(&req.headers, http.Header{"Cookie", build([]string{"sysauth_https=ffff; ", session_cookie_name, "=", sid32})})
	testing.expect_value(t, sid_from_cookie(&req), sid32)

	// 只认上游 sysauth_http。
	req2 := http.Request{}
	append(&req2.headers, http.Header{"Cookie", "sysauth_http=00112233"})
	testing.expect_value(t, sid_from_cookie(&req2), "00112233")

	// 无 cookie 头 → 空。
	req3 := http.Request{}
	testing.expect_value(t, sid_from_cookie(&req3), "")
}

@(test)
test_auth_login_params_json :: proc(t: ^testing.T) {
	backing: [262144]u8
	ar: mem.Arena
	mem.arena_init(&ar, backing[:])
	context.allocator = mem.arena_allocator(&ar)

	// 键按升序（sort_maps_by_key）：password 在 username 前。
	out := login_params("alice", "secret")
	testing.expect_value(t, out, `{"password":"secret","username":"alice"}`)

	// 引号必须被 JSON 转义：口令/用户名是自由文本，用回环解析验证转义正确（不靠手写转义串）。
	out2 := login_params(`a"b`, "c\\d")
	v, err := json.parse_string(out2, .JSON, true, context.allocator)
	testing.expect_value(t, err, nil)
	o, is_obj := v.(json.Object)
	testing.expect_value(t, is_obj, true)
	got, _ := as_str(o["username"])
	testing.expect_value(t, got, `a"b`)
	gotp, _ := as_str(o["password"])
	testing.expect_value(t, gotp, "c\\d")
}
