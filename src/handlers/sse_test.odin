package handlers

import "core:testing"

// 单元测试：SSE 的两个纯函数（分帧、拆总线记录）。
//
// 上游 `ubus.c:345` 的帧格式是 `event: %s\ndata: %s\n\n`，订阅被拒时回的是
// posix **负码**（`-EACCES`，:258/:384）——这两条最容易写错，钉在这里。

@(test)
test_sse_frame :: proc(t: ^testing.T) {
	alloc, ar := mk_arena()
	defer drop_arena(ar)

	testing.expect_value(t, sse_frame("add", `{"a":1}`, alloc), "event: add\ndata: {\"a\":1}\n\n")
	// 空 data 也要成套（上游 data 恒为 blobmsg 的 JSON，但格式本身不该特殊化）
	testing.expect_value(t, sse_frame("ping", "{}", alloc), "event: ping\ndata: {}\n\n")
}

@(test)
test_sse_record_split :: proc(t: ^testing.T) {
	method, data, ok := sse_record_split("add\t{\"a\":1}")
	testing.expect(t, ok)
	testing.expect_value(t, method, "add")
	testing.expect_value(t, data, `{"a":1}`)

	// tab 之后是空的也算（data 为空串）
	method2, data2, ok2 := sse_record_split("ping\t")
	testing.expect(t, ok2)
	testing.expect_value(t, method2, "ping")
	testing.expect_value(t, data2, "")

	// 没有 tab → 不是记录（残段/坏数据丢弃）
	_, _, bad := sse_record_split("no-tab-here")
	testing.expect(t, !bad)
}
