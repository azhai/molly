package backend

import "core:mem"
import "core:testing"

// 单元测试：backend 的共享纯函数与跨平台契约。
//
// 运行：odin test -collection:molly=src src/backend
//
// uci 相关断言针对的是 **darwin 的假配置**（src/backend/darwin.odin 的 FAKE_UCI）：
// 它存在的意义就是让 depends.uci 的每种形态能在 macOS 上被断言到；真机数据属第 7 步。
// 这些测试在 --target 下也会被编译（odin build 会类型检查测试代码），但只在 host 上运行。

// odin test 默认多线程跑用例，所以每个用例要**自己**一份 arena（共享全局会互相踩）。
// 用法：alloc, ar := mk_arena(); defer drop_arena(ar)
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

@(test)
test_ubus_error_message :: proc(t: ^testing.T) {
	alloc, ar := mk_arena()
	defer drop_arena(ar)

	testing.expect_value(t, ubus_error_message(0, alloc), "Success")
	testing.expect_value(t, ubus_error_message(4, alloc), "Not found")
	testing.expect_value(t, ubus_error_message(13, alloc), "System error")
	// 表外取值走上游的 out 分支：sprintf(err, "Unknown error: %d", error)
	testing.expect_value(t, ubus_error_message(99, alloc), "Unknown error: 99")
	testing.expect_value(t, ubus_error_message(-1, alloc), "Unknown error: -1")
}

@(test)
test_uci_config_sections_contract :: proc(t: ^testing.T) {
	alloc, ar := mk_arena()
	defer drop_arena(ar)

	sections, ok := uci_config_sections("network", alloc)
	testing.expect(t, ok, "network 应当可读")
	testing.expect(t, len(sections) > 0, "network 应当有 section")

	// 具名 section、匿名 section、option 的形状（契约见 backend.odin 顶部）
	found_lan := false
	found_anon := false
	for s in sections {
		if s.name == "lan" {
			found_lan = true
			testing.expect_value(t, s.type_name, "interface")
			found_proto := false
			for o in s.options {
				if o.name == "proto" {
					found_proto = true
					testing.expect_value(t, o.is_list, false)
					testing.expect_value(t, len(o.values), 1)
					testing.expect_value(t, o.values[0], "static")
				}
			}
			testing.expect(t, found_proto, "lan 应当有 proto")
		}
		if s.anonymous {
			found_anon = true
			testing.expect_value(t, s.name, "")
		}
	}
	testing.expect(t, found_lan, "假配置里应当有 network.lan")
	testing.expect(t, found_anon, "假配置里应当有匿名 section（@switch）")

	// 读不到的 config：ok = false（调用方按「0 个 section」处理）
	_, missing_ok := uci_config_sections("no-such-config", alloc)
	testing.expect(t, !missing_ok, "不存在的 config 应当 ok = false")

	// 存在但没有 section 的 config：ok = true 且空表（上游 `true` 形态据此判不满足）
	empty, empty_ok := uci_config_sections("empty-config", alloc)
	testing.expect(t, empty_ok)
	testing.expect_value(t, len(empty), 0)
}
