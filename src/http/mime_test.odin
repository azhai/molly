package http

import "core:testing"

// 单元测试：扩展名 → Content-Type（上游对应 uhttpd 的 mimetypes 表；逐条校准待真机，风险 R7）。
//
// 运行：odin test -collection:molly=src src/http

@(test)
test_content_type_for :: proc(t: ^testing.T) {
	Cases :: struct {
		path, want: string,
	}
	cases := []Cases{
		{"/index.html", "text/html; charset=utf-8"},
		{"/a/b.HTM", "text/html; charset=utf-8"}, // 扩展名不区分大小写
		{"/luci-static/test.css", "text/css; charset=utf-8"},
		{"/app.js", "application/javascript; charset=utf-8"},
		{"/m.json", "application/json; charset=utf-8"},
		{"/note.txt", "text/plain; charset=utf-8"},
		{"/logo.svg", "image/svg+xml"},
		{"/icon.ico", "image/x-icon"},
		{"/f.woff2", "font/woff2"},
		{"/noext", "application/octet-stream"}, // 没有扩展名
		{"/a.b/c", "application/octet-stream"}, // 不跨 '/'
		{"/trailing.", "application/octet-stream"}, // "." 结尾没有扩展名
		{"/weird.xyz", "application/octet-stream"}, // 未收录的扩展名不猜 text/plain
	}
	for c in cases {
		got := content_type_for(c.path)
		testing.expectf(t, got == c.want, "%q 应为 %q，实际 %q", c.path, c.want, got)
	}
}
