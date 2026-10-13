package backend

// cgi_io_test —— cgi-io 后端的纯决策 host 单测（会话闸 + 命令行反分词；对齐 cgi_io.go）。

import "core:testing"
import "core:mem"

@(test)
test_cgiio_require_session :: proc(t: ^testing.T) {
	testing.expect_value(t, cgiio_require_session(""), false)
	testing.expect_value(t, cgiio_require_session(Sess_Default_ID), false)
	testing.expect_value(t, cgiio_require_session("deadbeef"), true)
}

@(test)
test_cgiio_tokenize :: proc(t: ^testing.T) {
	backing: [8192]u8
	ar: mem.Arena
	mem.arena_init(&ar, backing[:])
	context.allocator = mem.arena_allocator(&ar)

	// 普通空格分词。
	a := cgiio_tokenize("ls -l /tmp")
	testing.expect_value(t, len(a), 3)
	testing.expect_value(t, a[0], "ls")
	testing.expect_value(t, a[2], "/tmp")

	// 反斜杠转义空格 → 单 token。
	b := cgiio_tokenize(`echo\ hi`)
	testing.expect_value(t, len(b), 1)
	testing.expect_value(t, b[0], "echo hi")

	// 反斜杠转义反斜杠 → 字面量反斜杠。
	c := cgiio_tokenize(`a\\b`)
	testing.expect_value(t, len(c), 1)
	testing.expect_value(t, c[0], `a\b`)

	// 空串 → 无 token。
	d := cgiio_tokenize("")
	testing.expect_value(t, len(d), 0)
}
