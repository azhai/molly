#+build linux
package backend

// 目标平台（ImmortalWrt 25.12 / aarch64_cortex-a53 / musl）上的真实现。
//
// 接上的库：libubus + libblobmsg_json + libubox + libuci。libuci 在
// 第 6 步（dispatcher 的 `depends.uci`）首次被引用，之后 DT_NEEDED 里就会
// 出现 libuci.so——第 1 步的遗留验收项。
//
// ---------------------------------------------------------------------------
// 并发模型与全局状态（计划决策 3）
//
// libubus 的 ctx 和 blob_buf 都**不是**线程安全的：
//   * ubus_invoke_fd 是同步的，内部会 poll ctx->sock 并把回复写进临时 request；
//     两个线程同时用同一个 ctx 会互相抢消息。
//   * blob_buf 的 head 是可变状态（blob_new 每次都改 head 的 raw_len）。
// 而我们是「一连接一线程」。所以用**一把全局互斥锁**把
// 「构造请求 → invoke → 格式化 JSON」整段串起来，配全局 ctx 与三个全局 buf。
// 持锁期间不写 socket（JSON 成型后才交给 HTTP 层），所以慢客户端不会占着总线；
// 单次持锁上限 = UBUS_TIMEOUT_MS。
//
// 上游 uhttpd 不这么做是因为它跑在 uloop 单线程里；它的 blob_buf 也是
// static 全局（`ubus.c:470/573/690`），靠同样的「一次只处理一个请求」成立。
// 注意 blob_buf 可以反复 blob_buf_init：它不 memset 也不 free 旧内存，
// 而是复用 buf->buf（`blob.c:102-113`），所以全局 buf 不会漏。

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:encoding/json"
import "core:sys/posix"
import "core:time"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"

import "molly:backend/bindings"

// ubus_invoke_fd 的超时（毫秒）。上游 uhttpd 用 uloop 定时器 + ubus_abort_request
// 实现 script_timeout（默认 60s，`ubus.c:596-597`）；我们走同步调用，直接把它作为
// ubus_complete_request 的超时。超时后 ubus_invoke_fd 返回 UBUS_STATUS_TIMEOUT。
UBUS_TIMEOUT_MS :: 30_000

@(private)
g_lock: sync.Mutex

@(private)
g_ctx: ^bindings.Ubus_Context

// list 的累积 buf；call 的**请求** buf（invoke 期间必须一直有效）
@(private)
g_tmp: bindings.Blob_Buf

// call 的回复累积 buf（回调往里塞）
@(private)
g_acc: bindings.Blob_Buf

// 交给 blobmsg_format_json 的输出 buf
@(private)
g_out: bindings.Blob_Buf

// 惰性连接。连不上不缓存失败——下次调用再试一次，代价就是一次 connect()。
@(private)
ubus_ctx :: proc() -> ^bindings.Ubus_Context {
	if g_ctx == nil {
		// path 传 nil = 用库内编译时的默认 socket（UBUS_UNIX_SOCKET）
		g_ctx = bindings.ubus_connect(nil)
		if g_ctx == nil {
			fmt.eprintln("molly: 连接 ubus 失败（ubusd 没起来？）")
		}
	}
	return g_ctx
}

// ---------------------------------------------------------------------------
// GET /ubus/list 与 /ubus/list/<path>
// ---------------------------------------------------------------------------

@(private)
List_Data :: struct {
	buf:        ^bindings.Blob_Buf,
	verbose:    bool,
	add_object: bool,
}

// 上游 uh_ubus_list_cb（`ubus.c:602-656`）逐行复刻。
//
// 回调没有 priv 形参可用（priv 在 ubus_request 里，不在回调签名上——见
// bindings/ubus.odin 的说明），所以累积 buf 从 priv 走：priv 由调用方传成
// `&List_Data`，这是 ubus_lookup 支持的用法，不依赖任何结构体布局。
@(private)
list_cb :: proc "c" (ctx: ^bindings.Ubus_Context, obj: ^bindings.Ubus_Object_Data, priv: rawptr) {
	data := cast(^List_Data)priv

	// 非 verbose：只收集对象路径
	if !data.verbose {
		bindings.blobmsg_add_string(data.buf, nil, obj.path)
		return
	}

	// 没有签名（对象还没注册方法）就整个跳过
	if obj.signature == nil {
		return
	}

	o: rawptr
	if data.add_object {
		o = bindings.blobmsg_open_table(data.buf, obj.path)
		if o == nil {
			return
		}
	}

	// 签名的每个子项是一个方法，方法名就是子项的名字
	for it := bindings.blob_iter(obj.signature); bindings.blob_iter_ok(it); it = bindings.blob_iter_next(it) {
		t := bindings.blobmsg_open_table(data.buf, bindings.blobmsg_name(it.pos))

		// 方法内部再遍历一遍：只有 INT32 类型的项才是「参数类型声明」，
		// 它的值就是 BLOBMSG_TYPE_* 之一。
		inner := bindings.blob_iter_data(bindings.blobmsg_data(it.pos), bindings.blobmsg_data_len(it.pos))
		for p := inner; bindings.blob_iter_ok(p); p = bindings.blob_iter_next(p) {
			if bindings.blob_id(p.pos) != bindings.BLOBMSG_TYPE_INT32 {
				continue
			}
			name := bindings.blobmsg_name(p.pos)
			// 这是上游的类型映射表（`ubus.c:630-649`）：只有这六个取值。
			switch bindings.blobmsg_get_u32(p.pos) {
			case bindings.BLOBMSG_TYPE_INT8:
				bindings.blobmsg_add_string(data.buf, name, "boolean")
			case bindings.BLOBMSG_TYPE_INT32:
				bindings.blobmsg_add_string(data.buf, name, "number")
			case bindings.BLOBMSG_TYPE_STRING:
				bindings.blobmsg_add_string(data.buf, name, "string")
			case bindings.BLOBMSG_TYPE_ARRAY:
				bindings.blobmsg_add_string(data.buf, name, "array")
			case bindings.BLOBMSG_TYPE_TABLE:
				bindings.blobmsg_add_string(data.buf, name, "object")
			case:
				bindings.blobmsg_add_string(data.buf, name, "unknown")
			}
		}

		bindings.blobmsg_close_table(data.buf, t)
	}

	if data.add_object {
		bindings.blobmsg_close_table(data.buf, o)
	}
}

list_objects :: proc(path: string, alloc: mem.Allocator) -> (json: string, err: int, ok: bool) {
	sync.lock(&g_lock)
	defer sync.unlock(&g_lock)

	ctx := ubus_ctx()
	if ctx == nil {
		return "", UBUS_STATUS_CONNECTION_FAILED, false
	}

	if bindings.blob_buf_init(&g_tmp, 0) != 0 {
		return "", UBUS_STATUS_NO_MEMORY, false
	}

	data := List_Data {
		buf        = &g_tmp,
		verbose    = true,
		add_object = len(path) == 0, // path 为空 = 列全部对象，要包一层对象名
	}

	// path 为空时传 nil：ubus_lookup 的语义是「列出所有对象」
	path_c: cstring
	if len(path) > 0 {
		path_c = strings.clone_to_cstring(path, alloc)
	}

	e := bindings.ubus_lookup(ctx, path_c, list_cb, &data)
	if e != 0 {
		return "", int(e), false
	}

	// 上游把累积 buf 的顶层子项原样拷进一个新 buf 再格式化（`ubus.c:320-325`）。
	// 中间多这一跳是因为累积 buf 开着嵌套 table，而格式化要的是一层平的结构。
	if bindings.blob_buf_init(&g_out, 0) != 0 {
		return "", UBUS_STATUS_NO_MEMORY, false
	}
	for it := bindings.blob_iter(g_tmp.head); bindings.blob_iter_ok(it); it = bindings.blob_iter_next(it) {
		bindings.blobmsg_add_blob(&g_out, it.pos)
	}

	// blobmsg_format_json 返回 malloc 内存，必须 free（见 bindings/libc.odin）
	json_c := bindings.blobmsg_format_json(g_out.head, true)
	if json_c == nil {
		return "", UBUS_STATUS_NO_MEMORY, false
	}
	defer bindings.c_free(rawptr(json_c))

	return strings.clone_from_cstring(json_c, alloc), 0, true
}

// ---------------------------------------------------------------------------
// POST /ubus（旧式）与 POST /ubus/call/<path>（新式）的调用部分
// ---------------------------------------------------------------------------

// 上游 uh_ubus_request_data_cb（`ubus.c:450-459`）：把回复的每个顶层子项原样追加进
// 累积 buf。回调里的 msg 只在回调期间有效，所以必须在这里就拷完。
//
// 累积 buf 直接用全局 g_acc：回调只可能在持锁的 invoke 期间跑，正是因为它拿不到
// priv（C 的回调没有这个形参），这里才需要靠全局状态。
@(private)
call_data_cb :: proc "c" (req: rawptr, msg_type: c.int, msg: ^bindings.Blob_Attr) {
	if msg == nil {
		return
	}
	for it := bindings.blob_iter(msg); bindings.blob_iter_ok(it); it = bindings.blob_iter_next(it) {
		bindings.blobmsg_add_blob(&g_acc, it.pos)
	}
}

call_object :: proc(obj_path: string, method: string, params_json: string, sid: string, alloc: mem.Allocator) -> Call_Result {
	sync.lock(&g_lock)
	defer sync.unlock(&g_lock)

	ctx := ubus_ctx()
	if ctx == nil {
		return {outcome = .Internal}
	}

	// 1) 找对象（上游 `ubus.c:885-888` 的 ubus_lookup_id → ERROR_OBJECT）
	obj_id: u32
	if bindings.ubus_lookup_id(ctx, strings.clone_to_cstring(obj_path, alloc), &obj_id) != 0 {
		return {outcome = .Object_Not_Found}
	}

	// 2) 构造请求（上游 uh_ubus_send_request，`ubus.c:565-584`）：
	//    params 的每个键值 + 追加 ubus_rpc_session。
	//
	//    上游先是 `blobmsg_for_each_attr` 逐项 blobmsg_add_blob，但遇到客户端自己
	//    传的 ubus_rpc_session 就回 -32602（`ubus.c:578-582`）；我们这里用的
	//    blobmsg_add_json_from_string 展开的是一模一样的平铺结构
	//    （`blobmsg_add_object` 就是平铺，见 blobmsg_json.c:22-29），差别只在不去重。
	//    因此「params 里塞 ubus_rpc_session 覆盖会话」这件事由 handler 在 JSON 层
	//    提前拒掉（见 src/handlers/ubus_http.odin 的 invalid_params_json）。
	if bindings.blob_buf_init(&g_tmp, 0) != 0 {
		return {outcome = .Internal}
	}
	if len(params_json) > 0 {
		params_c := strings.clone_to_cstring(params_json, alloc)
		if !bindings.blobmsg_add_json_from_string(&g_tmp, params_c) {
			// params 是 handler 自己序列化的，到这里还解析失败只能是本机故障
			return {outcome = .Internal}
		}
	}
	bindings.blobmsg_add_string(&g_tmp, "ubus_rpc_session", strings.clone_to_cstring(sid, alloc))

	// 3) 同步调用（bindings/ubus.odin 里说明了为什么不需要 uloop 注册）
	if bindings.blob_buf_init(&g_acc, 0) != 0 {
		return {outcome = .Internal}
	}
	ret := bindings.ubus_invoke_fd(
		ctx,
		obj_id,
		strings.clone_to_cstring(method, alloc),
		g_tmp.head,
		call_data_cb,
		nil,
		UBUS_TIMEOUT_MS,
		-1,
	)
	if ret != 0 {
		// 已知偏差：ubus_invoke_fd 把「请求根本没发出去」和「远端返回
		// UBUS_STATUS_INVALID_ARGUMENT」合并成了同一个返回值。上游走异步 API 能
		// 分开（发不出去 → ERROR_INTERNAL）。我们按上游的语义判：INVALID_ARGUMENT
		// 当成本机故障，其余（NOT_FOUND / TIMEOUT / METHOD_NOT_FOUND …）当成远端
		// 返回码交给 handler。
		if ret == UBUS_STATUS_INVALID_ARGUMENT {
			return {outcome = .Internal}
		}
		return {outcome = .Ok, ret = int(ret)}
	}

	// 4) 格式化回复（上游 uh_ubus_request_cb 的非 legacy 分支，`ubus.c:504-514`）。
	//    没有数据时回 ""（对应上游的 `"result": null`），不去格式化空表——那样会
	//    得到 "{}"，handler 就分不清「空」和「空对象」了。
	if bindings.blob_len(g_acc.head) == 0 {
		return {outcome = .Ok, ret = 0}
	}

	if bindings.blob_buf_init(&g_out, 0) != 0 {
		return {outcome = .Internal}
	}
	t := bindings.blobmsg_open_table(&g_out, nil)
	for it := bindings.blob_iter(g_acc.head); bindings.blob_iter_ok(it); it = bindings.blob_iter_next(it) {
		bindings.blobmsg_add_blob(&g_out, it.pos)
	}
	bindings.blobmsg_close_table(&g_out, t)

	json_c := bindings.blobmsg_format_json(g_out.head, true)
	if json_c == nil {
		return {outcome = .Internal}
	}
	defer bindings.c_free(rawptr(json_c))

	return {outcome = .Ok, ret = 0, reply = strings.clone_from_cstring(json_c, alloc)}
}

// ---------------------------------------------------------------------------
// uci 数据访问（菜单的 depends.uci）
// ---------------------------------------------------------------------------

// uci context 与 ubus ctx 一样是全局单例，靠同一把 g_lock 串行化。
// uci 的 API 本身不是线程安全的（共享 ctx 里的 package 缓存），我们做只读遍历，
// 串行化之后不会互相踩。
@(private)
g_uci: ^bindings.Uci_Context

@(private)
uci_ctx :: proc() -> ^bindings.Uci_Context {
	if g_uci == nil {
		g_uci = bindings.uci_alloc_context()
		if g_uci == nil {
			fmt.eprintln("molly: uci 上下文创建失败")
		}
	}
	return g_uci
}

// ---------------------------------------------------------------------------
// ubus 服务端线程（P3-1，ADR `.ai-agents/adr/0001-ubus-uloop-thread.md`）
// ---------------------------------------------------------------------------

// 探针对象：P3-1 的唯一目的是证明「molly 能自己注册对象、并被 ubus 调到」。
// P3-2…P3-5 会用 session / uci / file / luci 逐个替掉它。
PROBE_OBJECT_NAME :: "molly.probe"

@(private)
g_probe_methods := [?]bindings.Ubus_Object_Method{
	{name = "ping", handler = probe_ping},
	// P3-9：真机上唯一能**触发**一条 ubus 通知的入口（`ubus call molly.probe notify`），
	// 于是 /ubus/subscribe 的 SSE 在设备上也能被验收。darwin 侧同名同语义（见 darwin.odin）。
	{name = "notify", handler = probe_notify},
}

@(private)
g_probe_type: bindings.Ubus_Object_Type

@(private)
g_probe_object: bindings.Ubus_Object

// handler 跑在服务线程的 uloop 回调里，所以**不需要** g_lock（那个锁保护的是
// HTTP 线程用的 client ctx）。
// 返回 0 = 已同步回复；返回 >0 才是 deferred（那时必须调 ubus_complete_deferred_request）。
@(private)
probe_ping :: proc "c" (
	ctx: ^bindings.Ubus_Context,
	obj: ^bindings.Ubus_Object,
	req: ^bindings.Ubus_Request_Data,
	method: cstring,
	msg: ^bindings.Blob_Attr,
) -> c.int {
	// ponytail: 探针只回一个固定字段，不解析入参——P3-2 起才需要 blobmsg_parse。
	buf: bindings.Blob_Buf
	bindings.blobmsg_buf_init(&buf)
	bindings.blobmsg_add_string(&buf, "pong", "molly")
	return bindings.ubus_send_reply(ctx, req, buf.head)
}

// P3-9：`molly.probe` 的 `notify` —— 给自己的订阅者发一条通知（type = "ping"）。
// 这是设备上验 SSE 的**触发源**：`ubus call molly.probe notify` → 订阅了
// `molly.probe` 的 /ubus/subscribe 连接应收到 `event: ping\ndata: {"hello":"world"}`。
// darwin 侧同名方法直接推事件总线（没有 ubusd 可发），可观测结果一致。
@(private)
probe_notify :: proc "c" (
	ctx: ^bindings.Ubus_Context,
	obj: ^bindings.Ubus_Object,
	req: ^bindings.Ubus_Request_Data,
	method: cstring,
	msg: ^bindings.Blob_Attr,
) -> c.int {
	buf: bindings.Blob_Buf
	bindings.blobmsg_buf_init(&buf)
	bindings.blobmsg_add_string(&buf, "hello", "world")
	// timeout < 0：单向下发，不等订阅者回复（libubus.h:424-428）
	bindings.ubus_notify(ctx, obj, "ping", buf.head, -1)

	// 再回调用方一个确认（同一个 blob_buf 可以重新 init：libubus 在 notify 里已把
	// 内容序列化走了，blob_buf_init 只是把 used 归零，见 bindings/blob.odin 的说明）。
	bindings.blobmsg_buf_init(&buf)
	bindings.blobmsg_add_string(&buf, "notified", "molly.probe")
	return bindings.ubus_send_reply(ctx, req, buf.head)
}

// 服务线程：建 ctx → 注册对象 → 跑 uloop。除出错外不返回（uloop_run 阻塞）。
@(private)
ubus_server_thread :: proc() {
	ctx := bindings.ubus_connect(nil)
	if ctx == nil {
		fmt.eprintln("[molly] ubus 服务线程：连不上 ubusd，molly 不提供 ubus 对象")
		return
	}
	defer bindings.ubus_free(ctx)

	// 与上游 rpcd 的静态对象同构：name 就是 path（libubus 会把 obj.path 填成 name）。
	g_probe_type = bindings.Ubus_Object_Type{
		name      = PROBE_OBJECT_NAME,
		methods   = &g_probe_methods[0],
		n_methods = c.int(len(g_probe_methods)),
	}
	g_probe_object = bindings.Ubus_Object {
		name      = PROBE_OBJECT_NAME,
		type      = &g_probe_type,
		methods   = &g_probe_methods[0],
		n_methods = c.int(len(g_probe_methods)),
	}
	if rc := bindings.ubus_add_object(ctx, &g_probe_object); rc != 0 {
		fmt.eprintln("[molly] ubus 服务线程：注册对象失败，错误码", rc)
		return
	}
	fmt.println("[molly] ubus 对象已注册:", PROBE_OBJECT_NAME)

	// P3-2：接管 session 对象。设备上 rpcd 还在跑时注册会失败——非致命，记一行继续：
	// 要真正接管，先 `/etc/init.d/rpcd stop`（见 .ai-memory/p3-luci-server.md 的部署步骤）。
	register_session_object(ctx)

	// P3-3（S1）：接管 uci 的**只读**部分（`configs`/`get`）。同样，rpcd 在跑时注册会失败。
	register_uci_object(ctx)

	// P3-5（S1）：接管 luci-rpc（getBoardJSON/getDHCPLeases；其余方法回 8）。
	register_luci_object(ctx)

	// P3-4（第一批）：接管 file 的路径/权限核心与 `read`。file 是平台无关的真实现，
	// 所以这段代码与 darwin 上被测到的是同一份。
	register_file_object(ctx)

	// commit 要触发 `service.event`（上游 uci.c:1304-1321），而 provider 层的签名里
	// 没有 ubus ctx，所以在这里记一份（服务线程的 ctx 生命周期覆盖整个进程）。
	g_ubus_ctx = ctx

	// uloop 的初始化与运行都只发生在这个线程里；HTTP 线程从不碰它（R4）。
	if bindings.uloop_init() != 0 {
		fmt.eprintln("[molly] ubus 服务线程：uloop_init 失败")
		return
	}
	bindings.ubus_add_uloop(ctx)
	// P3-7 S2：循环改成「带超时的 run」而不是 -1，好让 HTTP 线程排进来的订阅命令
	// 能在 ubus 线程里被执行（所有 ctx 改动都必须在这一线程做，ADR 0001）。
	for {
		_ = bindings.uloop_run_timeout(SSE_LOOP_POLL_MS)
		sse_drain_watch_cmds(ctx)
	}
	fmt.eprintln("[molly] ubus 服务线程：事件循环退出，molly 不再提供 ubus 对象")
}

// ---------------------------------------------------------------------------
// P3-7 S2：ubus 订阅（linux 真实现）
//
// 命令方向（HTTP → ubus 线程）：HTTP 线程只往队列排命令，`uloop_run_timeout` 每次
// 返回后由 ubus 线程排空——ADR 0001 说「所有 ctx/循环改动都在 ubus 线程里做」，
// 这里用「轮询排空」代替「把命令管道挂进 uloop」，少一个 uloop fd 绑定，
// 可观测行为一致（命令延迟 ≤ SSE_LOOP_POLL_MS）。
//
// 事件方向（ubus → HTTP）：通知回调在 ubus 线程里跑，调 `event_bus_publish` 写管道。
//
// 与上游的一个刻意差异：uhttpd 每条 SSE 连接一个 subscriber（`du` 是 per-client 的），
// molly 按 **path** 去重一个——发布时是按 path 匹配的，一个就够，也省掉设备上的
// ubus 对象数量。
// ---------------------------------------------------------------------------

// uloop 每次 run 的超时（毫秒）：既用来排空命令队列，也顺带当心跳节拍。
SSE_LOOP_POLL_MS :: 100

@(private)
Sse_Watch_Op :: enum {
	Start,
	Stop,
}

@(private)
Sse_Watch_Cmd :: struct {
	op:   Sse_Watch_Op,
	path: string,
}

// 一条订阅 = 一个 `ubus_subscriber`。`sub` 必须是第一个字段：通知回调里靠
// `container_of(obj, ubus_subscriber, obj)`（-16）反推回这里，才能知道是哪个 path。
@(private)
Sse_Sub :: struct {
	sub:  bindings.Ubus_Subscriber, // 0（obj 在 +16）
	path: cstring,
	id:   u32,
}

// HTTP 线程写、ubus 线程读
@(private)
g_sse_lock: sync.Mutex
@(private)
g_sse_cmds: [64]Sse_Watch_Cmd
@(private)
g_sse_n:    int

// 只有 ubus 线程碰（命令在 drain 里被消化，所以不需要锁）
@(private)
g_sse_subs: [EVENT_BUS_MAX]^Sse_Sub
@(private)
g_sse_sub_n: int

sse_watch_start :: proc(path: string) -> bool {
	sync.lock(&g_sse_lock)
	defer sync.unlock(&g_sse_lock)
	if g_sse_n >= len(g_sse_cmds) {
		fmt.eprintln("[molly] 订阅命令队列满了，丢弃：", path)
		return false
	}
	g_sse_cmds[g_sse_n] = Sse_Watch_Cmd{op = .Start, path = strings.clone(path, session_store_allocator())}
	g_sse_n += 1
	return true
}

sse_watch_stop :: proc(path: string) {
	sync.lock(&g_sse_lock)
	defer sync.unlock(&g_sse_lock)
	if g_sse_n >= len(g_sse_cmds) {
		return
	}
	g_sse_cmds[g_sse_n] = Sse_Watch_Cmd{op = .Stop, path = strings.clone(path, session_store_allocator())}
	g_sse_n += 1
}

// 排空命令队列 + 发布已收到的通知（只在 ubus 线程里跑）。
@(private)
sse_drain_watch_cmds :: proc(ctx: ^bindings.Ubus_Context) {
	sync.lock(&g_sse_lock)
	pending := g_sse_cmds
	n := g_sse_n
	g_sse_n = 0
	sync.unlock(&g_sse_lock)

	for i in 0 ..< n {
		switch pending[i].op {
		case .Start:
			sse_watch_apply_start(ctx, pending[i].path)
		case .Stop:
			sse_watch_apply_stop(ctx, pending[i].path)
		}
	}

	// 通知：回调里只搬字节（它没有 context，不能分配），发布在这里做
	for g_sse_ev_tail != g_sse_ev_head {
		slot := &g_sse_events[g_sse_ev_tail]
		g_sse_ev_tail = (g_sse_ev_tail + 1) % SSE_EVENT_SLOTS
		if !slot.ready {
			continue
		}
		slot.ready = false
		event_bus_publish(
			string(cstring(rawptr(&slot.path[0]))),
			string(cstring(rawptr(&slot.method[0]))),
			string(cstring(rawptr(&slot.data[0]))),
			session_store_allocator(),
		)
	}
}

// 通知的落脚点（回调 → 主循环）。定长环形槽 + 单线程（回调与主循环都在 ubus
// 线程里），所以不需要锁；槽满了就丢（SSE 是尽力而为的推送）。
SSE_EVENT_SLOTS :: 16

@(private)
Sse_Event_Slot :: struct {
	path:   [128]u8,
	method: [64]u8,
	data:   [1024]u8,
	ready:  bool,
}

@(private)
g_sse_events: [SSE_EVENT_SLOTS]Sse_Event_Slot
@(private)
g_sse_ev_head: int
@(private)
g_sse_ev_tail: int

// `proc "c"` 的回调里没有隐式 context，所以这条路径上不能有任何分配/断言：
// 只做字节搬运（copy_cstr 是手写的 for 循环）。
@(private)
sse_event_enqueue :: proc "contextless" (path, method, data: cstring) {
	next := (g_sse_ev_head + 1) % SSE_EVENT_SLOTS
	if next == g_sse_ev_tail {
		return // 满了：丢这条（订阅者会少一帧，不会乱序）
	}
	slot := &g_sse_events[g_sse_ev_head]
	n := copy_cstr(slot.path[:], path)
	n = copy_cstr(slot.method[:], method)
	n = copy_cstr(slot.data[:], data)
	slot.ready = true
	g_sse_ev_head = next
}

// cstring → 定长字节数组（手写循环：`proc "contextless"` 里用不了 core:strings 的
// 分配型函数，也不该引入 context）。
@(private)
copy_cstr :: proc "contextless" (dst: []u8, src: cstring) -> int {
	if src == nil {
		if len(dst) > 0 {
			dst[0] = 0
		}
		return 0
	}
	// cstring 不能直接下标（Odin 不允许），用多指针逐字节走
	p := transmute([^]u8) src
	i := 0
	for p[i] != 0 && i < len(dst) {
		dst[i] = p[i]
		i += 1
	}
	// 截尾：写 NUL（放不下时覆盖最后一个字节）
	last := i
	if i >= len(dst) {
		last = len(dst) - 1
	}
	dst[last] = 0
	return i
}

@(private)
sse_watch_apply_start :: proc(ctx: ^bindings.Ubus_Context, path: string) {
	for i in 0 ..< g_sse_sub_n {
		if g_sse_subs[i].path != nil && string(g_sse_subs[i].path) == path {
			return // 已经在订这个对象了
		}
	}
	if g_sse_sub_n >= len(g_sse_subs) {
		fmt.eprintln("[molly] ubus 订阅数已达上限，忽略：", path)
		return
	}

	path_c := strings.clone_to_cstring(path, session_store_allocator())
	id: u32
	if rc := bindings.ubus_lookup_id(ctx, path_c, &id); rc != 0 {
		fmt.eprintln("[molly] ubus 订阅失败（lookup_id）：", path, "错误码", rc)
		return
	}

	sse := new(Sse_Sub, session_store_allocator())
	sse.path = path_c
	sse.id = id
	sse.sub.cb = sse_notify_cb
	// remove_cb / new_obj_cb 不设：对象消失时我们不需要额外动作（SSE 连接断开
	// 走 event_bus_unsubscribe → 这里 ubus_unsubscribe 即可）。
	if rc := bindings.ubus_register_subscriber(ctx, &sse.sub); rc != 0 {
		fmt.eprintln("[molly] ubus_register_subscriber 失败，错误码", rc)
		free(sse)
		return
	}
	if rc := bindings.ubus_subscribe(ctx, &sse.sub, id); rc != 0 {
		fmt.eprintln("[molly] ubus_subscribe 失败，错误码", rc)
		bindings.ubus_unregister_subscriber(ctx, &sse.sub)
		free(sse)
		return
	}
	g_sse_subs[g_sse_sub_n] = sse
	g_sse_sub_n += 1
}

@(private)
sse_watch_apply_stop :: proc(ctx: ^bindings.Ubus_Context, path: string) {
	for i in 0 ..< g_sse_sub_n {
		sse := g_sse_subs[i]
		if sse.path == nil || string(sse.path) != path {
			continue
		}
		bindings.ubus_unsubscribe(ctx, &sse.sub, sse.id)
		bindings.ubus_unregister_subscriber(ctx, &sse.sub)
		g_sse_subs[i] = g_sse_subs[g_sse_sub_n - 1]
		g_sse_sub_n -= 1
		free(sse)
		return
	}
}

// 通知回调（跑在 ubus 线程的 uloop 回调里）。对应上游 `ubus.c:328-350`：
// `event: <method>\ndata: <blobmsg json>\n\n`——分帧由 HTTP 侧做，这里只把
// (path, method, json) 交给事件总线。
@(private)
sse_notify_cb :: proc "c" (
	ctx: ^bindings.Ubus_Context,
	obj: ^bindings.Ubus_Object,
	req: ^bindings.Ubus_Request_Data,
	method: cstring,
	msg: ^bindings.Blob_Attr,
) -> c.int {
	// container_of(obj, struct ubus_subscriber, obj) 的反向（libubus-sub.c:23）：
	// sub 是 Sse_Sub 的第一个字段，obj 在 sub 内的 +16。
	obj_addr := transmute(uintptr) obj
	sse := transmute(^Sse_Sub) transmute(rawptr)(obj_addr - offset_of(bindings.Ubus_Subscriber, obj))
	if sse == nil || sse.path == nil {
		return 0
	}

	// 回调里没有 context（不能分配），所以先落到定长槽里，由主循环发布。
	json := bindings.blobmsg_format_json(msg, true)
	if json != nil {
		defer bindings.c_free(rawptr(json))
		sse_event_enqueue(sse.path, method, json)
	}
	return 0
}

start_ubus_server :: proc() -> bool {
	t := thread.create_and_start(ubus_server_thread, self_cleanup = true)
	if t == nil {
		fmt.eprintln("[molly] 创建 ubus 服务线程失败")
		return false
	}
	return true
}

// ---------------------------------------------------------------------------
// session 对象（P3-2）：注册 + blobmsg ⇄ JSON 桥 + linux 侧的密码校验钩子
//
// 逻辑全在 `session.odin`（平台无关）；这里只做两件事：
//   1. 入站 blobmsg → JSON 文本 → session_call → 回复 JSON → blobmsg
//      （blobmsg_format_json / blobmsg_add_json_from_string，P2 已绑定）
//   2. 提供 linux 的 `session_verify_password`（/etc/shadow + crypt）
// ---------------------------------------------------------------------------

// 方法表与上游顺序一致（rpcd session.c:1355-1366）
@(private)
g_session_methods := [?]bindings.Ubus_Object_Method{
	{name = "create", handler = session_handler},
	{name = "list", handler = session_handler},
	{name = "grant", handler = session_handler},
	{name = "revoke", handler = session_handler},
	{name = "access", handler = session_handler},
	{name = "set", handler = session_handler},
	{name = "get", handler = session_handler},
	{name = "unset", handler = session_handler},
	{name = "destroy", handler = session_handler},
	{name = "login", handler = session_handler},
}

@(private)
g_session_type: bindings.Ubus_Object_Type

@(private)
g_session_object: bindings.Ubus_Object

@(private)
register_session_object :: proc(ctx: ^bindings.Ubus_Context) {
	g_session_type = bindings.Ubus_Object_Type{
		name      = "session",
		methods   = &g_session_methods[0],
		n_methods = c.int(len(g_session_methods)),
	}
	g_session_object = bindings.Ubus_Object {
		name      = "session",
		type      = &g_session_type,
		methods   = &g_session_methods[0],
		n_methods = c.int(len(g_session_methods)),
	}
	if rc := bindings.ubus_add_object(ctx, &g_session_object); rc != 0 {
		fmt.eprintln(
			"[molly] ubus 服务线程：注册 session 失败（rpcd 还在跑？先 /etc/init.d/rpcd stop），错误码",
			rc,
		)
		return
	}
	fmt.println("[molly] ubus 对象已注册: session")
}

// 一个 handler 覆盖全部方法：方法名由 libubus 传入（上游 rpc_handle_acl 也是按方法名分流）。
@(private)
session_handler :: proc "c" (
	ctx: ^bindings.Ubus_Context,
	obj: ^bindings.Ubus_Object,
	req: ^bindings.Ubus_Request_Data,
	method: cstring,
	msg: ^bindings.Blob_Attr,
) -> c.int {
	// proc "c" 里默认没有 Odin 的 context（见 blob.odin 顶部的说明），而 session_call 的
	// 调用链里有些 proc 带 `allocator := context.allocator` 这类默认参数——先装一个默认上下文。
	// 会话数据是长期存活的，用默认分配器（malloc）而不是线程 arena 更合适。
	context = runtime.default_context()
	alloc := context.allocator

	params := "{}"
	if msg != nil {
		// blobmsg_format_json 回的是 malloc 串（blobmsg_json.c 里的 strbuf），用完要 free
		js := bindings.blobmsg_format_json(msg, false)
		if js != nil {
			defer bindings.c_free(rawptr(js))
			params = string(js)
		}
	}

	reply, status := session_call(string(method), params, alloc)
	if status != 0 {
		// 非 0 就是 ubus 状态码：信封层渲染成 {"code":N,"message":"…"}（与上游一致）
		return c.int(status)
	}

	buf: bindings.Blob_Buf
	bindings.blobmsg_buf_init(&buf)
	defer bindings.blob_buf_free(&buf)

	if len(reply) == 0 {
		// set / unset / destroy 在**上游不回数据**；这里的桥统一回一个空表（信封里是 `{}`）。
		// 这是已知偏离，真机 golden 对比时要核对（见 .ai-memory/p3-luci-server.md）。
		_ = bindings.blobmsg_add_json_from_string(&buf, "{}")
	} else {
		_ = bindings.blobmsg_add_json_from_string(&buf, strings.clone_to_cstring(reply, alloc))
	}
	return bindings.ubus_send_reply(ctx, req, buf.head)
}

// session.c:819-853 的 rpc_login_test_password。
//
//   hash 为空串            → 任何密码都通过（「没设密码」）
//   hash 以 "$p$" 开头     → 引用 /etc/shadow 里该用户的 hash，递归比对
//   其它                   → crypt(password, hash) 与 hash 相等
//
// 上游用 getspnam()；musl 没有导出它，这里直接解析 /etc/shadow——语义等价且可单测。
// crypt() 用内部静态缓冲、非线程安全：本函数只在 ubus 服务线程里被调用（session 对象的
// handler 都跑在那个线程），darwin 侧是另一份实现。
@(private)
session_verify_password :: proc(hash, password: string, alloc: mem.Allocator) -> bool {
	if len(hash) == 0 {
		return true
	}
	if strings.has_prefix(hash, "$p$") {
		name := hash[3:]
		if len(name) == 0 {
			return false
		}
		sp, found := shadow_hash(name, alloc)
		if !found {
			return false
		}
		return session_verify_password(sp, password, alloc)
	}

	got := bindings.crypt(
		strings.clone_to_cstring(password, alloc),
		strings.clone_to_cstring(hash, alloc),
	)
	if got == nil {
		return false
	}
	return string(got) == hash
}

// session.c:834 getspnam(name)->sp_pwdp 的等价物：/etc/shadow 的第二个字段。
@(private)
shadow_hash :: proc(name: string, alloc: mem.Allocator) -> (hash: string, ok: bool) {
	data, rerr := os.read_entire_file("/etc/shadow", alloc)
	if rerr != nil {
		return "", false
	}

	rest := string(data)
	for len(rest) > 0 {
		line := rest
		if nl := strings.index_byte(rest, '\n'); nl >= 0 {
			line, rest = rest[:nl], rest[nl + 1:]
		} else {
			rest = ""
		}

		colon := strings.index_byte(line, ':')
		if colon <= 0 || line[:colon] != name {
			continue
		}
		fields := line[colon + 1:]
		if c2 := strings.index_byte(fields, ':'); c2 >= 0 {
			return fields[:c2], true
		}
		return fields, true
	}
	return "", false
}

// 一个 config 的全部 section（契约见 backend.odin 顶部）。
//
// 复刻上游 ucode 的 `uci.load(conf)` + `uci.foreach` / `uci.get_all`（dispatcher.uc:236-264）：
//   1. uci_load 把 package 读进 ctx（已加载的会直接命中缓存）；
//   2. 沿 pkg->sections 环形表遍历 section（uci_foreach_element，uci.h:552）；
//   3. 沿 section->options 遍历 option，list 型逐个取 v.list 的元素。
// uci_object / 判定逻辑都不在这里——它们留在 src/luci，与上游同层。
//
// ok == false 表示 config 读不到（uci_load 非 0）：调用方按「0 个 section」处理，
// 与上游 load 失败后 foreach 找不到东西等价。
//
// **本函数只在 --target 下编译，运行时正确性待真机（第 7 步）验证。**
uci_config_sections :: proc(config: string, alloc: mem.Allocator) -> (sections: []Uci_Section, ok: bool) {
	sync.lock(&g_lock)
	defer sync.unlock(&g_lock)

	ctx := uci_ctx()
	if ctx == nil {
		return nil, false
	}

	pkg: ^bindings.Uci_Package
	if bindings.uci_load(ctx, strings.clone_to_cstring(config, alloc), &pkg) != 0 || pkg == nil {
		return nil, false
	}

	return uci_package_sections(pkg, alloc), true
}

// uci_package → []Uci_Section（get/state/changes/commit 共用；P2 起就这一段）。
@(private)
uci_package_sections :: proc(pkg: ^bindings.Uci_Package, alloc: mem.Allocator) -> []Uci_Section {
	out := make([dynamic]Uci_Section, 0, 8, alloc)
	for el := bindings.uci_element_first(&pkg.sections); el != nil; {
		// 布局若与 C 不符，type 字段是第一个能看出来的地方（32 字节处）
		if el.type != .Section {
			el = bindings.uci_element_next(&pkg.sections, el)
			continue
		}
		sec := (^bindings.Uci_Section)(rawptr(el))

		opts := make([dynamic]Uci_Option, 0, 4, alloc)
		for oel := bindings.uci_element_first(&sec.options); oel != nil; {
			if oel.type != .Option {
				oel = bindings.uci_element_next(&sec.options, oel)
				continue
			}
			opt := (^bindings.Uci_Option)(rawptr(oel))

			values := make([dynamic]string, 0, 1, alloc)
			is_list := opt.type == .List
			if is_list {
				for lel := bindings.uci_element_first(&opt.v.list); lel != nil; {
					append(&values, bindings.uci_cstr(lel.name))
					lel = bindings.uci_element_next(&opt.v.list, lel)
				}
			} else {
				append(&values, bindings.uci_cstr(opt.v.string))
			}

			append(&opts, Uci_Option{
				name    = bindings.uci_cstr(oel.name),
				is_list = is_list,
				values  = values[:],
			})
			oel = bindings.uci_element_next(&sec.options, oel)
		}

		append(&out, Uci_Section{
			name      = bindings.uci_cstr(el.name),
			type_name = bindings.uci_cstr(sec.type_name),
			anonymous = sec.anonymous,
			options   = opts[:],
		})
		el = bindings.uci_element_next(&pkg.sections, el)
	}

	return out[:]
}

// ubus 服务线程的 context（uci_commit 触发 config.change 事件时要用）。
@(private)
g_ubus_ctx: ^bindings.Ubus_Context

// uci_list_configs：/etc/config/* 的字母序列表（libuci 内部走 glob）。
// P3-3 的 `configs` 方法用它（uci.c:1390）。
// P3-5：getBoardJSON 读的板级描述文件（luci.c 的 blobmsg_add_json_from_file 路径）。
luci_board_json_path :: proc() -> string {
	return "/etc/board.json"
}

// P3-6：acl.d 目录（session.h 的 RPC_SESSION_ACL_DIR + glob "/*.json"）。
session_acl_dir :: proc() -> string {
	return "/usr/share/rpcd/acl.d"
}

uci_list_configs :: proc(alloc: mem.Allocator) -> (names: []string, ok: bool) {
	sync.lock(&g_lock)
	defer sync.unlock(&g_lock)

	ctx := uci_ctx()
	if ctx == nil {
		return nil, false
	}

	list: [^]cstring
	if bindings.uci_list_configs(ctx, &list) != 0 || list == nil {
		return nil, false
	}
	defer bindings.uci_free_configs(list)

	out := make([dynamic]string, 0, 8, alloc)
	for i := 0; list[i] != nil; i += 1 {
		append(&out, bindings.uci_cstr(list[i]))
	}
	return out[:], true
}

// ---------------------------------------------------------------------------
// P3-3（S1）：接管 uci 对象
//
// 与 P3-2 的 session 同构：一个 handler 覆盖全部方法，入站 blobmsg → JSON 文本 →
// uci_call → 回复 JSON → blobmsg。方法表的顺序照抄上游（uci.c:1768-1784）。
//
// 目前只有只读的 `configs` / `get` 在 uci_object.odin 里真跑，其余回 NOT_SUPPORTED(8)
// （分片见 .ai-memory/p3-luci-server.md）。也就是说设备上接管这个对象后，
// **写方法不会改动 /etc/config**——写路径要等 S3 并用真机 golden 对着 uci CLI 验。
// ---------------------------------------------------------------------------

@(private)
g_uci_methods := [?]bindings.Ubus_Object_Method{
	{name = "configs", handler = uci_handler},
	{name = "get", handler = uci_handler},
	{name = "state", handler = uci_handler},
	{name = "add", handler = uci_handler},
	{name = "set", handler = uci_handler},
	{name = "delete", handler = uci_handler},
	{name = "rename", handler = uci_handler},
	{name = "order", handler = uci_handler},
	{name = "changes", handler = uci_handler},
	{name = "revert", handler = uci_handler},
	{name = "commit", handler = uci_handler},
	{name = "apply", handler = uci_handler},
	{name = "confirm", handler = uci_handler},
	{name = "rollback", handler = uci_handler},
	{name = "reload_config", handler = uci_handler},
}

@(private)
g_uci_type: bindings.Ubus_Object_Type

@(private)
g_uci_object: bindings.Ubus_Object

@(private)
register_uci_object :: proc(ctx: ^bindings.Ubus_Context) {
	g_uci_type = bindings.Ubus_Object_Type{
		name      = "uci",
		methods   = &g_uci_methods[0],
		n_methods = c.int(len(g_uci_methods)),
	}
	g_uci_object = bindings.Ubus_Object {
		name      = "uci",
		type      = &g_uci_type,
		methods   = &g_uci_methods[0],
		n_methods = c.int(len(g_uci_methods)),
	}
	if rc := bindings.ubus_add_object(ctx, &g_uci_object); rc != 0 {
		fmt.eprintln(
			"[molly] ubus 服务线程：注册 uci 失败（rpcd 还在跑？先 /etc/init.d/rpcd stop），错误码",
			rc,
		)
		return
	}
	fmt.println("[molly] ubus 对象已注册: uci（只读 configs/get，写方法回 NOT_SUPPORTED）")
}

@(private)
uci_handler :: proc "c" (
	ctx: ^bindings.Ubus_Context,
	obj: ^bindings.Ubus_Object,
	req: ^bindings.Ubus_Request_Data,
	method: cstring,
	msg: ^bindings.Blob_Attr,
) -> c.int {
	// 与 session_handler 同构。这段桥接两边完全一样，但 session 那条路径已经在设备上
	// 验过——抽公共 proc 的改动留到 P3-4/P3-5 一起做，先别动它。
	context = runtime.default_context()
	alloc := context.allocator

	params := "{}"
	if msg != nil {
		js := bindings.blobmsg_format_json(msg, false)
		if js != nil {
			defer bindings.c_free(rawptr(js))
			params = string(js)
		}
	}

	reply, status := uci_call(string(method), params, alloc)
	if status != 0 {
		// 非 0 = ubus 状态码：信封层渲染成 {"code":N,"message":"…"}（与上游一致）
		return c.int(status)
	}

	buf: bindings.Blob_Buf
	bindings.blobmsg_buf_init(&buf)
	defer bindings.blob_buf_free(&buf)

	if len(reply) == 0 {
		_ = bindings.blobmsg_add_json_from_string(&buf, "{}")
	} else {
		_ = bindings.blobmsg_add_json_from_string(&buf, strings.clone_to_cstring(reply, alloc))
	}
	return bindings.ubus_send_reply(ctx, req, buf.head)
}
// ---------------------------------------------------------------------------
// P3-3（S2）：delta / savedir / commit / revert
//
// 与上游的差别（有意为之，见 docs/interfaces.md §8）：
//   上游用**一个** uci_context，每次调用把它的 delta 搜索路径整表替换成
//   /var/run/rpcd/uci-<sid>（`rpc_uci_replace_savedir`，uci.c:264-303）——那要直接
//   改 `struct uci_context` 的内部（delta_path），而它是私有的（uci.h 只给不透明句柄）。
//   这里改成：**每个会话一个短命 context**（用完就 free）。新 context 的 delta 路径
//   天然只有我们加的那一个，没有跨会话串味，也不用碰内部结构。代价是每次调用多一次
//   uci_alloc_context（相对 uci_load 的解析开销可忽略，而且 molly 本来就不缓存解析结果）。
// ---------------------------------------------------------------------------

// 会话的 savedir：/var/run/rpcd/uci-<sid>；无 sid（内部调用）用 "/tmp/.uci"，
// 与上游 rpc_uci_set_savedir 的 else 分支一致（uci.c:293-297）。
@(private)
uci_savedir_of :: proc(sid: string, alloc: mem.Allocator) -> string {
	if len(sid) == 0 {
		return "/tmp/.uci"
	}
	return fmt.aprintf("%s%s", UCI_SAVEDIR_PREFIX, sid, allocator = alloc)
}

// 建一个带指定 delta 目录的 context。调用方负责 defer uci_free_context_ctx。
// delta 目录不存在也没关系：libuci 只是找不到 delta 文件（等于「没有未提交改动」）。
@(private)
uci_ctx_with_savedir :: proc(dir: string) -> ^bindings.Uci_Context {
	ctx := bindings.uci_alloc_context()
	if ctx == nil {
		return nil
	}
	if bindings.uci_set_savedir(ctx, strings.clone_to_cstring(dir)) != 0 {
		bindings.uci_free_context(ctx)
		return nil
	}
	return ctx
}

// 所有方法入口都由 uci_object.odin 调它。linux 侧是空实现：savedir 由每个操作自己
// 按 sid 建短命 context 来承载（见上面的说明），这里只报告「能切」。
uci_set_savedir :: proc(sid: string) -> bool {
	return true
}

// `state`：读**已提交态**（上游把 savedir 切到 /var/state，uci.c:619-620）。
uci_state_sections :: proc(config: string, alloc: mem.Allocator) -> (sections: []Uci_Section, status: int) {
	sync.lock(&g_lock)
	defer sync.unlock(&g_lock)

	ctx := uci_ctx_with_savedir("/var/state")
	if ctx == nil {
		return nil, UCI_STATUS_UNKNOWN_ERROR
	}
	defer bindings.uci_free_context(ctx)

	pkg: ^bindings.Uci_Package
	if bindings.uci_load(ctx, strings.clone_to_cstring(config, alloc), &pkg) != 0 || pkg == nil {
		return nil, UCI_STATUS_NOT_FOUND
	}
	defer bindings.uci_unload(ctx, pkg)

	return uci_package_sections(pkg, alloc), UCI_STATUS_OK
}

// `changes`：枚举该 config 的 `p->saved_delta`（uci.c:1250-1251、:1285-1286）。
uci_delta_changes :: proc(sid, config: string, alloc: mem.Allocator) -> (changes: []Uci_Change, status: int) {
	sync.lock(&g_lock)
	defer sync.unlock(&g_lock)

	ctx := uci_ctx_with_savedir(uci_savedir_of(sid, alloc))
	if ctx == nil {
		return nil, UCI_STATUS_UNKNOWN_ERROR
	}
	defer bindings.uci_free_context(ctx)

	pkg: ^bindings.Uci_Package
	if bindings.uci_load(ctx, strings.clone_to_cstring(config, alloc), &pkg) != 0 || pkg == nil {
		return nil, UCI_STATUS_NOT_FOUND
	}
	defer bindings.uci_unload(ctx, pkg)

	out := make([dynamic]Uci_Change, 0, 4, alloc)
	for el := bindings.uci_element_first(&pkg.saved_delta); el != nil; {
		d := (^bindings.Uci_Delta)(rawptr(el))
		kind: Uci_Change_Kind
		switch d.cmd {
		case .Add:
			kind = .Add
		case .Remove:
			kind = .Remove
		case .Change:
			kind = .Change
		case .Rename:
			kind = .Rename
		case .Reorder:
			kind = .Reorder
		case .List_Add:
			kind = .List_Add
		case .List_Del:
			kind = .List_Del
		}
		append(
			&out,
			Uci_Change {
				kind = kind,
				section = bindings.uci_cstr(d.section),
				name = bindings.uci_cstr(el.name),
				value = bindings.uci_cstr(d.value),
			},
		)
		el = bindings.uci_element_next(&pkg.saved_delta, el)
	}

	return out[:], UCI_STATUS_OK
}

// uci.c:1304-1321 rpc_uci_trigger_event：找 `service` 对象、调它的 event 方法，
// 载荷 {"type":"config.change","data":{"package":<config>}}，1s 超时。
// 没有 service 对象就什么都不做（上游也是 `if (!ubus_lookup_id(...))`）。
// 这个调用是**同步**的，且发生在 ubus 服务线程里——与 rpcd 完全一致
// （rpcd 的 handler 就跑在 uloop 线程里，用 ubus_invoke 同步调）。
@(private)
uci_trigger_event :: proc(ctx: ^bindings.Ubus_Context, config: string, alloc: mem.Allocator) {
	id: u32
	if bindings.ubus_lookup_id(ctx, "service", &id) != 0 {
		return
	}

	buf: bindings.Blob_Buf
	bindings.blobmsg_buf_init(&buf)
	defer bindings.blob_buf_free(&buf)

	_ = bindings.blobmsg_add_json_from_string(&buf, "{}")
	// 用 blobmsg 逐个字段写：name 参数为 NULL 时是数组项，这里都是命名表项
	_ = bindings.blobmsg_add_string(&buf, "type", strings.clone_to_cstring("config.change", alloc))
	t := bindings.blobmsg_open_table(&buf, "data")
	_ = bindings.blobmsg_add_string(&buf, "package", strings.clone_to_cstring(config, alloc))
	bindings.blobmsg_close_table(&buf, t)

	_ = bindings.ubus_invoke_fd(ctx, id, "event", buf.head, nil, nil, 1000, -1)
}

// `commit`：uci.c:1344-1351 —— load → uci_commit(ctx, &p, false) → unload → 触发事件。
// `overwrite=false` 与上游一致（uci.h:235-243：不覆盖，写完清掉 delta）。
uci_commit :: proc(sid, config: string, alloc: mem.Allocator) -> int {
	sync.lock(&g_lock)
	defer sync.unlock(&g_lock)

	ctx := uci_ctx_with_savedir(uci_savedir_of(sid, alloc))
	if ctx == nil {
		return UCI_STATUS_UNKNOWN_ERROR
	}
	defer bindings.uci_free_context(ctx)

	pkg: ^bindings.Uci_Package
	if bindings.uci_load(ctx, strings.clone_to_cstring(config, alloc), &pkg) != 0 || pkg == nil {
		return UCI_STATUS_NOT_FOUND
	}

	// 与上游同样的顺序：写盘用**服务线程的** ctx 触发事件，所以先把 commit 做完再
	// unload（事件里可能要读刚写下的配置）。
	rc := bindings.uci_commit(ctx, &pkg, false)
	if rc != 0 {
		bindings.uci_unload(ctx, pkg)
		return UCI_STATUS_UNKNOWN_ERROR
	}
	bindings.uci_unload(ctx, pkg)

	if g_ubus_ctx != nil {
		uci_trigger_event(g_ubus_ctx, config, alloc)
	}
	return UCI_STATUS_OK
}

// `revert`：uci.c:1353-1360 —— uci_lookup_ptr(package) → uci_revert → unload。
uci_revert :: proc(sid, config: string, alloc: mem.Allocator) -> int {
	sync.lock(&g_lock)
	defer sync.unlock(&g_lock)

	ctx := uci_ctx_with_savedir(uci_savedir_of(sid, alloc))
	if ctx == nil {
		return UCI_STATUS_UNKNOWN_ERROR
	}
	defer bindings.uci_free_context(ctx)

	ptr := bindings.Uci_Ptr {
		pkg = strings.clone_to_cstring(config, alloc),
	}
	if bindings.uci_lookup_ptr(ctx, &ptr, nil, true) != 0 || ptr.p == nil {
		return UCI_STATUS_NOT_FOUND
	}

	rc := bindings.uci_revert(ctx, &ptr)
	bindings.uci_unload(ctx, ptr.p)
	if rc != 0 {
		return UCI_STATUS_UNKNOWN_ERROR
	}
	return UCI_STATUS_OK
}

// ---------------------------------------------------------------------------
// P3-3（S3）：写事务
//
// 一次方法调用 = 一个事务 =「建会话 ctx → load → 改 → save → unload」。
// 事务期间**一直持 g_lock**：libuci 不是线程安全的，而且写路径是多步操作，
// 中间不能让别的请求插进来（读路径也是同样的锁，见 uci_config_sections）。
//
// 注意：`uci_save` 只把改动写进 savedir 里的 delta 文件，**不碰 /etc/config**；
// 真正落盘要 `commit`（S2 已实现）。
// ---------------------------------------------------------------------------

Uci_Write_Txn :: struct {
	ctx:    ^bindings.Uci_Context,
	pkg:    ^bindings.Uci_Package,
	config: string,
}

uci_write_begin :: proc(sid, config: string, alloc: mem.Allocator) -> (^Uci_Write_Txn, int) {
	sync.lock(&g_lock)

	ctx := uci_ctx_with_savedir(uci_savedir_of(sid, alloc))
	if ctx == nil {
		sync.unlock(&g_lock)
		return nil, UCI_STATUS_UNKNOWN_ERROR
	}

	pkg: ^bindings.Uci_Package
	if bindings.uci_load(ctx, strings.clone_to_cstring(config, alloc), &pkg) != 0 || pkg == nil {
		bindings.uci_free_context(ctx)
		sync.unlock(&g_lock)
		return nil, UCI_STATUS_NOT_FOUND
	}

	txn := new(Uci_Write_Txn)
	txn^ = Uci_Write_Txn {
		ctx    = ctx,
		pkg    = pkg,
		config = config,
	}
	return txn, UCI_STATUS_OK
}

uci_write_end :: proc(txn: ^Uci_Write_Txn) {
	if txn == nil {
		return
	}
	if txn.ctx != nil && txn.pkg != nil {
		bindings.uci_unload(txn.ctx, txn.pkg)
	}
	if txn.ctx != nil {
		bindings.uci_free_context(txn.ctx)
	}
	free(txn)
	sync.unlock(&g_lock)
}

uci_write_sections :: proc(txn: ^Uci_Write_Txn, alloc: mem.Allocator) -> ([]Uci_Section, int) {
	if txn == nil {
		return nil, UCI_STATUS_NOT_SUPPORTED
	}
	return uci_package_sections(txn.pkg, alloc), UCI_STATUS_OK
}

// section 是否存在（上游在分流 value 之前就查，见 uci.c:829-830、:749-755）。
@(private)
uci_write_section_exists :: proc(txn: ^Uci_Write_Txn, section: string, alloc: mem.Allocator) -> bool {
	ptr := bindings.Uci_Ptr {
		pkg     = strings.clone_to_cstring(txn.config, alloc),
		section = strings.clone_to_cstring(section, alloc),
	}
	if bindings.uci_lookup_ptr(txn.ctx, &ptr, nil, true) != 0 {
		return false
	}
	return ptr.s != nil
}

// 具名 section → `uci_set`（ptr.value = type，uci.c:713-722）；
// 匿名 → `uci_add_section`，名字由 libuci 生成（uci.c:724-731）。
uci_write_add_section :: proc(
	txn: ^Uci_Write_Txn,
	type_name, name: string,
	alloc: mem.Allocator,
) -> (string, int) {
	if txn == nil {
		return "", UCI_STATUS_NOT_SUPPORTED
	}

	if len(name) > 0 {
		ptr := bindings.Uci_Ptr {
			pkg     = strings.clone_to_cstring(txn.config, alloc),
			section = strings.clone_to_cstring(name, alloc),
			value   = strings.clone_to_cstring(type_name, alloc),
		}
		if bindings.uci_lookup_ptr(txn.ctx, &ptr, nil, true) != 0 {
			return "", UCI_STATUS_NOT_FOUND
		}
		if bindings.uci_set(txn.ctx, &ptr) != 0 {
			return "", UCI_STATUS_UNKNOWN_ERROR
		}
		return name, UCI_STATUS_OK
	}

	sec: ^bindings.Uci_Section
	type_c := strings.clone_to_cstring(type_name, alloc)
	if bindings.uci_add_section(txn.ctx, txn.pkg, type_c, &sec) != 0 || sec == nil {
		return "", UCI_STATUS_UNKNOWN_ERROR
	}
	return bindings.uci_cstr(sec.e.name), UCI_STATUS_OK
}

// 现有 option 的状态（不存在也算成功：exists = false）。
@(private)
uci_write_option_state :: proc(
	txn: ^Uci_Write_Txn,
	section, option: string,
	alloc: mem.Allocator,
) -> Uci_Option_State {
	ptr := bindings.Uci_Ptr {
		pkg     = strings.clone_to_cstring(txn.config, alloc),
		section = strings.clone_to_cstring(section, alloc),
		opt     = strings.clone_to_cstring(option, alloc),
	}
	if bindings.uci_lookup_ptr(txn.ctx, &ptr, nil, true) != 0 || ptr.s == nil || ptr.o == nil {
		return Uci_Option_State{}
	}

	state := Uci_Option_State {
		exists  = true,
		is_list = ptr.o.type == .List,
	}
	if !state.is_list && ptr.o.v.string != nil {
		state.value = bindings.uci_cstr(ptr.o.v.string)
	}
	return state
}

// 按计划层给的 ops 依次执行。每条 op 都重新 lookup（delete/set 会改变元素状态，
// 缓存 ptr 反而容易踩到已经释放的 uci_section ——上游也是每次重查）。
@(private)
uci_write_run_plan :: proc(
	txn: ^Uci_Write_Txn,
	section, option: string,
	plan: Uci_Merge_Plan,
	alloc: mem.Allocator,
) -> int {
	if plan.status != 0 {
		return plan.status
	}

	for item in plan.ops {
		ptr := bindings.Uci_Ptr {
			pkg     = strings.clone_to_cstring(txn.config, alloc),
			section = strings.clone_to_cstring(section, alloc),
			opt     = strings.clone_to_cstring(option, alloc),
		}
		if item.op == .Set_Option || item.op == .Add_List {
			ptr.value = strings.clone_to_cstring(item.value, alloc)
		}

		if bindings.uci_lookup_ptr(txn.ctx, &ptr, nil, true) != 0 {
			return UCI_STATUS_NOT_FOUND
		}

		rc: c.int
		switch item.op {
		case .Delete_Option:
			rc = bindings.uci_delete(txn.ctx, &ptr)
		case .Set_Option:
			if ptr.s == nil {
				return UCI_STATUS_NOT_FOUND
			}
			rc = bindings.uci_set(txn.ctx, &ptr)
		case .Add_List:
			if ptr.s == nil {
				return UCI_STATUS_NOT_FOUND
			}
			rc = bindings.uci_add_list(txn.ctx, &ptr)
		}

		if rc != 0 {
			return UCI_STATUS_UNKNOWN_ERROR
		}
	}

	return UCI_STATUS_OK
}

uci_write_merge_set :: proc(
	txn: ^Uci_Write_Txn,
	section, option: string,
	value: json.Value,
	alloc: mem.Allocator,
) -> int {
	if txn == nil {
		return UCI_STATUS_NOT_SUPPORTED
	}
	if !uci_verify_name(option) {
		return UCI_STATUS_INVALID_ARGUMENT
	}
	if !uci_write_section_exists(txn, section, alloc) {
		return UCI_STATUS_NOT_FOUND
	}
	plan := uci_plan_merge_set(value, uci_write_option_state(txn, section, option, alloc), alloc)
	return uci_write_run_plan(txn, section, option, plan, alloc)
}

uci_write_add_value :: proc(
	txn: ^Uci_Write_Txn,
	section, option: string,
	value: json.Value,
	alloc: mem.Allocator,
) -> int {
	if txn == nil {
		return UCI_STATUS_NOT_SUPPORTED
	}
	if !uci_verify_name(option) {
		return UCI_STATUS_INVALID_ARGUMENT
	}
	if !uci_write_section_exists(txn, section, alloc) {
		return UCI_STATUS_NOT_FOUND
	}
	plan := uci_plan_add_value(value, alloc)
	return uci_write_run_plan(txn, section, option, plan, alloc)
}

uci_write_save :: proc(txn: ^Uci_Write_Txn) -> int {
	if txn == nil {
		return UCI_STATUS_NOT_SUPPORTED
	}
	if bindings.uci_save(txn.ctx, txn.pkg) != 0 {
		return UCI_STATUS_UNKNOWN_ERROR
	}
	return UCI_STATUS_OK
}

// 删一个具名 option（uci.c:983-986、:998-999）：找不到 → 4。
@(private)
uci_write_delete_option :: proc(
	txn: ^Uci_Write_Txn,
	section, option: string,
	alloc: mem.Allocator,
) -> int {
	ptr := bindings.Uci_Ptr {
		pkg     = strings.clone_to_cstring(txn.config, alloc),
		section = strings.clone_to_cstring(section, alloc),
		opt     = strings.clone_to_cstring(option, alloc),
	}
	if bindings.uci_lookup_ptr(txn.ctx, &ptr, nil, true) != 0 || ptr.s == nil || ptr.o == nil {
		return UCI_STATUS_NOT_FOUND
	}
	if bindings.uci_delete(txn.ctx, &ptr) != 0 {
		return UCI_STATUS_UNKNOWN_ERROR
	}
	return UCI_STATUS_OK
}

// uci.c:954-1006 的执行部分：
//   .Section → 删整个 section（上游收到 NULL 的 opt）
//   .Option  → 删具名 option，找不到 → 4
//   .Options → 逐个删，**一个都没删到** → 4（`:973-991` 的聚合）
uci_write_delete :: proc(
	txn: ^Uci_Write_Txn,
	section: string,
	form: Uci_Delete_Form,
	names: []string,
	alloc: mem.Allocator,
) -> int {
	if txn == nil {
		return UCI_STATUS_NOT_SUPPORTED
	}

	switch form {
	case .Section:
		ptr := bindings.Uci_Ptr {
			pkg     = strings.clone_to_cstring(txn.config, alloc),
			section = strings.clone_to_cstring(section, alloc),
		}
		if bindings.uci_lookup_ptr(txn.ctx, &ptr, nil, true) != 0 || ptr.s == nil {
			return UCI_STATUS_NOT_FOUND
		}
		if bindings.uci_delete(txn.ctx, &ptr) != 0 {
			return UCI_STATUS_UNKNOWN_ERROR
		}
		return UCI_STATUS_OK

	case .Option:
		if len(names) == 0 {
			return UCI_STATUS_NOT_FOUND
		}
		return uci_write_delete_option(txn, section, names[0], alloc)

	case .Options:
		found := false
		for name in names {
			if uci_write_delete_option(txn, section, name, alloc) == UCI_STATUS_OK {
				found = true
			}
		}
		return found ? UCI_STATUS_OK : UCI_STATUS_NOT_FOUND
	}

	return UCI_STATUS_UNKNOWN_ERROR
}

// uci.c:1111-1121：lookup → `(ptr.option && !ptr.o) || !ptr.s` → 4 → uci_rename。
uci_write_rename :: proc(
	txn: ^Uci_Write_Txn,
	section, option, new_name: string,
	alloc: mem.Allocator,
) -> int {
	if txn == nil {
		return UCI_STATUS_NOT_SUPPORTED
	}

	ptr := bindings.Uci_Ptr {
		pkg     = strings.clone_to_cstring(txn.config, alloc),
		section = strings.clone_to_cstring(section, alloc),
		value   = strings.clone_to_cstring(new_name, alloc),
	}
	if len(option) > 0 {
		ptr.opt = strings.clone_to_cstring(option, alloc)
	}

	if bindings.uci_lookup_ptr(txn.ctx, &ptr, nil, true) != 0 {
		return UCI_STATUS_NOT_FOUND
	}
	if (len(option) > 0 && ptr.o == nil) || ptr.s == nil {
		return UCI_STATUS_NOT_FOUND
	}
	if bindings.uci_rename(txn.ctx, &ptr) != 0 {
		return UCI_STATUS_UNKNOWN_ERROR
	}
	return UCI_STATUS_OK
}

// 把 section 挪到 pos（uci.c:1177）。返回「找到了吗」——上游对找不到的项继续，
// 由调用方把状态码聚合成 4。
uci_write_reorder :: proc(txn: ^Uci_Write_Txn, section: string, pos: int, alloc: mem.Allocator) -> bool {
	if txn == nil {
		return false
	}

	ptr := bindings.Uci_Ptr {
		pkg     = strings.clone_to_cstring(txn.config, alloc),
		section = strings.clone_to_cstring(section, alloc),
	}
	if bindings.uci_lookup_ptr(txn.ctx, &ptr, nil, true) != 0 || ptr.s == nil {
		return false
	}

	_ = bindings.uci_reorder_section(txn.ctx, ptr.s, c.int(pos))
	return true
}

// ---------------------------------------------------------------------------
// P3-3（S4）：apply 系的两个 provider
// ---------------------------------------------------------------------------

// uci.c:1443-1455 rpc_uci_apply_config：load → commit（`overwrite = false`，写完清 delta）
// → unload → 触发 config.change 事件。
// `no_delta = true` 是回滚路径用的：上游在回滚时把 savedir 换成 /dev/null
// （uci.c:1524-1525），这样 uci_load 不会把**当前未提交的 delta** 合进来，
// 否则「恢复旧配置」会被污染。我们的每调用一个 ctx 的实现里，等价做法就是
// 让这个 ctx 的 delta 目录指向 /dev/null（libuci 在那里找不到 delta 文件）。
uci_apply_config :: proc(config: string, no_delta: bool, alloc: mem.Allocator) -> int {
	sync.lock(&g_lock)
	defer sync.unlock(&g_lock)

	ctx := uci_ctx_with_savedir(no_delta ? "/dev/null" : uci_savedir_of("", alloc))
	if ctx == nil {
		return UCI_STATUS_UNKNOWN_ERROR
	}
	defer bindings.uci_free_context(ctx)

	pkg: ^bindings.Uci_Package
	if bindings.uci_load(ctx, strings.clone_to_cstring(config, alloc), &pkg) != 0 || pkg == nil {
		// 上游忽略 load 失败（照样触发事件），这里也照做：只有真的 load 出来才提交
		if g_ubus_ctx != nil {
			uci_trigger_event(g_ubus_ctx, config, alloc)
		}
		return UCI_STATUS_OK
	}

	rc := bindings.uci_commit(ctx, &pkg, false)
	bindings.uci_unload(ctx, pkg)
	if g_ubus_ctx != nil {
		uci_trigger_event(g_ubus_ctx, config, alloc)
	}
	if rc != 0 {
		return UCI_STATUS_UNKNOWN_ERROR
	}
	return UCI_STATUS_OK
}

// uci.c:1720-1734 rpc_uci_reload：fork 一个子进程，先 sleep(2)（等这次 RPC 的响应发出去），
// 再 execv("/sbin/reload_config")；父进程立刻返回 0。
uci_reload_config :: proc(alloc: mem.Allocator) -> int {
	pid := posix.fork()
	if pid < 0 {
		return UCI_STATUS_UNKNOWN_ERROR
	}
	if pid == 0 {
		// 子进程：这里只做 sleep + exec（没有分配、没有 Odin 运行时依赖）
		time.sleep(2 * time.Second)
		argv := [2]cstring{"/sbin/reload_config", nil}
		posix.execv(argv[0], raw_data(argv[:]))
		posix._exit(127)
	}
	return UCI_STATUS_OK
}

// ---------------------------------------------------------------------------
// P3-4（第一批）：file 对象
//
// 与 uci 同构（一个 handler 覆盖全部方法 + blobmsg ⇄ JSON 桥），方法表照抄上游
// file.c 的 file_methods[] 顺序。
// ---------------------------------------------------------------------------

@(private)
g_file_methods := [?]bindings.Ubus_Object_Method{
	{name = "read", handler = file_handler},
	{name = "write", handler = file_handler},
	{name = "list", handler = file_handler},
	{name = "lstat", handler = file_handler},
	{name = "stat", handler = file_handler},
	{name = "md5", handler = file_handler},
	{name = "remove", handler = file_handler},
	{name = "exec", handler = file_handler},
}

@(private)
g_file_type: bindings.Ubus_Object_Type

@(private)
g_file_object: bindings.Ubus_Object

@(private)
register_file_object :: proc(ctx: ^bindings.Ubus_Context) {
	g_file_type = bindings.Ubus_Object_Type{
		name      = "file",
		methods   = &g_file_methods[0],
		n_methods = c.int(len(g_file_methods)),
	}
	g_file_object = bindings.Ubus_Object {
		name      = "file",
		type      = &g_file_type,
		methods   = &g_file_methods[0],
		n_methods = c.int(len(g_file_methods)),
	}
	if rc := bindings.ubus_add_object(ctx, &g_file_object); rc != 0 {
		fmt.eprintln(
			"[molly] ubus 服务线程：注册 file 失败（rpcd 还在跑？先 /etc/init.d/rpcd stop），错误码",
			rc,
		)
		return
	}
	fmt.println("[molly] ubus 对象已注册: file（read；其余方法待 P3-4 续，回 NOT_SUPPORTED）")
}

@(private)
file_handler :: proc "c" (
	ctx: ^bindings.Ubus_Context,
	obj: ^bindings.Ubus_Object,
	req: ^bindings.Ubus_Request_Data,
	method: cstring,
	msg: ^bindings.Blob_Attr,
) -> c.int {
	// 与 session_handler / uci_handler 同构（抽公共 proc 的改动留到 P3-5 一起做）
	context = runtime.default_context()
	alloc := context.allocator

	params := "{}"
	if msg != nil {
		js := bindings.blobmsg_format_json(msg, false)
		if js != nil {
			defer bindings.c_free(rawptr(js))
			params = string(js)
		}
	}

	reply, status := file_call(string(method), params, alloc)
	if status != 0 {
		return c.int(status)
	}

	buf: bindings.Blob_Buf
	bindings.blobmsg_buf_init(&buf)
	defer bindings.blob_buf_free(&buf)

	if len(reply) == 0 {
		_ = bindings.blobmsg_add_json_from_string(&buf, "{}")
	} else {
		_ = bindings.blobmsg_add_json_from_string(&buf, strings.clone_to_cstring(reply, alloc))
	}
	return bindings.ubus_send_reply(ctx, req, buf.head)
}

// ---------------------------------------------------------------------------
// P3-5（S1）：接管 luci-rpc 对象
//
// 与 session/uci/file 同构：一个 handler 覆盖全部方法。方法表照抄上游
// （luci.c:2033-2040，对象名 `luci-rpc`）。目前 getBoardJSON/getDHCPLeases 在
// luci_object.odin 里真跑，其余 4 个（netlink/iwinfo/getifaddrs 绑定）回
// NOT_SUPPORTED(8)，属 S2。
// ---------------------------------------------------------------------------

@(private)
g_luci_methods := [?]bindings.Ubus_Object_Method{
	{name = "getNetworkDevices", handler = luci_handler},
	{name = "getWirelessDevices", handler = luci_handler},
	{name = "getHostHints", handler = luci_handler},
	{name = "getDUIDHints", handler = luci_handler},
	{name = "getBoardJSON", handler = luci_handler},
	{name = "getDHCPLeases", handler = luci_handler},
}

@(private)
g_luci_type: bindings.Ubus_Object_Type

@(private)
g_luci_object: bindings.Ubus_Object

@(private)
register_luci_object :: proc(ctx: ^bindings.Ubus_Context) {
	g_luci_type = bindings.Ubus_Object_Type{
		name      = "rpcd-luci",
		methods   = &g_luci_methods[0],
		n_methods = c.int(len(g_luci_methods)),
	}
	g_luci_object = bindings.Ubus_Object{
		name      = "luci-rpc",
		type      = &g_luci_type,
		methods   = &g_luci_methods[0],
		n_methods = c.int(len(g_luci_methods)),
	}
	if rc := bindings.ubus_add_object(ctx, &g_luci_object); rc != 0 {
		fmt.eprintln(
			"[molly] ubus 服务线程：注册 luci-rpc 失败（rpcd 还在跑？先 /etc/init.d/rpcd stop），错误码",
			rc,
		)
		return
	}
	fmt.println("[molly] ubus 对象已注册: luci-rpc（getBoardJSON/getDHCPLeases/getDUIDHints，其余回 NOT_SUPPORTED）")
}

@(private)
luci_handler :: proc "c" (
	ctx: ^bindings.Ubus_Context,
	obj: ^bindings.Ubus_Object,
	req: ^bindings.Ubus_Request_Data,
	method: cstring,
	msg: ^bindings.Blob_Attr,
) -> c.int {
	// 与 session/uci/file 的 handler 同构（抽公共 proc 的改动留到 P3-6/P3-7 一起做）
	context = runtime.default_context()
	alloc := context.allocator

	params := "{}"
	if msg != nil {
		js := bindings.blobmsg_format_json(msg, false)
		if js != nil {
			defer bindings.c_free(rawptr(js))
			params = string(js)
		}
	}

	// luci-rpc 的两个已实现方法不消费 sid（上游 policy 里没有 session 字段），
	// 但注入保持与其它对象一致的机制，由 luci_call 自行忽略。
	reply, status := luci_call(string(method), params, alloc)
	if status != 0 {
		return c.int(status)
	}

	buf: bindings.Blob_Buf
	bindings.blobmsg_buf_init(&buf)
	defer bindings.blob_buf_free(&buf)

	if len(reply) == 0 {
		_ = bindings.blobmsg_add_json_from_string(&buf, "{}")
	} else {
		_ = bindings.blobmsg_add_json_from_string(&buf, strings.clone_to_cstring(reply, alloc))
	}
	return bindings.ubus_send_reply(ctx, req, buf.head)
}

// ---------------------------------------------------------------------------
// P3-5 S2b：getNetworkDevices（luci.c:648-896）
//
// 逐 /sys/class/net 条目读 sysfs + getifaddrs 拿 v4/v6/PACKET 地址。
// iwinfo（无线设备的 hwmodes/crypto 等字段）上游也是 dlopen 可选的——设备没有
// libiwinfo 时同样缺这些字段，这里先不实现（偏离记文档）。
// 只能在 linux 上跑（sysfs）；darwin 的同名 provider 回 8。
// ---------------------------------------------------------------------------

LUCI_IFF_UP :: 0x1
LUCI_IFF_BROADCAST :: 0x2
LUCI_IFF_LOOPBACK :: 0x8
LUCI_IFF_POINTOPOINT :: 0x10
LUCI_IFF_NOARP :: 0x80
LUCI_IFF_PROMISC :: 0x100
LUCI_IFF_MULTICAST :: 0x1000

// luci.c 的 readstr：读文件、去尾空白；打不开返回空串
@(private)
luci_readsys :: proc(path: string, alloc: mem.Allocator) -> string {
	data, err := os.read_entire_file(path, alloc)
	if err != nil {
		return ""
	}
	return strings.trim_space(string(data))
}

@(private)
luci_sa2str :: proc(sa: ^bindings.Sockaddr_Base, buf: [^]u8) -> string {
	switch sa.family {
	case 2: // AF_INET：sin_addr 在偏移 4
		got := posix.inet_ntop(.INET, rawptr(&sa.data[2]), buf, 16)
		if got != nil {
			return strings.clone(string(got), context.allocator)
		}
	case 10: // AF_INET6：sin6_addr 在偏移 8
		got := posix.inet_ntop(.INET6, rawptr(&sa.data[6]), buf, 46)
		if got != nil {
			return strings.clone(string(got), context.allocator)
		}
	case 17: // AF_PACKET：sll_addr 在偏移 12（= data[10]），取 6 字节（ea2str）
		mac := sa.data[10:16]
		out := make([]u8, 17, context.allocator)
		digits := "0123456789abcdef"
		for i := 0; i < 6; i += 1 {
			out[i * 3] = digits[mac[i] >> 4]
			out[i * 3 + 1] = digits[mac[i] & 15]
			if i < 5 {
				out[i * 3 + 2] = ':'
			}
		}
		return string(out[:])
	}
	return ""
}

@(private)
luci_netdev_json :: proc(
	name: string,
	ifa_start: ^bindings.Ifaddrs,
	alloc: mem.Allocator,
) -> json.Object {
	obj := make(json.Object, 8, alloc)
	obj["name"] = json.Value(json.String(name))

	// bridge（luci.c:670-698）：brif 目录能打开 → bridge=1 + ports + id + stp
	brif := fmt.aprintf("/sys/class/net/%s/brif", name, allocator = alloc)
	_, brif_err := os.read_directory_by_path(brif, -1, alloc)
	if brif_err == nil {
		obj["bridge"] = json.Value(json.Integer(1))
		ports := make([dynamic]json.Value, 0, 4, alloc)
		port_entries, pok := os.read_directory_by_path(brif, -1, alloc)
		if pok == nil {
			for p in port_entries {
				if p.name == "." || p.name == ".." {
					continue
				}
				append(&ports, json.Value(json.String(strings.clone(p.name, alloc))))
			}
		}
		obj["ports"] = json.Value(json.Array(ports))
		obj["id"] = json.Value(json.String(
			luci_readsys(fmt.aprintf("/sys/class/net/%s/bridge/bridge_id", name, allocator = alloc), alloc),
		))
		obj["stp"] = json.Value(json.Integer(
			luci_readsys(fmt.aprintf("/sys/class/net/%s/bridge/stp_state", name, allocator = alloc), alloc) != "0" ? 1 : 0,
		))
	}

	// master（readlink 的 basename，luci.c:700-706）
	if link, lerr := os.read_link(
		fmt.aprintf("/sys/class/net/%s/master", name, allocator = alloc),
		alloc,
	); lerr == nil {
		slash := strings.last_index_byte(link, '/')
		base := slash >= 0 ? link[slash + 1:] : link
		obj["master"] = json.Value(json.String(strings.clone(base, alloc)))
	}

	obj["wireless"] = json.Value(json.Integer(
		len(luci_readsys(fmt.aprintf("/sys/class/net/%s/phy80211/index", name, allocator = alloc), alloc)) > 0 ? 1 : 0,
	))

	operstate := luci_readsys(fmt.aprintf("/sys/class/net/%s/operstate", name, allocator = alloc), alloc)
	obj["up"] = json.Value(json.Integer((operstate == "up" || operstate == "unknown") ? 1 : 0))

	if mtu, pok := strconv.parse_uint(
		luci_readsys(fmt.aprintf("/sys/class/net/%s/mtu", name, allocator = alloc), alloc),
		10,
	); pok && mtu > 0 {
		obj["mtu"] = json.Value(json.Integer(i64(mtu)))
	}
	if qlen, pok := strconv.parse_uint(
		luci_readsys(fmt.aprintf("/sys/class/net/%s/tx_queue_len", name, allocator = alloc), alloc),
		10,
	); pok && qlen > 0 {
		obj["qlen"] = json.Value(json.Integer(i64(qlen)))
	}

	// devtype（luci.c:726-738）：uevent 里的 DEVTYPE= 行，缺省 "ethernet"
	devtype := "ethernet"
	uevent := luci_readsys(fmt.aprintf("/sys/class/net/%s/uevent", name, allocator = alloc), alloc)
	if idx := strings.index(uevent, "DEVTYPE="); idx >= 0 {
		rest := uevent[idx + len("DEVTYPE="):]
		nl := strings.index_byte(rest, '\n')
		devtype = nl >= 0 ? rest[:nl] : rest
	}
	obj["devtype"] = json.Value(json.String(devtype))

	// v4/v6 地址（luci.c:740-772），顺带把 flags OR 起来（luci.c:768/789）
	ifa_flags: u32
	buf: [46]u8
	families := [2]int{2, 10}
	family_keys := [2]string{"ipaddrs", "ip6addrs"}
	for fi := 0; fi < 2; fi += 1 {
		family := families[fi]
		arr := make([dynamic]json.Value, 0, 2, alloc)
		for ifa := ifa_start; ifa != nil; ifa = ifa.next {
			if ifa.addr == nil || ifa.addr.family != u16(family) {
				continue
			}
			if string(ifa.name) != name {
				continue
			}
			entry := make(json.Object, 2, alloc)
			entry["address"] = json.Value(json.String(luci_sa2str(ifa.addr, &buf[0])))
			if ifa.netmask != nil {
				entry["netmask"] = json.Value(json.String(luci_sa2str(ifa.netmask, &buf[0])))
			}
			if ifa.dstaddr != nil && (u32(ifa.flags) & LUCI_IFF_POINTOPOINT) != 0 {
				entry["remote"] = json.Value(json.String(luci_sa2str(ifa.dstaddr, &buf[0])))
			} else if ifa.dstaddr != nil && (u32(ifa.flags) & LUCI_IFF_BROADCAST) != 0 {
				entry["broadcast"] = json.Value(json.String(luci_sa2str(ifa.dstaddr, &buf[0])))
			}
			append(&arr, json.Value(entry))
			ifa_flags |= u32(ifa.flags)
		}
		obj[family_keys[fi]] = json.Value(json.Array(arr))
	}

	// PACKET 信息（luci.c:774-809）：mac/type/ifindex/parent，取第一个匹配项
	for ifa := ifa_start; ifa != nil; ifa = ifa.next {
		if ifa.addr == nil || ifa.addr.family != 17 {
			continue
		}
		if string(ifa.name) != name {
			continue
		}
		// struct sockaddr_ll（linux/if_packet.h）：family 0-1、protocol 2-3、
		// ifindex 4-7、hatype 8-9、pkttype 10、halen 11、addr 12-19。
		// 相对 Sockaddr_Base 的 data[]（从 sockaddr 偏移 2 起）：
		// ifindex → data[2..5]、hatype → data[6..7]、halen → data[9]、addr → data[10..17]
		hatype := u16(ifa.addr.data[6]) | u16(ifa.addr.data[7]) << 8
		ifindex := i32(
			u32(ifa.addr.data[2]) | u32(ifa.addr.data[3]) << 8 |
			u32(ifa.addr.data[4]) << 16 | u32(ifa.addr.data[5]) << 24,
		)
		if hatype == u16(1) {
			obj["mac"] = json.Value(json.String(luci_sa2str(ifa.addr, &buf[0])))
		}
		obj["type"] = json.Value(json.Integer(i64(hatype)))
		obj["ifindex"] = json.Value(json.Integer(i64(ifindex)))

		// parent（luci.c:791-806）：iflink != ifindex 时找对应设备名
		if iflink, pok := strconv.parse_int(
			luci_readsys(fmt.aprintf("/sys/class/net/%s/iflink", name, allocator = alloc), alloc),
			10,
		); pok && i32(iflink) != ifindex {
			for p := ifa_start; p != nil; p = p.next {
				if p.addr == nil || p.addr.family != 17 {
					continue
				}
				pi := i32(
					u32(p.addr.data[2]) | u32(p.addr.data[3]) << 8 |
					u32(p.addr.data[4]) << 16 | u32(p.addr.data[5]) << 24,
				)
				if pi == i32(iflink) {
					obj["parent"] = json.Value(json.String(strings.clone(string(p.name), alloc)))
					break
				}
			}
		}
		break // 只取第一个 PACKET 匹配（luci.c:808）
	}

	// stats（luci.c:811-820）
	stats_names := [10]string{
		"rx_bytes", "tx_bytes", "tx_errors", "rx_errors", "tx_packets",
		"rx_packets", "multicast", "collisions", "rx_dropped", "tx_dropped",
	}
	stats := make(json.Object, 10, alloc)
	for sn in stats_names {
		v, _ := strconv.parse_uint(
			luci_readsys(fmt.aprintf("/sys/class/net/%s/statistics/%s", name, sn, allocator = alloc), alloc),
			10,
		)
		stats[sn] = json.Value(json.Integer(i64(v)))
	}
	obj["stats"] = json.Value(stats)

	// flags（luci.c:822-830）
	flags := make(json.Object, 7, alloc)
	flags["up"] = json.Value(json.Integer((ifa_flags & LUCI_IFF_UP) != 0 ? 1 : 0))
	flags["broadcast"] = json.Value(json.Integer((ifa_flags & LUCI_IFF_BROADCAST) != 0 ? 1 : 0))
	flags["promisc"] = json.Value(json.Integer((ifa_flags & LUCI_IFF_PROMISC) != 0 ? 1 : 0))
	flags["loopback"] = json.Value(json.Integer((ifa_flags & LUCI_IFF_LOOPBACK) != 0 ? 1 : 0))
	flags["noarp"] = json.Value(json.Integer((ifa_flags & LUCI_IFF_NOARP) != 0 ? 1 : 0))
	flags["multicast"] = json.Value(json.Integer((ifa_flags & LUCI_IFF_MULTICAST) != 0 ? 1 : 0))
	flags["pointtopoint"] = json.Value(json.Integer((ifa_flags & LUCI_IFF_POINTOPOINT) != 0 ? 1 : 0))
	obj["flags"] = json.Value(flags)

	// link（luci.c:832-854）
	link := make(json.Object, 5, alloc)
	if speed := luci_readsys(fmt.aprintf("/sys/class/net/%s/speed", name, allocator = alloc), alloc); len(speed) > 0 {
		v, pok := strconv.parse_int(speed, 10)
		if pok {
			link["speed"] = json.Value(json.Integer(v))
		}
	}
	if duplex := luci_readsys(fmt.aprintf("/sys/class/net/%s/duplex", name, allocator = alloc), alloc); len(duplex) > 0 {
		link["duplex"] = json.Value(json.String(duplex))
	}
	carrier, _ := strconv.parse_int(luci_readsys(fmt.aprintf("/sys/class/net/%s/carrier", name, allocator = alloc), alloc), 10)
	link["carrier"] = json.Value(json.Integer(carrier == 1 ? 1 : 0))
	changes, _ := strconv.parse_int(luci_readsys(fmt.aprintf("/sys/class/net/%s/carrier_changes", name, allocator = alloc), alloc), 10)
	link["changes"] = json.Value(json.Integer(changes))
	up_count, _ := strconv.parse_int(luci_readsys(fmt.aprintf("/sys/class/net/%s/carrier_up_count", name, allocator = alloc), alloc), 10)
	link["up_count"] = json.Value(json.Integer(up_count))
	down_count, _ := strconv.parse_int(luci_readsys(fmt.aprintf("/sys/class/net/%s/carrier_down_count", name, allocator = alloc), alloc), 10)
	link["down_count"] = json.Value(json.Integer(down_count))
	obj["link"] = json.Value(link)

	return obj
}

// getNetworkDevices 的回复（luci.c:860-896）。
@(private)
luci_network_devices_json :: proc(alloc: mem.Allocator) -> (string, int) {
	doc := make(json.Object, 8, alloc)

	ifa_start: ^bindings.Ifaddrs
	if bindings.getifaddrs(&ifa_start) != 0 {
		ifa_start = nil // 上游失败也继续（只是没有地址信息）
	} else if ifa_start != nil {
		defer bindings.freeifaddrs(ifa_start)
	}

	entries, derr := os.read_directory_by_path("/sys/class/net", -1, alloc)
	if derr == nil {
		for e in entries {
			if e.name == "." || e.name == ".." {
				continue
			}
			doc[strings.clone(e.name, alloc)] = json.Value(luci_netdev_json(e.name, ifa_start, alloc))
		}
	}

	return session_marshal(json.Value(doc), alloc), LUCI_STATUS_OK
}

// ---------------------------------------------------------------------------
// P3-5 S2c：getWirelessDevices（luci.c:1098-1190）
//
// 上游是对 netifd 的 `network.wireless status` 的**代理**：ubus_invoke + 延迟回复，
// 回调里重塑（跳过 iwinfo 键、interfaces 数组逐表去掉 iwinfo、再按 radio 名补 iwinfo）。
// molly 用**同步** ubus_invoke（bindings.ubus_invoke_fd）：在 ubus 服务线程里等 netifd
// 回包——上游用 async + defer 避免在方法回调里重入 uloop；molly 的对象层是同步 RPC，
// 这里就直接同步取（偏离记文档）。
// iwinfo 未实现（见 S2b′），所以重塑等价于「跳过所有 iwinfo 键」。
// ---------------------------------------------------------------------------

@(private)
g_luci_invoke_reply: string

@(private)
luci_invoke_data_cb :: proc "c" (req: rawptr, msg_type: c.int, msg: ^bindings.Blob_Attr) {
	context = runtime.default_context()
	if msg == nil {
		return
	}
	js := bindings.blobmsg_format_json(msg, false)
	if js == nil {
		return
	}
	defer bindings.c_free(rawptr(js))
	g_luci_invoke_reply = strings.clone(string(js))
}

@(private)
luci_wireless_devices_json :: proc(alloc: mem.Allocator) -> (string, int) {
	ctx := g_ubus_ctx
	if ctx == nil {
		return "", LUCI_STATUS_UNKNOWN_ERROR
	}

	id: u32
	if bindings.ubus_lookup_id(ctx, "network.wireless", &id) != 0 {
		return "", LUCI_STATUS_NOT_FOUND // 上游：invoke_ubus 起不来 → NOT_FOUND（:1187）
	}

	req: bindings.Blob_Buf
	bindings.blobmsg_buf_init(&req)
	defer bindings.blob_buf_free(&req)

	g_luci_invoke_reply = ""
	if rc := bindings.ubus_invoke_fd(
		ctx,
		id,
		"status",
		req.head,
		luci_invoke_data_cb,
		nil,
		30000,
		-1,
	); rc != 0 {
		return "", LUCI_STATUS_UNKNOWN_ERROR
	}
	raw := g_luci_invoke_reply
	g_luci_invoke_reply = ""
	if len(raw) == 0 {
		return "", LUCI_STATUS_UNKNOWN_ERROR
	}

	doc: json.Value
	if err := json.unmarshal(transmute([]byte)(raw), &doc, .JSON, alloc); err != nil {
		return "", LUCI_STATUS_UNKNOWN_ERROR
	}
	status_obj, is_obj := doc.(json.Object)
	if !is_obj {
		return "", LUCI_STATUS_UNKNOWN_ERROR
	}

	out := make(json.Object, len(status_obj), alloc)
	for radio_name, radio_val in status_obj {
		radio, radio_ok := radio_val.(json.Object)
		if !radio_ok {
			continue // 上游只收 table（:1108-1110）
		}
		r_out := make(json.Object, len(radio), alloc)
		first_ifname := "" // 上游：第一个能取到 iwinfo 的接口名（:1151）
		for k, v in radio {
			if k == "iwinfo" {
				continue // :1120-1122
			}
			if k == "interfaces" {
				arr, arr_ok := v.(json.Array)
				if !arr_ok {
					continue // 类型不对 → 跳过整个键（:1124-1125）
				}
				i_out := make([dynamic]json.Value, 0, len(arr), alloc)
				for iface_val in arr {
					iface, iface_ok := iface_val.(json.Object)
					if !iface_ok {
						continue // 只收 table（:1132-1133）
					}
					clean := make(json.Object, len(iface), alloc)
					ifname := ""
					for ik, iv in iface {
						if ik == "iwinfo" {
							continue // :1143-1144
						}
						if ik == "ifname" {
							if sv, is_str := iv.(json.String); is_str {
								ifname = string(sv)
							}
						}
						clean[ik] = iv
					}
					// 接口级 iwinfo（phy_only=false）；第一个成功的 ifname 给 radio 级用
					if len(ifname) > 0 {
						if iw, iw_ok := luci_iwinfo_json(ifname, false, alloc); iw_ok {
							clean["iwinfo"] = json.Value(iw)
							if len(first_ifname) == 0 {
								first_ifname = strings.clone(ifname, alloc)
							}
						}
					}
					append(&i_out, json.Value(clean))
				}
				r_out["interfaces"] = json.Value(json.Array(i_out))
				continue
			}
			r_out[k] = v // 其余属性原样拷贝（blobmsg_add_blob，:1158-1160）
		}

		// radio 级 iwinfo（phy_only=true）：没有接口能取到时用 radio 名试（:1163-1165）
		radio_dev := len(first_ifname) > 0 ? first_ifname : radio_name
		if iw, iw_ok := luci_iwinfo_json(radio_dev, true, alloc); iw_ok {
			r_out["iwinfo"] = json.Value(iw)
		}

		out[radio_name] = json.Value(r_out)
	}

	return session_marshal(json.Value(out), alloc), LUCI_STATUS_OK
}

// ---------------------------------------------------------------------------
// P3-5 S2d：getHostHints（luci.c:1192-1828）
//
// 五个来源按优先级合并（**数字越大越靠前**）：
//   netlink 邻居表 10、/etc/ethers 50、dhcp 租约 100、getifaddrs 200、uci 静态租约 250
// 回复：以 MAC 文本为键的对象，值是 {ipaddrs:[v4 文本], ip6addrs:[v6 文本], name?}；
// 同一 MAC 的同族地址按（prio DESC, 地址字节 ASC）排序，重复地址取优先级更高者。
//
// 两个上游行为要照抄（golden 对比会看到）：
//   1. uci 静态租约的 `ip` **实际从不生效**——上游 uci_lookup_ptr 后的类型判断写成
//      `!= UCI_TYPE_STRING`（:1499-1503），正常 STRING 选项必然走 else → n=NULL →
//      in.s_addr=0 → 不添加地址。所以静态租约只贡献 MAC + hostname。
//   2. rrdns（`network.rrdns` ubus 调用）补主机名：v6 只在没有主机名时填，v4 **覆盖**。
//      rrdns 不存在时（非 OpenWrt 环境）静默跳过。
//
// linux-only（netlink/ifaddrs/sysfs）；darwin 回 8。
// ---------------------------------------------------------------------------

LUCI_PRIO_NL :: 10
LUCI_PRIO_ETHER :: 50
LUCI_PRIO_LEASEFILE :: 100
LUCI_PRIO_IFADDRS :: 200
LUCI_PRIO_STATIC_LEASE :: 250

Luci_Hint_Addr :: struct {
	af:   int, // 4 / 6
	prio: int,
	addr: string,
}

Luci_Hint :: struct {
	hostname: string,
	v4:       [dynamic]Luci_Hint_Addr,
	v6:       [dynamic]Luci_Hint_Addr,
}

@(private)
luci_hint_get :: proc(hints: ^map[string]^Luci_Hint, mac: string, alloc: mem.Allocator) -> ^Luci_Hint {
	if h, ok := hints[mac]; ok {
		return h
	}
	h := new(Luci_Hint, alloc)
	h^ = Luci_Hint {
		v4 = make([dynamic]Luci_Hint_Addr, 0, 2, alloc),
		v6 = make([dynamic]Luci_Hint_Addr, 0, 2, alloc),
	}
	hints[strings.clone(mac, alloc)] = h
	return h
}

// 地址的字节日表示（比较用；失败返回 (buf, 0)）
@(private)
luci_addr_bytes :: proc(af: int, addr: string, buf: ^[16]u8) -> int {
	c := strings.clone_to_cstring(addr)
	ok := posix.inet_pton(af == 4 ? .INET : .INET6, c, rawptr(buf))
	return ok == .SUCCESS ? (af == 4 ? 4 : 16) : 0
}

// luci.c:1279-1320：同族同地址去重，只有更高优先级才更新
@(private)
luci_hint_add_addr :: proc(h: ^Luci_Hint, af: int, prio: int, addr: string, alloc: mem.Allocator) {
	list := af == 4 ? &h.v4 : &h.v6
	for &item in list {
		if item.addr == addr {
			if prio > item.prio {
				item.prio = prio // 上游：删了重插以获得新排序；这里排序在收尾统一做
			}
			return
		}
	}
	append(list, Luci_Hint_Addr{af = af, prio = prio, addr = strings.clone(addr, alloc)})
}

@(private)
luci_hint_sort :: proc(list: ^[dynamic]Luci_Hint_Addr) {
	// 插入排序：prio DESC，同 prio 比地址字节 ASC（luci.c:1219-1234）
	for i := 1; i < len(list); i += 1 {
		cur := list[i]
		j := i - 1
		for j >= 0 {
			other := list[j]
			less := false
			if cur.prio != other.prio {
				less = cur.prio > other.prio
			} else {
				a: [16]u8
				b: [16]u8
				la := luci_addr_bytes(cur.af, cur.addr, &a)
				lb := luci_addr_bytes(other.af, other.addr, &b)
				if la != 0 && lb != 0 && la == lb {
					cmp := 0
					for k := 0; k < la; k += 1 {
						if a[k] != b[k] {
							cmp = int(a[k]) - int(b[k])
							break
						}
					}
					less = cmp < 0
				}
			}
			if !less {
				break
			}
			list[j + 1] = other
			j -= 1
		}
		list[j + 1] = cur
	}
}

// --- 来源 1：netlink 邻居表（luci.c:1236-1425）-----------------------------
//
// 用**裸 netlink socket**（不引 libnl：设备上 rpcd 侧有 libnl，但 molly 少一个运行时依赖）。
// 发 RTM_GETNEIGH dump，收 RTM_NEWNEIGH，过滤 family/state，取 NDA_DST + NDA_LLADDR。

LUCI_AF_NETLINK :: 16
LUCI_NETLINK_ROUTE :: 0
LUCI_RTM_NEWNEIGH :: 28
LUCI_RTM_GETNEIGH :: 30
LUCI_NLM_F_REQUEST :: 0x1
LUCI_NLM_F_DUMP :: 0x300
LUCI_NLM_F_MULTI :: 0x2
LUCI_NLMSG_ERROR :: 2
LUCI_NLMSG_DONE :: 3
LUCI_NDA_DST :: 1
LUCI_NDA_LLADDR :: 3
LUCI_NUD_NOARP :: 0x40

@(private)
luci_mac_text :: proc(bytes: []u8, alloc: mem.Allocator) -> string {
	if len(bytes) < 6 {
		return ""
	}
	out := make([]u8, 17, alloc)
	digits := "0123456789abcdef"
	for i := 0; i < 6; i += 1 {
		out[i * 3] = digits[bytes[i] >> 4]
		out[i * 3 + 1] = digits[bytes[i] & 15]
		if i < 5 {
			out[i * 3 + 2] = ':'
		}
	}
	return string(out[:])
}

@(private)
luci_ip_text :: proc(af: int, bytes: []u8, alloc: mem.Allocator) -> string {
	if af == 4 && len(bytes) < 4 {
		return ""
	}
	if af == 6 && len(bytes) < 16 {
		return ""
	}
	buf: [46]u8
	got := posix.inet_ntop(af == 4 ? .INET : .INET6, rawptr(&bytes[0]), &buf[0], 46)
	if got == nil {
		return ""
	}
	return strings.clone(string(got), alloc)
}

@(private)
luci_get_host_hints_nl :: proc(
	hints: ^map[string]^Luci_Hint,
	alloc: mem.Allocator,
) {
	fd := posix.socket(posix.AF(LUCI_AF_NETLINK), .RAW, posix.Protocol(LUCI_NETLINK_ROUTE))
	if int(fd) < 0 {
		return
	}
	defer posix.close(fd)

	// bind 拿一个端口（pid=0 → 内核分配）
	addr: [12]u8 // struct sockaddr_nl{family u16, pad u16, pid u32, groups u32}
	addr[0] = u8(LUCI_AF_NETLINK)
	if posix.bind(fd, (^posix.sockaddr)(rawptr(&addr[0])), 12) != .OK {
		return
	}

	// 请求：nlmsghdr(16) + ndmsg(12)
	req: [28]u8
	req_len: u32 = 28
	req[0] = u8(req_len & 0xff)
	req[1] = u8((req_len >> 8) & 0xff)
	req[2] = u8((req_len >> 16) & 0xff)
	req[3] = u8((req_len >> 24) & 0xff)
	req_type: u16 = u16(LUCI_RTM_GETNEIGH)
	req[4] = u8(req_type & 0xff)
	req[5] = u8(req_type >> 8)
	req_flags: u16 = u16(LUCI_NLM_F_REQUEST | LUCI_NLM_F_DUMP)
	req[6] = u8(req_flags & 0xff)
	req[7] = u8(req_flags >> 8)
	// ndm_family = AF_UNSPEC(0)，其余全 0

	if posix.send(fd, &req[0], 28, {}) < 0 {
		return
	}

	buf: [16384]u8
	done := false
	for !done {
		n := posix.recv(fd, &buf[0], len(buf), {})
		if n <= 0 {
			break
		}
		off := 0
		for off + 16 <= int(n) {
			msg_len := int(u32(buf[off]) | u32(buf[off + 1]) << 8 | u32(buf[off + 2]) << 16 | u32(buf[off + 3]) << 24)
			msg_type := u16(buf[off + 4]) | u16(buf[off + 5]) << 8
			if msg_len < 16 || off + msg_len > int(n) {
				break
			}
			if msg_type == u16(LUCI_NLMSG_DONE) {
				done = true
				break
			}
			if msg_type == u16(LUCI_NLMSG_ERROR) {
				done = true
				break
			}
			if msg_type == u16(LUCI_RTM_NEWNEIGH) && msg_len >= 28 {
				nd := off + 16
				family := buf[nd]
				state := u16(buf[nd + 8]) | u16(buf[nd + 9]) << 8

				// family 只认 v4/v6；state 里除了 NOARP 之外任意位（luci.c:1346-1351）
				ok_family := family == 2 || family == 10
				ok_state := (state & (0xff & ~u16(LUCI_NUD_NOARP))) != 0
				if ok_family && ok_state {
					af := int(family) == 2 ? 4 : 6
					dst: []u8
					mac: []u8
					// 属性从 nd+12 开始
					ao := nd + 12
					for ao + 4 <= off + msg_len {
						alen := int(u16(buf[ao]) | u16(buf[ao + 1]) << 8)
						atype := u16(buf[ao + 2]) | u16(buf[ao + 3]) << 8
						if alen < 4 || ao + alen > off + msg_len {
							break
						}
						payload := buf[ao + 4:ao + alen]
						if atype == u16(LUCI_NDA_DST) {
							dst = payload
						} else if atype == u16(LUCI_NDA_LLADDR) {
							mac = payload
						}
						ao += (alen + 3) & ~int(3) // 4 字节对齐
					}
					if len(mac) >= 6 && len(dst) > 0 {
						mac_text := luci_mac_text(mac, alloc)
						ip_text := luci_ip_text(af, dst, alloc)
						if len(mac_text) > 0 && len(ip_text) > 0 {
							h := luci_hint_get(hints, mac_text, alloc)
							luci_hint_add_addr(h, af, LUCI_PRIO_NL, ip_text, alloc)
						}
					}
				}
			}
			off += (msg_len + 3) & ~int(3)
		}
	}
}

// --- 来源 2/3/5：/etc/ethers、dhcp 租约、uci 静态租约 ----------------------

@(private)
luci_get_host_hints_ether :: proc(
	hints: ^map[string]^Luci_Hint,
	alloc: mem.Allocator,
) {
	data, err := os.read_entire_file("/etc/ethers", alloc)
	if err != nil {
		return // 文件不存在：直接跳过（luci.c:1434-1437）
	}
	for line in strings.split(string(data), "\n", alloc) {
		f := strings.fields(strings.trim_space(line), alloc)
		if len(f) < 1 {
			continue
		}
		mac := luci_parse_mac(f[0], alloc)
		if len(mac) == 0 {
			continue
		}
		h := luci_hint_get(hints, mac, alloc)
		if len(f) < 2 {
			continue
		}
		// 第二个字段是 v4 → 当地址加（prio 50）；否则当主机名（luci.c:1446-1456）
		if luci_valid_ip4(f[1]) {
			luci_hint_add_addr(h, 4, LUCI_PRIO_ETHER, f[1], alloc)
		} else if len(h.hostname) == 0 {
			h.hostname = strings.clone(f[1], alloc)
		}
	}
}

@(private)
luci_get_host_hints_uci :: proc(
	hints: ^map[string]^Luci_Hint,
	alloc: mem.Allocator,
) {
	// 静态租约（dhcp config 的 host section，prio 250）
	// 注意：`ip` 照抄上游**不生效**（见文件头注释 1）。
	if sections, ok := uci_config_sections("dhcp", alloc); ok {
		for s in sections {
			if s.type_name != "host" {
				continue
			}
			name := ""
			macs: []string
			for o in s.options {
				switch o.name {
				case "name":
					if len(o.values) > 0 {
						name = o.values[0]
					}
				case "mac":
					if o.is_list {
						macs = o.values
					} else if len(o.values) > 0 {
						// 单一字符串里可以有空格分隔的多个 MAC（luci.c:1523-1527）
						macs = strings.fields(o.values[0], alloc)
					}
				}
			}
			for m in macs {
				mac := luci_parse_mac(m, alloc)
				if len(mac) == 0 {
					continue
				}
				h := luci_hint_get(hints, mac, alloc)
				if len(name) > 0 && len(h.hostname) == 0 {
					h.hostname = strings.clone(name, alloc)
				}
			}
		}
	}

	// dhcp 租约文件（prio 100，luci.c:1555-1575）
	now := int(time.to_unix_seconds(time.now()))
	for f in luci_lease_files(alloc) {
		data, err := os.read_entire_file(f.path, alloc)
		if err != nil {
			continue
		}
		for e in luci_parse_leases(string(data), f.odhcpd, now, alloc) {
			if len(e.mac) == 0 {
				continue
			}
			h := luci_hint_get(hints, e.mac, alloc)
			if len(e.addr) > 0 {
				luci_hint_add_addr(h, e.af, LUCI_PRIO_LEASEFILE, e.addr, alloc)
			}
			if len(e.hostname) > 0 && len(h.hostname) == 0 {
				h.hostname = strings.clone(e.hostname, alloc)
			}
		}
	}
}

// --- 来源 4：getifaddrs（luci.c:1584-1658）--------------------------------

@(private)
luci_get_host_hints_ifaddrs :: proc(
	hints: ^map[string]^Luci_Hint,
	alloc: mem.Allocator,
) {
	ifa_start: ^bindings.Ifaddrs
	if bindings.getifaddrs(&ifa_start) != 0 || ifa_start == nil {
		return
	}
	defer bindings.freeifaddrs(ifa_start)

	// 按设备名聚合：MAC（AF_PACKET）+ 第一个 v4 + 第一个 v6
	Device :: struct {
		mac: string,
		v4:  string,
		v6:  string,
	}
	devices := make(map[string]^Device, 4, alloc)

	for ifa := ifa_start; ifa != nil; ifa = ifa.next {
		if ifa.addr == nil {
			continue
		}
		name := string(ifa.name)
		d, has := devices[name]
		if !has {
			d = new(Device, alloc)
			devices[strings.clone(name, alloc)] = d
		}
		switch ifa.addr.family {
		case 17: // AF_PACKET：sll_halen 在偏移 10（相对 sockaddr 起点 = data[9]）、
			// sll_addr 在偏移 12（= data[10]）
			halen := ifa.addr.data[9]
			if halen == 6 && len(d.mac) == 0 {
				d.mac = luci_mac_text(ifa.addr.data[10:16], alloc)
			}
		case 10: // AF_INET6：sin6_addr 在偏移 8（= data[6]）
			if len(d.v6) == 0 {
				d.v6 = luci_ip_text(6, ifa.addr.data[6:22], alloc)
			}
		case 2: // AF_INET：sin_addr 在偏移 4（= data[2]）
			if len(d.v4) == 0 {
				d.v4 = luci_ip_text(4, ifa.addr.data[2:6], alloc)
			}
		}
	}

	for _, d in devices {
		if len(d.mac) == 0 || (len(d.v4) == 0 && len(d.v6) == 0) {
			continue
		}
		h := luci_hint_get(hints, d.mac, alloc)
		if len(d.v4) > 0 {
			luci_hint_add_addr(h, 4, LUCI_PRIO_IFADDRS, d.v4, alloc)
		}
		if len(d.v6) > 0 {
			luci_hint_add_addr(h, 6, LUCI_PRIO_IFADDRS, d.v6, alloc)
		}
	}
}

// --- 收尾：rrdns（可选）+ 组装回复（luci.c:1709-1808）---------------------

@(private)
luci_hint_v6_rrdns_ok :: proc(addr: string) -> bool {
	// 非 ::（未指定）、非 link-local（fe80::/10）、非 ULA（fc00::/7）（luci.c:1731-1734）
	b: [16]u8
	if luci_addr_bytes(6, addr, &b) == 0 {
		return false
	}
	unspecified := true
	for v in b {
		if v != 0 {
			unspecified = false
			break
		}
	}
	if unspecified {
		return false
	}
	if b[0] == 0xfe && (b[1] & 0xc0) == 0x80 {
		return false
	}
	if (b[0] & 0xfe) == 0xfc {
		return false
	}
	return true
}

@(private)
luci_host_hints_json :: proc(alloc: mem.Allocator) -> (string, int) {
	hints := make(map[string]^Luci_Hint, 8, alloc)

	luci_get_host_hints_nl(&hints, alloc)
	luci_get_host_hints_uci(&hints, alloc)
	luci_get_host_hints_ether(&hints, alloc)
	luci_get_host_hints_ifaddrs(&hints, alloc)

	// rrdns 补主机名（上游同步调 network.rrdns lookup；对象不存在就跳过）
	luci_host_hints_rrdns(&hints, alloc)

	out := make(json.Object, len(hints), alloc)
	for mac, h in hints {
		luci_hint_sort(&h.v4)
		luci_hint_sort(&h.v6)

		obj := make(json.Object, 3, alloc)
		v4 := make([dynamic]json.Value, 0, len(h.v4), alloc)
		for a in h.v4 {
			append(&v4, json.Value(json.String(a.addr)))
		}
		obj["ipaddrs"] = json.Value(json.Array(v4))
		v6 := make([dynamic]json.Value, 0, len(h.v6), alloc)
		for a in h.v6 {
			append(&v6, json.Value(json.String(a.addr)))
		}
		obj["ip6addrs"] = json.Value(json.Array(v6))
		if len(h.hostname) > 0 {
			obj["name"] = json.Value(json.String(h.hostname))
		}
		out[mac] = json.Value(obj)
	}

	return session_marshal(json.Value(out), alloc), LUCI_STATUS_OK
}

// rrdns：一次 ubus 调用把「主机名」补进 hint。与 S2c 同用同步 ubus_invoke。
@(private)
g_luci_rrdns_reply: string

@(private)
luci_rrdns_data_cb :: proc "c" (req: rawptr, msg_type: c.int, msg: ^bindings.Blob_Attr) {
	context = runtime.default_context()
	if msg == nil {
		return
	}
	js := bindings.blobmsg_format_json(msg, false)
	if js == nil {
		return
	}
	defer bindings.c_free(rawptr(js))
	g_luci_rrdns_reply = strings.clone(string(js))
}

@(private)
luci_host_hints_rrdns :: proc(hints: ^map[string]^Luci_Hint, alloc: mem.Allocator) {
	ctx := g_ubus_ctx
	if ctx == nil {
		return
	}

	// 收集要查的地址（v4 全收、v6 过滤掉 link-local/ULA/未指定）
	addrs := make([dynamic]string, 0, 8, alloc)
	for _, h in hints {
		for a in h.v4 {
			append(&addrs, a.addr)
		}
		for a in h.v6 {
			if luci_hint_v6_rrdns_ok(a.addr) {
				append(&addrs, a.addr)
			}
		}
	}
	if len(addrs) == 0 {
		return
	}

	id: u32
	if bindings.ubus_lookup_id(ctx, "network.rrdns", &id) != 0 {
		return // 对象不存在（上游 invoke 失败也照样出结果）
	}

	req: bindings.Blob_Buf
	bindings.blobmsg_buf_init(&req)
	defer bindings.blob_buf_free(&req)
	arr := bindings.blobmsg_open_array(&req, "addrs")
	for a in addrs {
		_ = bindings.blobmsg_add_string(&req, nil, strings.clone_to_cstring(a))
	}
	bindings.blobmsg_close_array(&req, arr)
	_ = bindings.blobmsg_add_u32(&req, "timeout", 250)
	_ = bindings.blobmsg_add_u32(&req, "limit", u32(len(addrs)))

	g_luci_rrdns_reply = ""
	if rc := bindings.ubus_invoke_fd(ctx, id, "lookup", req.head, luci_rrdns_data_cb, nil, 1000, -1); rc != 0 {
		return
	}
	raw := g_luci_rrdns_reply
	g_luci_rrdns_reply = ""
	if len(raw) == 0 {
		return
	}

	doc: json.Value
	if err := json.unmarshal(transmute([]byte)(raw), &doc, .JSON, alloc); err != nil {
		return
	}
	obj, is_obj := doc.(json.Object)
	if !is_obj {
		return
	}

	// 回复是 {地址: 主机名}：v6 只在缺主机名时填，v4 覆盖（luci.c:1680-1701）
	for addr_key, val in obj {
		name, is_str := val.(json.String)
		if !is_str || len(name) == 0 {
			continue
		}
		for _, h in hints {
			for &a in h.v6 {
				if a.addr == addr_key {
					if len(h.hostname) == 0 {
						h.hostname = strings.clone(string(name), alloc)
					}
					break
				}
			}
			for &a in h.v4 {
				if a.addr == addr_key {
					h.hostname = strings.clone(string(name), alloc)
					break
				}
			}
		}
	}
}
