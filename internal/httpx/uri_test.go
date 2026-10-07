package httpx

import "testing"

// 用例逐条对应 Odin 版 src/http/uri_test.odin 的断言意图，保证两版语义不漂移。
func TestNormalizePath(t *testing.T) {
	cases := []struct {
		name string
		raw  string
		want string
		// wantState 为 0 时表示期望 URIOk
		bad      bool
		escaping bool
	}{
		{name: "根路径", raw: "/", want: "/"},
		{name: "普通路径", raw: "/luci-static/x.css", want: "/luci-static/x.css"},
		{name: "剥查询串", raw: "/luci-static/x.css?v=1", want: "/luci-static/x.css"},
		{name: "剥片段", raw: "/a/b#frag", want: "/a/b"},
		{name: "百分号解码", raw: "/a%20b/c", want: "/a b/c"},
		{name: "大写十六进制", raw: "/a%2Fb", want: "/a/b"},
		{name: "重复斜杠压掉", raw: "/a//b///c", want: "/a/b/c"},
		{name: "点段丢弃", raw: "/a/./b", want: "/a/b"},
		{name: "尾部斜杠保留语义", raw: "/a/b/", want: "/a/b"},
		{name: "编码的点不逃逸", raw: "/a/%2e%2e/b", escaping: true},
		{name: "裸点点逃逸", raw: "/a/../b", escaping: true},
		{name: "开头逃逸", raw: "/../etc/passwd", escaping: true},
		{name: "百分号截断", raw: "/a%2", bad: true},
		{name: "百分号非十六进制", raw: "/a%zz", bad: true},
		{name: "NUL 拒绝", raw: "/a%00b", bad: true},
		{name: "控制字符拒绝", raw: "/a%1fb", bad: true},
		{name: "不以斜杠开头", raw: "a/b", bad: true},
		{name: "空目标", raw: "", bad: true},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, state := NormalizePath(tc.raw)
			switch {
			case tc.bad:
				if state != URIBad {
					t.Fatalf("NormalizePath(%q) 状态 = %v，期望 URIBad", tc.raw, state)
				}
			case tc.escaping:
				if state != URIEscaping {
					t.Fatalf("NormalizePath(%q) 状态 = %v，期望 URIEscaping", tc.raw, state)
				}
			default:
				if state != URIOk {
					t.Fatalf("NormalizePath(%q) 状态 = %v，期望 URIOk", tc.raw, state)
				}
				if got != tc.want {
					t.Fatalf("NormalizePath(%q) = %q，期望 %q", tc.raw, got, tc.want)
				}
			}
		})
	}
}

func TestContentTypeFor(t *testing.T) {
	cases := map[string]string{
		"/a/index.html": "text/html", // 不带 charset
		"/a/x.HTM":      "text/html",
		"/a/x.css":      "text/css",
		"/a/x.js":       "text/javascript",          // 不是 application/javascript
		"/a/x.mjs":      "application/octet-stream", // uhttpd 表外
		"/a/x.woff2":    "application/octet-stream", // 同上（字体也是）
		"/a/x.ico":      "application/octet-stream", // 同上
		"/a/x.svg":      "image/svg+xml",
		"/a/x.xml":      "application/xml",
		"/a.b/c":        "application/octet-stream", // 不跨 '/'
		"/a/x.unknown":  "application/octet-stream",
		"/a/x.":         "application/octet-stream",
		"/a/noext":      "application/octet-stream",
		"/a/x.jpg":      "image/jpeg",
		"/a/x.JSON":     "application/json",
	}
	for path, want := range cases {
		if got := ContentTypeFor(path); got != want {
			t.Errorf("ContentTypeFor(%q) = %q，期望 %q", path, got, want)
		}
	}
}
