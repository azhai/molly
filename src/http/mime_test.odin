package http

import "core:testing"

// 单元测试：扩展名 → Content-Type。期望值**逐条来自原厂 uhttpd 的真机实测**
// （2026-10-07 真机量了 36 个扩展名，取样脚本见 .ai-memory/go-port-plan.md 同日条目）。
// 三条要点：uhttpd 不带 charset、`.js` 是 `text/javascript`、表外一律 `application/octet-stream`。
//
// 运行：odin test -collection:molly=src src/http

@(test)
test_content_type_for :: proc(t: ^testing.T) {
	Cases :: struct {
		path, want: string,
	}
	cases := []Cases{
		{"/index.html", "text/html"}, // 不带 charset
		{"/a/b.HTM", "text/html"}, // 扩展名不区分大小写
		{"/luci-static/test.css", "text/css"},
		{"/app.js", "text/javascript"}, // 不是 application/javascript
		{"/m.json", "application/json"},
		{"/note.txt", "text/plain"},
		{"/f.conf", "text/plain"}, // 与 .log 同类
		{"/d.xml", "application/xml"},
		{"/logo.svg", "image/svg+xml"},
		{"/icon.ico", "application/octet-stream"}, // uhttpd 表外
		{"/f.woff2", "application/octet-stream"}, // 同上（字体也是）
		{"/m.mjs", "application/octet-stream"}, // 同上
		{"/m.map", "application/octet-stream"}, // 同上
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
