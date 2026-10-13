package handlers

// ubus_sse_test —— 纯 SSE 帧格式化 / 订阅错误信封的 host 单测（对齐 ubus.go 的 sseFrame/subscribeError）。

import "core:testing"
import "core:mem"

@(test)
test_sse_frame_and_heartbeat :: proc(t: ^testing.T) {
	backing: [8192]u8
	ar: mem.Arena
	mem.arena_init(&ar, backing[:])
	context.allocator = mem.arena_allocator(&ar)

	testing.expect_value(t, sse_frame("update", `{"a":1}`), "event: update\ndata: {\"a\":1}\n\n")
	testing.expect_value(t, sse_frame("", ""), "event: \ndata: \n\n")
	testing.expect_value(t, sse_heartbeat_frame, ": heartbeat\n\n")
}

@(test)
test_subscribe_error_json :: proc(t: ^testing.T) {
	backing: [8192]u8
	ar: mem.Arena
	mem.arena_init(&ar, backing[:])
	context.allocator = mem.arena_allocator(&ar)

	// posix 负码（ACL 不过）；键升序：code 在 message 前。
	testing.expect_value(t, subscribe_error_json(-ubus_eacces, "Permission denied"), `{"code":-13,"message":"Permission denied"}`)
	// ubus 正码（对象不存在等）。
	testing.expect_value(t, subscribe_error_json(9, "Unknown error"), `{"code":9,"message":"Unknown error"}`)
}
