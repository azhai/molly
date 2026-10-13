package assets

// assets_test —— 菜单/配置注入的纯逻辑 + 内嵌资源完整性（host 单测）。

import "core:testing"
import "core:mem"
import "core:strings"

// 内联 arena：backing/ar 必须是每个 @(test) 过程的局部（不能用 helper 返回，
// 否则 arena 随 helper 栈帧失效 → 分配落在悬垂内存上）。跟 cgi_test/menu_test 同构。

@(test)
test_config_json_field_order :: proc(t: ^testing.T) {
	backing: [65536]u8
	ar: mem.Arena
	mem.arena_init(&ar, backing[:])
	context.allocator = mem.arena_allocator(&ar)
	cfg := Config{sid = "abc123", menu = Menu, expert = "/admin"}
	s := ConfigJSON(cfg)
	// 顶层字段序：sid,menu,expert（对齐 Go 结构体，非字母序）。
	testing.expectf(t, strings.has_prefix(s, `{"sid":"abc123","menu":[{"id":"dash","title":"仪表盘","ready":true}`),
		"head mismatch: %s", s)
	testing.expectf(t, strings.has_suffix(s, `"expert":"/admin"}`), "tail mismatch: %s", s)
	// 十个菜单项全就绪：ready:false 一次都不该出现（smoke 也钉这条）。
	testing.expect_value(t, strings.count(s, `"ready":false`), 0)
	testing.expect_value(t, strings.count(s, `"ready":true`), 10)
}

@(test)
test_quote_escapes_like_go :: proc(t: ^testing.T) {
	backing: [4096]u8
	ar: mem.Arena
	mem.arena_init(&ar, backing[:])
	context.allocator = mem.arena_allocator(&ar)
	// <>& 走 Go 的 HTML 安全转义；控制字符与引号反斜杠常规转义。
	testing.expect_value(t, quote("a<b>&c"), `"a\u003cb\u003e\u0026c"`)
	testing.expect_value(t, quote(`x"y\z`), `"x\"y\\z"`)
	// 中文原样（非 ASCII 不转 \u）。
	testing.expect_value(t, quote("仪表"), `"仪表"`)
}

@(test)
test_embedded_assets_present :: proc(t: ^testing.T) {
	backing: [4096]u8
	ar: mem.Arena
	mem.arena_init(&ar, backing[:])
	context.allocator = mem.arena_allocator(&ar)
	h := HTML()
	m := MITHRIL()
	// 字节数与源文件一致（生成器逐字节内嵌）。
	testing.expect_value(t, len(h), 92367)
	testing.expect_value(t, len(m), 24697)
	// 两个占位符都在 HTML 里，等 handler 替换。
	testing.expect(t, strings.contains(h, "__CFG__"))
	testing.expect(t, strings.contains(h, "__MITHRIL__"))
	// mithril.js 正文既不含占位符也不含 </script>（注入安全的前提，见 simple.go 注释）。
	testing.expect(t, ! strings.contains(m, "__CFG__"))
	testing.expect(t, ! strings.contains(m, "</scr"+"ipt>"))
}
