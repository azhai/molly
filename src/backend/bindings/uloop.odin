#+build linux
package bindings

// libubox 的 uloop 绑定：只绑「用 uloop 驱动 ubus 服务端」需要的那几个入口（ADR 0001）。
//
// 为什么必须自己驱动：`ubus_add_uloop` / `ubus_handle_event` 在 libubus.h:289/:295 是
// **static inline**（.so 里没有符号），而它们只有两句：
//     uloop_fd_add(&ctx->sock, ULOOP_BLOCKING | ULOOP_READ);
//     ctx->sock.cb(&ctx->sock, ULOOP_READ);
// 两者都只碰 `ctx->sock`，所以只要把 `struct ubus_context` 的 sock 偏移绑对
// （libubus.h:160-165，实测 80）就行——见 ubus.odin 里的 #assert。
//
// 尺寸/偏移不是估的：用真实头文件编译过一个 C 探针打印 offsetof/sizeof（2026-09-26），
// 数值见下面的 #assert；LP64 下 host 与 aarch64 的布局一致（bool 1 字节、指针 8 字节）。

import "core:c"

foreign import ubox "system:ubox"

// uloop.h:47-50
ULOOP_READ         :: 1 << 0
ULOOP_WRITE        :: 1 << 1
ULOOP_EDGE_TRIGGER :: 1 << 2
ULOOP_BLOCKING     :: 1 << 3

// uloop.h:41：void (*)(struct uloop_fd *, unsigned int)
Uloop_Fd_Handler :: proc "c" (u: ^Uloop_Fd, events: c.uint)

// struct uloop_fd（uloop.h:62-70）：cb(8) + fd(4) + 四个 1 字节标志 = 16
Uloop_Fd :: struct {
	cb:         Uloop_Fd_Handler, // 0
	fd:         c.int, // 8
	eof:        bool, // 12
	error:      bool, // 13
	registered: bool, // 14
	flags:      u8, // 15
}
#assert(size_of(Uloop_Fd) == 16, "Uloop_Fd 必须与 C 的 uloop_fd 同为 16 字节")
#assert(offset_of(Uloop_Fd, cb) == 0)
#assert(offset_of(Uloop_Fd, fd) == 8)

@(default_calling_convention = "c")
foreign ubox {
	uloop_init        :: proc() -> c.int ---
	uloop_fd_add      :: proc(sock: ^Uloop_Fd, flags: c.uint) -> c.int ---
	uloop_fd_delete   :: proc(sock: ^Uloop_Fd) -> c.int ---
	// uloop_run 是 static inline（uloop.h:147-150）= uloop_run_timeout(-1)
	uloop_run_timeout :: proc(timeout: c.int) -> c.int ---
	uloop_done        :: proc() ---
}

// 为什么这里只绑这几个：P3-1 只需要「起 ctx → 注册对象 → 跑事件循环」。
// 定时器（uloop_timeout_set）与 fd 注销（uloop_fd_delete）留给 P3-7 的 SSE 心跳，
// 到那时再加——AGENTS.md §2.1 的「写能跑起来的最小实现」。
