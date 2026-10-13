package handlers

// luci_test —— luci_tree_path（URL 路径 → 菜单树路径）的 host 单测。纯字符串决策，不碰套接字/树。
// 钉住契约 §5.1：去前缀 + 补回被省掉的段；strip 空则原样返回去前缀后的剩余（含空串/裸 "/"）。

import "core:testing"
import "core:mem"

@(test)
test_luci_tree_path_no_strip :: proc(t: ^testing.T) {
	backing: [8192]u8
	ar: mem.Arena
	mem.arena_init(&ar, backing[:])
	context.allocator = mem.arena_allocator(&ar)

	// strip 为空（上游默认）：只去前缀，剩余原样返回。
	testing.expect_value(t, luci_tree_path("/cgi-bin/luci/admin/status", "/cgi-bin/luci", ""), "/admin/status")
	testing.expect_value(t, luci_tree_path("/cgi-bin/luci", "/cgi-bin/luci", ""), "") // 裸前缀 → 空路径（root firstchild）
	testing.expect_value(t, luci_tree_path("/admin/status", "/admin", ""), "/status")
}

@(test)
test_luci_tree_path_with_strip :: proc(t: ^testing.T) {
	backing: [8192]u8
	ar: mem.Arena
	mem.arena_init(&ar, backing[:])
	context.allocator = mem.arena_allocator(&ar)

	// 本站部署：prefix=/admin、strip=/admin。URL 少的那一段与树里多的那一段互相抵消。
	testing.expect_value(t, luci_tree_path("/admin/status/overview", "/admin", "/admin"), "/admin/status/overview")
	// 裸前缀 / 前缀斜杠 → 补成 "/"（root）。
	testing.expect_value(t, luci_tree_path("/admin", "/admin", "/admin"), "/")
	testing.expect_value(t, luci_tree_path("/admin/", "/admin", "/admin"), "/")
	// 长写法（URL 已带 /admin 段）不重复补。
	testing.expect_value(t, luci_tree_path("/admin/admin/status", "/admin", "/admin"), "/admin/status")
}
