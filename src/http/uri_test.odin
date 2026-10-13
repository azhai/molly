package http

// src/http 的纯函数单测 —— 逐条移植 internal/httpx/uri_test.go 的断言，锁死语义不漂移。
// 跑法（host）：odin test src/http
// dev-2026-10 的发现机制：带 @(test) 属性、签名 proc(t: ^testing.T) 的过程才会被注册。

import "core:testing"
import "core:mem"

@(test)
test_normalize_path :: proc(t: ^testing.T) {
	// 生产里 Normalize_Path 跑在每请求 arena 上；测试用同样的 arena 包一层，避免裸分配泄漏。
	backing: [8192]u8
	ar: mem.Arena
	mem.arena_init(&ar, backing[:])
	old := context.allocator
	context.allocator = mem.arena_allocator(&ar)
	defer context.allocator = old

	Case :: struct {
		raw, want: string,
		bad, escaping: bool,
	}
	cases := []Case{
		{"/", "/", false, false},
		{"/luci-static/x.css", "/luci-static/x.css", false, false},
		{"/luci-static/x.css?v=1", "/luci-static/x.css", false, false},
		{"/a/b#frag", "/a/b", false, false},
		{"/a%20b/c", "/a b/c", false, false},
		{"/a%2Fb", "/a/b", false, false},
		{"/a//b///c", "/a/b/c", false, false},
		{"/a/./b", "/a/b", false, false},
		{"/a/b/", "/a/b", false, false},
		{"/a/%2e%2e/b", "", false, true},
		{"/a/../b", "", false, true},
		{"/../etc/passwd", "", false, true},
		{"/a%2", "", true, false},
		{"/a%zz", "", true, false},
		{"/a%00b", "", true, false},
		{"/a%1fb", "", true, false},
		{"a/b", "", true, false},
		{"", "", true, false},
	}
	for c in cases {
		got, state := Normalize_Path(c.raw)
		if c.bad {
			testing.expectf(t, state == .Bad, "NormalizePath(%s) 期望 URIBad", c.raw)
		} else if c.escaping {
			testing.expectf(t, state == .Escaping, "NormalizePath(%s) 期望 URIEscaping", c.raw)
		} else {
			testing.expectf(t, state == .Ok, "NormalizePath(%s) 期望 URIOk", c.raw)
			testing.expect_value(t, got, c.want)
		}
	}
}

@(test)
test_content_type_for :: proc(t: ^testing.T) {
	// 同上：Content_Type_For 内部 strings.to_lower 会分配，放 arena 里随作用域回收。
	backing: [4096]u8
	ar: mem.Arena
	mem.arena_init(&ar, backing[:])
	old := context.allocator
	context.allocator = mem.arena_allocator(&ar)
	defer context.allocator = old

	Case :: struct { path, want: string }
	cases := []Case{
		{"/a/index.html", "text/html"},        // 不带 charset
		{"/a/x.HTM", "text/html"},
		{"/a/x.css", "text/css"},
		{"/a/x.js", "text/javascript"},        // 不是 application/javascript
		{"/a/x.mjs", "application/octet-stream"},  // uhttpd 表外
		{"/a/x.woff2", "application/octet-stream"}, // 字体也表外
		{"/a/x.ico", "application/octet-stream"},    // 同上
		{"/a/x.svg", "image/svg+xml"},
		{"/a/x.xml", "application/xml"},
		{"/a.b/c", "application/octet-stream"}, // 不跨 '/'
		{"/a/x.unknown", "application/octet-stream"},
		{"/a/x.", "application/octet-stream"},
		{"/a/noext", "application/octet-stream"},
		{"/a/x.jpg", "image/jpeg"},
		{"/a/x.JSON", "application/json"},
	}
	for c in cases {
		testing.expect_value(t, Content_Type_For(c.path), c.want)
	}
}
