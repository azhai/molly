package backend

import "core:testing"
import "core:mem"
import "core:fmt"

// backend 派发的单测。用 arena 包住整个作用域避免裸分配 leak WARN；
// 与 event_bus_test 一样触及进程级全局（registry / bus），故用 ODIN_TEST_THREADS=1 串行跑。
@(test)
test_backend_dispatch :: proc(t: ^testing.T) {
	backing: [16384]u8
	ar: mem.Arena
	mem.arena_init(&ar, backing[:])
	old := context.allocator
	context.allocator = mem.arena_allocator(&ar)
	defer context.allocator = old
	alloc := context.allocator

	// ---- 状态码文案（协议表面的一部分）----
	testing.expect_value(t, Ubus_Error_Message(Status_OK), "Success")
	testing.expect_value(t, Ubus_Error_Message(Status_Not_Found), "Not found")
	testing.expect_value(t, Ubus_Error_Message(Status_System_Error), "System error")
	over := Ubus_Error_Message(999)
	testing.expect_value(t, over, "Unknown error: 999")

	// ---- 内置 molly.probe：ping ----
	status, reply := Dispatch(alloc, "molly.probe", "ping", "")
	testing.expect_value(t, status, Status_OK)
	testing.expect_value(t, reply, `{"pong":"molly"}`)

	// ---- 内置 molly.probe：notify → 扇到事件总线 ----
	sub, ok := Subscribe("molly.probe")
	testing.expect(t, ok, "Subscribe molly.probe 应成功")
	status, reply = Dispatch(alloc, "molly.probe", "notify", "")
	testing.expect_value(t, status, Status_OK)
	testing.expect_value(t, reply, `{"notified":"molly.probe"}`)

	ev, more := Recv(sub)
	testing.expect(t, more, "Recv 应拿到 notify 事件")
	testing.expect_value(t, ev.object, "molly.probe")
	testing.expect_value(t, ev.method, "ping")
	testing.expect_value(t, ev.data, `{"hello":"world"}`)
	Free_Event(ev)
	Unsubscribe(sub)

	// ---- 未知方法 ----
	status, _ = Dispatch(alloc, "molly.probe", "nope", "")
	testing.expect_value(t, status, Status_Method_Not_Found)

	// ---- 未注册对象（shim 只会转发已注册对象，走到这里 = 漏注册）----
	status, _ = Dispatch(alloc, "ghost", "x", "")
	testing.expect_value(t, status, Status_Not_Supported)

	// ---- 注册表接入：s3c~s3f 的对象的接缝形态 ----
	Register_Object(alloc, "fake.echo", fake_echo_handler)
	status, reply = Dispatch(alloc, "fake.echo", "hi", "")
	testing.expect_value(t, status, Status_OK)
	testing.expect_value(t, reply, "echo:hi") // 证明 handler 被接入
}

// fake_echo_handler —— 注册表形态探针：把 method 前缀回显（用当前 context 的 arena 造回复）。
fake_echo_handler :: proc(method, params_json: string, alloc: mem.Allocator) -> (status: i32, reply: string) {
	_ = alloc // 生产对象的 handler 会用显式 alloc；探针直接借 context.arena
	reply = fmt.tprintf("echo:%s", method)
	return Status_OK, reply
}
