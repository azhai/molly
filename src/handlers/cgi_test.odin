package handlers

import "core:mem"
import "core:testing"

import "molly:http"

// 单元测试：CGI 桥接的两个纯函数（环境构造、响应解析）。
//
// 运行：odin test -collection:molly=src src/handlers   （或 ./tests/unit.sh）
//
// 为什么这两个函数值得单测：它们是「CGI 规范 ↔ molly 内部表示」的全部翻译逻辑，
// 出错不会崩、只会静默给出错误的 URL/权限判定（上游 ucode 靠这些变量决定路由与鉴权）。

@(private)
mk_arena :: proc() -> (mem.Allocator, ^mem.Dynamic_Arena) {
	a := new(mem.Dynamic_Arena) // 零初始化
	mem.dynamic_arena_init(a)
	return mem.dynamic_arena_allocator(a), a
}

@(private)
drop_arena :: proc(a: ^mem.Dynamic_Arena) {
	mem.dynamic_arena_destroy(a)
	free(a)
}

@(private)
env_get :: proc(env: []string, key: string) -> string {
	for e in env {
		if i := index_byte_str(e, '='); i > 0 && e[:i] == key {
			return e[i + 1:]
		}
	}
	return ""
}

@(private)
index_byte_str :: proc(s: string, c: byte) -> int {
	for i := 0; i < len(s); i += 1 {
		if s[i] == c {
			return i
		}
	}
	return -1
}

@(private)
sample_request :: proc() -> http.Request {
	req := http.Request {
		method = .Post,
		target = "/cgi-bin/luci/admin/status/overview?v=1&x=2",
		minor  = 1,
	}
	// transmute 只能作用在已定型表达式上：先落到局部变量再转
	body := "hello"
	req.body = transmute([]byte)(body)
	req.headers[0] = {name = "X-Test", value = "abc"}
	req.headers[1] = {name = "Content-Type", value = "application/json"}
	req.headers[2] = {name = "Content-Length", value = "5"}
	req.headers[3] = {name = "Connection", value = "keep-alive"}
	req.n_heads = 4
	return req
}

@(test)
test_build_cgi_env :: proc(t: ^testing.T) {
	alloc, ar := mk_arena()
	defer drop_arena(ar)

	req := sample_request()
	env, ok := build_cgi_env(&req, "/cgi-bin/luci/admin/status/overview", "127.0.0.1", "/www", alloc)
	testing.expect(t, ok)

	testing.expect_value(t, env_get(env[:], "REQUEST_METHOD"), "POST")
	testing.expect_value(t, env_get(env[:], "SCRIPT_NAME"), "/cgi-bin/luci")
	testing.expect_value(t, env_get(env[:], "PATH_INFO"), "/admin/status/overview")
	testing.expect_value(t, env_get(env[:], "QUERY_STRING"), "v=1&x=2")
	testing.expect_value(t, env_get(env[:], "REQUEST_URI"), "/cgi-bin/luci/admin/status/overview?v=1&x=2")
	testing.expect_value(t, env_get(env[:], "SERVER_PROTOCOL"), "HTTP/1.1")
	testing.expect_value(t, env_get(env[:], "GATEWAY_INTERFACE"), "CGI/1.1")
	testing.expect_value(t, env_get(env[:], "DOCUMENT_ROOT"), "/www")
	testing.expect_value(t, env_get(env[:], "REMOTE_ADDR"), "127.0.0.1")
	testing.expect_value(t, env_get(env[:], "CONTENT_LENGTH"), "5")
	testing.expect_value(t, env_get(env[:], "CONTENT_TYPE"), "application/json")
	testing.expect_value(t, env_get(env[:], "HTTP_X_TEST"), "abc")

	// Content-Type / Content-Length / Connection 不能走 HTTP_* 通道（CGI 规范）
	testing.expect_value(t, env_get(env[:], "HTTP_CONTENT_TYPE"), "")
	testing.expect_value(t, env_get(env[:], "HTTP_CONTENT_LENGTH"), "")
	testing.expect_value(t, env_get(env[:], "HTTP_CONNECTION"), "")
}

@(test)
test_build_cgi_env_edge_cases :: proc(t: ^testing.T) {
	alloc, ar := mk_arena()
	defer drop_arena(ar)

	// 裸前缀：PATH_INFO 为空、QUERY_STRING 为空、GET 的 CONTENT_LENGTH 是 0
	req := http.Request{method = .Get, target = "/cgi-bin/luci", minor = 0}
	env, _ := build_cgi_env(&req, "/cgi-bin/luci", "10.0.0.9", "/www", alloc)
	testing.expect_value(t, env_get(env[:], "PATH_INFO"), "")
	testing.expect_value(t, env_get(env[:], "QUERY_STRING"), "")
	testing.expect_value(t, env_get(env[:], "CONTENT_LENGTH"), "0")
	testing.expect_value(t, env_get(env[:], "SERVER_PROTOCOL"), "HTTP/1.0")
	testing.expect_value(t, env_get(env[:], "REQUEST_METHOD"), "GET")

	// 认不出的方法（上游会当 405/501 处理，这里至少不能丢信息）
	req2 := http.Request{method = .Other, target = "/cgi-bin/luci/x", minor = 1}
	env2, _ := build_cgi_env(&req2, "/cgi-bin/luci/x", "127.0.0.1", "/www", alloc)
	testing.expect_value(t, env_get(env2[:], "REQUEST_METHOD"), "UNKNOWN")
	testing.expect_value(t, env_get(env2[:], "PATH_INFO"), "/x")

	// 头名规范化：X-Forwarded-For → HTTP_X_FORWARDED_FOR
	req3 := http.Request{method = .Get, target = "/cgi-bin/luci", minor = 1}
	req3.headers[0] = {name = "X-Forwarded-For", value = "1.2.3.4"}
	req3.n_heads = 1
	env3, _ := build_cgi_env(&req3, "/cgi-bin/luci", "127.0.0.1", "/www", alloc)
	testing.expect_value(t, env_get(env3[:], "HTTP_X_FORWARDED_FOR"), "1.2.3.4")
}

@(test)
test_parse_cgi_response :: proc(t: ^testing.T) {
	alloc, ar := mk_arena()
	defer drop_arena(ar)

	// 常规：Content-Type + body
	resp, ok := parse_cgi_response("Content-Type: text/plain\r\n\r\nhello", alloc)
	testing.expect(t, ok)
	testing.expect_value(t, resp.code, 200)
	testing.expect_value(t, resp.reason, "OK")
	testing.expect_value(t, resp.content_type, "text/plain")
	testing.expect_value(t, resp.body, "hello")

	// Status + 额外头透传；Content-Length / Connection 被丢掉
	raw := "Status: 302 Found\r\nContent-Type: text/html\r\nLocation: /cgi-bin/luci/\r\n" +
	       "Set-Cookie: sysauth=x; path=/\r\nContent-Length: 999\r\nConnection: close\r\n\r\n<p>go</p>"
	resp2, ok2 := parse_cgi_response(raw, alloc)
	testing.expect(t, ok2)
	testing.expect_value(t, resp2.code, 302)
	testing.expect_value(t, resp2.reason, "Found")
	testing.expect_value(t, resp2.body, "<p>go</p>")

	found_location, found_cookie, found_len := false, false, false
	for h in resp2.extra {
		switch {
		case h.name == "Location" && h.value == "/cgi-bin/luci/":
			found_location = true
		case h.name == "Set-Cookie":
			found_cookie = true
		case ascii_eq(h.name, "Content-Length"), ascii_eq(h.name, "Connection"):
			found_len = true
		}
	}
	testing.expect(t, found_location)
	testing.expect(t, found_cookie)
	testing.expect(t, !found_len)

	// Status 只有码没有短语时补默认短语
	resp3, _ := parse_cgi_response("Status: 404\r\nContent-Type: text/plain\r\n\r\nx", alloc)
	testing.expect_value(t, resp3.code, 404)
	testing.expect_value(t, resp3.reason, "Not Found")

	// LF LF 分隔也认（桩程序与手写脚本常用）
	resp4, ok4 := parse_cgi_response("Content-Type: text/plain\n\nbody", alloc)
	testing.expect(t, ok4)
	testing.expect_value(t, resp4.body, "body")

	// 非标准的 "HTTP/1.1 200 OK" 起始行也认
	resp5, ok5 := parse_cgi_response("HTTP/1.1 201 Created\r\nContent-Type: text/plain\r\n\r\nx", alloc)
	testing.expect(t, ok5)
	testing.expect_value(t, resp5.code, 201)

	// 缺 Content-Type → 脚本错误
	_, ok6 := parse_cgi_response("X-Only: 1\r\n\r\nbody", alloc)
	testing.expect(t, !ok6)

	// 完全没有头块 → 脚本错误
	_, ok7 := parse_cgi_response("no header block at all", alloc)
	testing.expect(t, !ok7)
}

@(test)
test_split_command :: proc(t: ^testing.T) {
	alloc, ar := mk_arena()
	defer drop_arena(ar)

	// 多空白、两端空白：按空白切分（命令里带参数时用）
	// 注意这里只是**切分**的样本，别把它当成设备上的推荐取值——设备上应填 `/www/cgi-bin/luci`
	// （见 cgi_exec.odin 头部与 docs/interfaces.md §5.5；uhttpd.uc 是模板，不能当脚本跑）
	argv := split_command("  /usr/bin/ucode   -L   /usr/share/ucode  ", alloc)
	testing.expect_value(t, len(argv), 3)
	testing.expect_value(t, argv[0], "/usr/bin/ucode")
	testing.expect_value(t, argv[1], "-L")
	testing.expect_value(t, argv[2], "/usr/share/ucode")

	testing.expect_value(t, len(split_command("   ", alloc)), 0)
	testing.expect_value(t, len(split_command("", alloc)), 0)
}
