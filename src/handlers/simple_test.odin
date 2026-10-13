package handlers

// simple_test —— 简洁版页面构造的纯逻辑 host 单测（页替换/注入/入口判定；对齐 simple.go）。

import "core:testing"
import "core:mem"
import "core:strings"
import "molly:assets"

@(test)
test_build_simple_page_substitution :: proc(t: ^testing.T) {
	// 堆上 arena backing（页面 ~数十 KB，但避免大局部数组落栈触发栈溢出告警）。
	ar: mem.Arena
	backing := make([]u8, 512000)
	prev := context.allocator
	mem.arena_init(&ar, backing)
	context.allocator = mem.arena_allocator(&ar)

	sid := "0123456789abcdef0123456789abcdef"
	page := build_simple_page("/admin", sid)

	// 两个占位符都被替换干净。
	testing.expect(t, ! strings.contains(page, "__CFG__"))
	testing.expect(t, ! strings.contains(page, "__MITHRIL__"))
	// 注入项：sid、专家版前缀、菜单首项（字段序邻接与 smoke 一致）。
	testing.expect(t, strings.contains(page, build([]string{`"sid":"`, sid, `"`})))
	testing.expect(t, strings.contains(page, `"expert":"/admin"`))
	testing.expect(t, strings.contains(page, `"id":"dash","title":"仪表盘","ready":true`))
	// Mithril 已落地：页面比未注入的 HTML 更长（mithril.js 正文进来了）。
	testing.expect(t, len(page) > len(assets.HTML()))

	context.allocator = prev
	delete(backing)
}

@(test)
test_build_simple_page_sanitizes_sid :: proc(t: ^testing.T) {
	ar: mem.Arena
	backing := make([]u8, 512000)
	prev := context.allocator
	mem.arena_init(&ar, backing)
	context.allocator = mem.arena_allocator(&ar)

	// 客户端 cookie 里的脚本注入：整串非 hex → 丢弃 → sid 为空，绝不到达页面。
	page := build_simple_page("/admin", "<script>x</script>")
	testing.expect(t, ! strings.contains(page, "<script>x"))
	testing.expect(t, strings.contains(page, `"sid":""`))

	context.allocator = prev
	delete(backing)
}

@(test)
test_is_simple_predicates :: proc(t: ^testing.T) {
	testing.expect(t, Is_Simple_Path("/lite"))
	testing.expect(t, Is_Simple_Path("/lite/"))
	testing.expect(t, Is_Simple_Path("/lite/admin/status"))
	testing.expect(t, ! Is_Simple_Path("/litefoo")) // 边界：裸 has_prefix 会误判
	testing.expect(t, ! Is_Simple_Path("/admin"))
	testing.expect(t, Is_Simple_Entry("/"))
	testing.expect(t, ! Is_Simple_Entry("/lite"))
}
