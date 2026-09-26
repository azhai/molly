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
	_ = bindings.uloop_run_timeout(-1)
	fmt.eprintln("[molly] ubus 服务线程：事件循环退出，molly 不再提供 ubus 对象")
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
