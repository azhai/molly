#+build linux
package bindings

// libubus 的绑定。两种角色：
//   P2 客户端：lookup / lookup_id / invoke（HTTP 线程同步调用，见 linux.odin 的 g_ctx）
//   P3 服务端：注册对象 + 处理入站调用（专用线程，见 ADR 0001 与 linux.odin 的 ubus_server_thread）
//
// 只声明真正用得到的符号，且**全部**是 .so 里导出的函数（`llvm-nm -D` 核对过）：
//   ubus_connect / ubus_free / ubus_lookup / ubus_lookup_id / ubus_invoke_fd /
//   ubus_add_object / ubus_remove_object / ubus_send_reply / ubus_complete_deferred_request。
//
// static inline 的那两个（ubus_invoke、ubus_add_uloop）不能绑定，见文件末尾的等价实现。

import "core:c"

foreign import ubus "system:ubus"

// struct ubus_context（libubus.h:160-189，共 344 字节）。这里**只建模到 sock**：
// `ubus_add_uloop` 是 static inline，它要做 `uloop_fd_add(&ctx->sock, ...)`，
// 所以必须知道 sock 的偏移（实测 80，见下面的 #assert）。
//
// **不要**用这个布局去分配 ubus_context——它只是 libubus 给我们的指针的视图，
// 后面的字段（pending_timer / msgbuf / …）没有建模。
Ubus_Context :: struct {
	requests: Uci_List, // 0   list_head
	objects:  [48]byte, // 16  avl_tree（我们不读它，只要占位正确）
	pending:  Uci_List, // 64  list_head
	sock:     Uloop_Fd, // 80  ← uloop 的驱动入口
}
#assert(offset_of(Ubus_Context, sock) == 80, "uloop_fd_add(&ctx->sock) 依赖这个偏移")

// libubus.h:191-196：{ u32 id; u32 type_id; const char *path; struct blob_attr *signature }
// 回调里要读 path 与 signature，所以布局必须对：4+4+8+8 = 24。
Ubus_Object_Data :: struct {
	id:        u32,
	type_id:   u32,
	path:      cstring,
	signature: ^Blob_Attr,
}
#assert(size_of(Ubus_Object_Data) == 24)

// libubus.h:46-48：void (*)(ubus_context*, ubus_object_data*, void *priv)
Ubus_Lookup_Handler :: proc "c" (ctx: ^Ubus_Context, obj: ^Ubus_Object_Data, priv: rawptr)

// libubus.h:57-58：void (*)(struct ubus_request *req, int type, struct blob_attr *msg)
//
// 注意：C 的回调**没有 priv 形参**（priv 存在 struct ubus_request 里）。上游
// uhttpd 靠 container_of 从 req 反推自己的结构体；我们改用「全局累积 buf + 全局
// 互斥锁」——回调只在持锁的 invoke 期间跑，等价且不必猜 ubus_request 的布局。
Ubus_Data_Handler :: proc "c" (req: rawptr, msg_type: c.int, msg: ^Blob_Attr)

// ---------------------------------------------------------------------------
// 服务端（P3）
// ---------------------------------------------------------------------------

// libubus.h:49-51：int (*)(ubus_context*, ubus_object*, ubus_request_data*, const char*, blob_attr*)
Ubus_Handler :: proc "c" (
	ctx: ^Ubus_Context,
	obj: ^Ubus_Object,
	req: ^Ubus_Request_Data,
	method: cstring,
	msg: ^Blob_Attr,
) -> c.int

// struct ubus_request_data（libubus.h:204-215）：只当不透明句柄传回 libubus
// （ubus_send_reply / ubus_complete_deferred_request），所以不建模字段。
Ubus_Request_Data :: struct {}

// struct ubus_method（libubus.h:111-119）= 48
Ubus_Object_Method :: struct {
	name:     cstring, // 0
	handler:  Ubus_Handler, // 8
	mask:     c.ulong, // 16
	tags:     c.ulong, // 24
	policy:   rawptr, // 32  const struct blobmsg_policy *
	n_policy: c.int, // 40
}
#assert(size_of(Ubus_Object_Method) == 48, "Ubus_Object_Method 必须与 C 的 ubus_method 同为 48 字节")

// struct ubus_object_type（libubus.h:121-127）= 32
Ubus_Object_Type :: struct {
	name:      cstring, // 0
	id:        u32, // 8
	methods:   ^Ubus_Object_Method, // 16
	n_methods: c.int, // 24
}
#assert(size_of(Ubus_Object_Type) == 32, "Ubus_Object_Type 必须与 C 的 ubus_object_type 同为 32 字节")

// struct ubus_object（libubus.h:129-143）= 120；开头的 avl_node 只占位（libubus 自己维护）
Ubus_Object :: struct {
	avl:             [56]byte, // 0   struct avl_node
	name:            cstring, // 56
	id:              u32, // 64
	_pad0:           u32, // 68
	path:            cstring, // 72
	type:            ^Ubus_Object_Type, // 80
	subscribe_cb:    rawptr, // 88  ubus_state_handler_t
	has_subscribers: bool, // 96
	_pad1:           [7]byte, // 97
	methods:         ^Ubus_Object_Method, // 104
	n_methods:       c.int, // 112
}
#assert(size_of(Ubus_Object) == 120, "Ubus_Object 必须与 C 的 ubus_object 同为 120 字节")
#assert(offset_of(Ubus_Object, path) == 72, "我们用 name 注册，path 由 libubus 填；偏移必须对")
#assert(offset_of(Ubus_Object, type) == 80)
#assert(offset_of(Ubus_Object, methods) == 104)

foreign ubus {
	// path 传 nil 表示用库内编译时的默认 socket（UBUS_UNIX_SOCKET），
	// 比我们写死 /var/run/ubus/ubus.sock 更能跟随 SDK 版本。
	ubus_connect   :: proc(path: cstring) -> ^Ubus_Context ---
	ubus_free      :: proc(ctx: ^Ubus_Context) ---
	ubus_lookup    :: proc(ctx: ^Ubus_Context, path: cstring, cb: Ubus_Lookup_Handler, priv: rawptr) -> c.int ---
	ubus_lookup_id :: proc(ctx: ^Ubus_Context, path: cstring, id: ^u32) -> c.int ---
	// 同步版：内部 = invoke_async_fd + complete_request(timeout)，自己 poll
	// ctx->sock，所以**不需要** uloop 注册（libubus-req.c:248-262）。
	// fd 传 -1（不传文件描述符）。
	ubus_invoke_fd :: proc(ctx: ^Ubus_Context, obj: u32, method: cstring, msg: ^Blob_Attr, cb: Ubus_Data_Handler, priv: rawptr, timeout: c.int, fd: c.int) -> c.int ---

	// ---- 服务端 ----
	// 注册对象（libubus 会把 obj.path 填成 obj.name；成功后可被 `ubus list` 看到）
	ubus_add_object    :: proc(ctx: ^Ubus_Context, obj: ^Ubus_Object) -> c.int ---
	ubus_remove_object :: proc(ctx: ^Ubus_Context, obj: ^Ubus_Object) -> c.int ---
	// 在 handler 里回复：msg 传 blob_buf 的 head（blobmsg_buf_init + 若干 add 之后的 head）
	ubus_send_reply    :: proc(ctx: ^Ubus_Context, req: ^Ubus_Request_Data, msg: ^Blob_Attr) -> c.int ---
	// handler 返回 >0 时表示「稍后回复」，必须再调这个把请求收尾
	ubus_complete_deferred_request :: proc(ctx: ^Ubus_Context, req: ^Ubus_Request_Data, ret: c.int) ---

	// ---- 订阅（P3-7 S2，libubus.h:145-152 + libubus-sub.c:77-132）----
	// ubus_register_subscriber 内部会 `obj->methods = &watch_method; n_methods = 1`
	// 再 ubus_add_object（libubus-sub.c:86-89），所以调用方只需填 cb（对象名可为空，
	// ubus_add_object 对 name == NULL 是允许的，见 libubus-obj.c:227）。
	ubus_register_subscriber   :: proc(ctx: ^Ubus_Context, sub: ^Ubus_Subscriber) -> c.int ---
	ubus_subscribe             :: proc(ctx: ^Ubus_Context, sub: ^Ubus_Subscriber, id: u32) -> c.int ---
	ubus_unsubscribe           :: proc(ctx: ^Ubus_Context, sub: ^Ubus_Subscriber, id: u32) -> c.int ---
	// ubus_unregister_subscriber 是 static inline（libubus.h:329-335），.so 里没有
	// 符号——复刻在下面（与 ubus_add_uloop 同一个套路）。

	// libubus.h:427-428：给对象的所有订阅者发一条通知。
	// timeout < 0 表示**不等**订阅者回复（libubus.h:424-426）——SSE 只需要单向推送。
	ubus_notify :: proc(
		ctx: ^Ubus_Context,
		obj: ^Ubus_Object,
		type_: cstring,
		msg: ^Blob_Attr,
		timeout: c.int,
	) -> c.int ---
}

// libubus.h:53-54：void (*)(ubus_context*, ubus_subscriber*, uint32_t id)
Ubus_Remove_Handler :: proc "c" (ctx: ^Ubus_Context, sub: ^Ubus_Subscriber, id: u32)

// libubus.h:51（new_obj_cb 的实参是 `obj->path`，libubus-sub.c:73）
Ubus_New_Object_Handler :: proc "c" (ctx: ^Ubus_Context, sub: ^Ubus_Subscriber, path: cstring)

// struct ubus_subscriber（libubus.h:145-152）= 160
//   list_head 16 + ubus_object 120 + 三个回调 24
//
// `obj` 的偏移（16）是硬约束：libubus 的订阅回调里
// `container_of(obj, struct ubus_subscriber, obj)`（libubus-sub.c:23）就是按它反推的，
// molly 在通知回调里也要按同一个偏移找回自己的订阅结构。
Ubus_Subscriber :: struct {
	list:       Uci_List, // 0   struct list_head（next/prev，16 字节）
	obj:        Ubus_Object, // 16
	cb:         Ubus_Handler, // 136
	remove_cb:  Ubus_Remove_Handler, // 144
	new_obj_cb: Ubus_New_Object_Handler, // 152
}
#assert(size_of(Ubus_Subscriber) == 160, "Ubus_Subscriber 必须与 C 的 ubus_subscriber 同为 160 字节")
#assert(offset_of(Ubus_Subscriber, obj) == 16, "container_of(obj, ubus_subscriber, obj) 依赖这个偏移")

// libubus.h:289 的 static inline，逐字复刻：
//     uloop_fd_add(&ctx->sock, ULOOP_BLOCKING | ULOOP_READ);
ubus_add_uloop :: proc "contextless" (ctx: ^Ubus_Context) {
	uloop_fd_add(&ctx.sock, ULOOP_BLOCKING | ULOOP_READ)
}

// libubus.h:329-335 的 static inline，逐字复刻：
//     if (!list_empty(&obj->list)) list_del_init(&obj->list);
//     return ubus_remove_object(ctx, &obj->obj);
//
// `list_empty` = `next == &list`（INIT_LIST_HEAD 后自指）；`list_del_init` = 摘链
// 再 INIT_LIST_HEAD。molly 不用 new_obj_cb（不会进 auto_subscribers 链表），
// 所以这段实际恒为「已是空链 → 直接 remove_object」，但照样照抄，免得将来加了
// new_obj_cb 时语义悄悄跑偏。
ubus_unregister_subscriber :: proc "contextless" (ctx: ^Ubus_Context, sub: ^Ubus_Subscriber) -> c.int {
	self := &sub.list
	if sub.list.next != nil && sub.list.next != self {
		if sub.list.prev != nil {
			sub.list.prev.next = sub.list.next
		}
		if sub.list.next != nil {
			sub.list.next.prev = sub.list.prev
		}
		sub.list.next = self
		sub.list.prev = self
	}
	return ubus_remove_object(ctx, &sub.obj)
}

// 故意**不**绑定 ubus_strerror：错误文案由共享层 backend.ubus_error_message 提供。
// 那里抄的是 libubus.c 的 __ubus_strerror 表，darwin 的假实现也能给出一致的文案，
// 两个平台不会各自漂移（详见 backend.odin 的说明）。