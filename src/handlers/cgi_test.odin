package handlers

// cgi_test —— build_cgi_env / parse_cgi_response / cgi_script_name / 小工具的 host 单测
// （对齐 internal/handlers/cgi_test.go）。纯字符串决策，不 fork 子进程、不碰套接字。

import "core:testing"
import "core:mem"
import "core:strings"
import "molly:http"
import "molly:backend"

// make_req —— 造一个只填 cgi 用得着字段的最小 Request（headers/body 落 context.allocator）。
make_req :: proc(method, target, content_type, cookie, host: string) -> http.Request {
	r: http.Request
	r.method = method
	r.target = target
	r.version = "1.1"
	r.query = nil
	append(&r.headers, http.Header{"Host", host})
	if content_type != "" {
		append(&r.headers, http.Header{"Content-Type", content_type})
	}
	if cookie != "" {
		append(&r.headers, http.Header{"Cookie", cookie})
	}
	append(&r.headers, http.Header{"X-Test", "abc"})
	return r
}

// env_value —— 从 "K=V" 列表取 K 的值；不存在回 "\x00不存在"（对齐 Go 的 envValue）。
env_value :: proc(env: []string, key: string) -> string {
	pfx := build([]string{key, "="})
	for e in env {
		if strings.has_prefix(e, pfx) {
			return e[len(pfx):]
		}
	}
	return "\x00不存在"
}

env_count :: proc(env: []string, key: string) -> int {
	pfx := build([]string{key, "="})
	n := 0
	for e in env {
		if strings.has_prefix(e, pfx) {
			n += 1
		}
	}
	return n
}

@(test)
test_build_cgi_env_full :: proc(t: ^testing.T) {
	backing: [262144]u8
	ar: mem.Arena
	mem.arena_init(&ar, backing[:])
	context.allocator = mem.arena_allocator(&ar)

	req := make_req("POST", "/cgi-bin/luci/admin/status/overview?v=1&x=2", "application/json", "", "router.lan")
	req.body = []u8{'h', 'e', 'l', 'l', 'o'}
	env := build_cgi_env(&req, "/admin/status/overview", "tests/fixtures/www", "/tmp/molly-ubus.sock", "/cgi-bin/luci", "")
	defer delete(env)

	cases := [][2]string{
		{"GATEWAY_INTERFACE", "CGI/1.1"},
		{"SERVER_SOFTWARE", "molly"},
		{"SERVER_PROTOCOL", "HTTP/1.1"},
		{"REQUEST_METHOD", "POST"},
		{"REQUEST_URI", "/cgi-bin/luci/admin/status/overview?v=1&x=2"},
		{"SCRIPT_NAME", "/cgi-bin/luci"},
		{"PATH_INFO", "/admin/status/overview"},
		{"QUERY_STRING", "v=1&x=2"},
		{"DOCUMENT_ROOT", "tests/fixtures/www"},
		{"REMOTE_ADDR", ""},
		{"CONTENT_LENGTH", "5"},
		{"CONTENT_TYPE", "application/json"},
		{"HTTP_X_TEST", "abc"},
		{"HTTP_HOST", "router.lan"},
		{"MOLLY_UBUS_SOCKET", "/tmp/molly-ubus.sock"},
	}
	for kv in cases {
		testing.expect_value(t, env_value(env[:], kv[0]), kv[1])
	}
	// 特例头不做成 HTTP_*
	testing.expect_value(t, env_value(env[:], "HTTP_CONTENT_TYPE"), "\x00不存在")
	testing.expect_value(t, env_value(env[:], "HTTP_CONTENT_LENGTH"), "\x00不存在")
}

@(test)
test_build_cgi_env_renames_session_cookie :: proc(t: ^testing.T) {
	backing: [262144]u8
	ar: mem.Arena
	mem.arena_init(&ar, backing[:])
	context.allocator = mem.arena_allocator(&ar)

	sid := "0123456789abcdef0123456789abcdef"
	req := make_req("GET", "/admin/system/package-manager", "", build([]string{"sysauth_molly=", sid}), "")
	env := build_cgi_env(&req, "/admin/system/package-manager", "/www", "", "/admin", "/admin")
	defer delete(env)
	got := env_value(env[:], "HTTP_COOKIE")
	want_names := []string{build([]string{"sysauth_molly=", sid}), build([]string{"sysauth_http=", sid}), build([]string{"sysauth_https=", sid})}
	for want in want_names {
		testing.expect_value(t, strings.contains(got, want), true)
	}
	testing.expect_value(t, env_count(env[:], "HTTP_COOKIE"), 1)
}

@(test)
test_build_cgi_env_anonymous_no_cookie :: proc(t: ^testing.T) {
	backing: [262144]u8
	ar: mem.Arena
	mem.arena_init(&ar, backing[:])
	context.allocator = mem.arena_allocator(&ar)

	req := make_req("GET", "/admin/status/overview", "", "", "")
	env := build_cgi_env(&req, "/admin/status/overview", "/www", "", "/admin", "/admin")
	defer delete(env)
	testing.expect_value(t, env_value(env[:], "HTTP_COOKIE"), "\x00不存在")
}

@(test)
test_build_cgi_env_bare_prefix :: proc(t: ^testing.T) {
	backing: [262144]u8
	ar: mem.Arena
	mem.arena_init(&ar, backing[:])
	context.allocator = mem.arena_allocator(&ar)

	req := make_req("GET", "/cgi-bin/luci", "", "", "")
	env := build_cgi_env(&req, "", "/www", "", "/cgi-bin/luci", "")
	defer delete(env)
	testing.expect_value(t, env_value(env[:], "PATH_INFO"), "")
	testing.expect_value(t, env_value(env[:], "CONTENT_LENGTH"), "0")
	testing.expect_value(t, env_value(env[:], "MOLLY_UBUS_SOCKET"), "\x00不存在")
}

@(test)
test_cgi_script_name :: proc(t: ^testing.T) {
	// strip 空 → 等于 prefix；strip 收尾 → 去掉尾段（/admin 去 admin → ""）。
	testing.expect_value(t, cgi_script_name("/cgi-bin/luci", ""), "/cgi-bin/luci")
	testing.expect_value(t, cgi_script_name("/admin", "/admin"), "")
	testing.expect_value(t, cgi_script_name("/admin", "/admin/status"), "/admin") // 不匹配原样返回
}

@(test)
test_parse_cgi_response :: proc(t: ^testing.T) {
	backing: [262144]u8
	ar: mem.Arena
	mem.arena_init(&ar, backing[:])
	context.allocator = mem.arena_allocator(&ar)

	resp, ok := parse_cgi_response("Content-Type: text/plain\r\nStatus: 302 Found\r\nLocation: /x\r\n\r\nbody")
	testing.expect_value(t, ok, true)
	testing.expect_value(t, resp.code, 302)
	testing.expect_value(t, resp.reason, "Found")
	testing.expect_value(t, resp.content_type, "text/plain")
	testing.expect_value(t, resp.body, "body")
	testing.expect_value(t, len(resp.extra), 1)
	if len(resp.extra) == 1 {
		testing.expect_value(t, resp.extra[0].name, "Location")
		testing.expect_value(t, resp.extra[0].value, "/x")
	}

	resp2, ok2 := parse_cgi_response("Content-Type: text/html\n\nhi")
	testing.expect_value(t, ok2, true)
	testing.expect_value(t, resp2.body, "hi")
	testing.expect_value(t, resp2.code, 200)

	resp3, ok3 := parse_cgi_response("HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\n\r\nx")
	testing.expect_value(t, ok3, true)
	testing.expect_value(t, resp3.code, 404)

	resp4, ok4 := parse_cgi_response("Status: 403\r\nContent-Type: text/plain\r\n\r\n")
	testing.expect_value(t, ok4, true)
	testing.expect_value(t, resp4.reason, "Forbidden")

	_, ok5 := parse_cgi_response("Status: 200 OK\r\n\r\nx")
	testing.expect_value(t, ok5, false) // 缺 Content-Type

	_, ok6 := parse_cgi_response("Content-Type: text/plain")
	testing.expect_value(t, ok6, false) // 没有空行分隔

	resp7, ok7 := parse_cgi_response("Content-Type: text/plain\r\nContent-Length: 999\r\nConnection: close\r\n\r\n")
	testing.expect_value(t, ok7, true)
	testing.expect_value(t, len(resp7.extra), 0)
}

@(test)
test_cgi_helpers :: proc(t: ^testing.T) {
	backing: [262144]u8
	ar: mem.Arena
	mem.arena_init(&ar, backing[:])
	context.allocator = mem.arena_allocator(&ar)

	testing.expect_value(t, header_env_name("X-Forwarded-For"), "X_FORWARDED_FOR")
	methods := []string{"GET", "HEAD", "POST", "PUT", "DELETE", "OPTIONS"}
	for m in methods {
		testing.expect_value(t, cgi_method_string(m), m)
	}
	testing.expect_value(t, cgi_method_string("FROB"), "UNKNOWN")

	// widen_session_cookie_path：会话 cookie 放宽 path=/，其它原样。
	testing.expect_value(t, widen_session_cookie_path("sysauth_http=abc; Path=/admin/; HttpOnly"), "sysauth_http=abc; Path=/; HttpOnly")
	testing.expect_value(t, widen_session_cookie_path("theme=dark; Path=/x"), "theme=dark; Path=/x")

	testing.expect_value(t, remote_host("127.0.0.1:5555"), "127.0.0.1")
	testing.expect_value(t, remote_host("[::1]:8080"), "::1")
	testing.expect_value(t, remote_host("127.0.0.1"), "127.0.0.1")
}

@(test)
test_split_command :: proc(t: ^testing.T) {
	backing: [262144]u8
	ar: mem.Arena
	mem.arena_init(&ar, backing[:])
	context.allocator = mem.arena_allocator(&ar)

	// 单命令、多段、连续/前后分隔符、纯空白（→ 空）。
	one := split_command("/www/cgi-bin/luci")
	testing.expect_value(t, len(one), 1)
	testing.expect_value(t, one[0], "/www/cgi-bin/luci")

	many := split_command("ucode  -t\ta.uc  x")
	want := []string{"ucode", "-t", "a.uc", "x"}
	testing.expect_value(t, len(many), len(want))
	for w, i in want {
		testing.expect_value(t, many[i], w)
	}

	empty := split_command("   \t ")
	testing.expect_value(t, len(empty), 0)
}

@(test)
test_cgi_exit_desc :: proc(t: ^testing.T) {
	backing: [262144]u8
	ar: mem.Arena
	mem.arena_init(&ar, backing[:])
	context.allocator = mem.arena_allocator(&ar)

	// 子进程正常退出（含非零码）→ "exit N"；broken.sh 就是 exit 3。
	st := backend.Spawn_Result{started = true, exited = true, code = 3}
	testing.expect_value(t, exit_desc(st), "exit 3")
	// 没跑起来（启动失败，started=false）→ "spawn failed"。
	zero: backend.Spawn_Result
	testing.expect_value(t, exit_desc(zero), "spawn failed")
}
