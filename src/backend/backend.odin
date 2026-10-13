package backend

// backend —— 平台无关的 ubus 能力接缝（逐段对齐 internal/backend/backend.go + internal_objects.go）。
//
// 本文件收三件事：
//   1. ubus 状态码 + 文案表（enum ubus_msg_status，抄 libubus.c 的 __ubus_strerror）；
//   2. 跨层数据形状：Call_Outcome / Call_Result / Uci_Section / Uci_Option / ACL_Level；
//   3. 入站派发：shim.c 的 molly_ubus_handler 回调 @(export) mollyGoHandle，
//      把 (obj, method, params_json) 路由到注册的自有对象，回复以 C malloc 串交回 shim（shim free）。
//
// 与 Go 版的差异：Go 靠 cgo //export 自动桥接；Odin 这里手写 @(export) 边界。
// mollyGoHandle 是 "c contextless"（由 ubus 线程从 C 调入，无 Odin 运行期 context），
// 故所有内存走显式 alloc 参数 + libc.malloc（回复缓冲必须能被 C free() 回收）。

import "core:fmt"
import "core:mem"
import "core:c"
import "core:c/libc"
import "base:runtime"

// ---------------------------------------------------------------------------
// ubus 状态码：enum ubus_msg_status（ubusmsg.h:120-136）。下标即返回值。
// ---------------------------------------------------------------------------

Status_OK                 :: 0
Status_Invalid_Command    :: 1
Status_Invalid_Argument   :: 2
Status_Method_Not_Found   :: 3
Status_Not_Found          :: 4
Status_No_Data            :: 5
Status_Permission_Denied  :: 6
Status_Timeout            :: 7
Status_Not_Supported      :: 8
Status_Unknown_Error      :: 9
Status_Connection_Failed  :: 10
Status_No_Memory          :: 11
Status_Parse_Error        :: 12
Status_System_Error       :: 13

// 文案逐字抄 libubus.c 的 __ubus_strerror（libubus.c:26-41）。
status_text := [14]string{
	"Success",
	"Invalid command",
	"Invalid argument",
	"Method not found",
	"Not found",
	"No response",
	"Permission denied",
	"Request timed out",
	"Operation not supported",
	"Unknown error",
	"Connection failed",
	"Out of memory",
	"Parsing message data failed",
	"System error",
}

// Ubus_Error_Message —— 复刻 libubus 的 ubus_strerror。
// 不直接链 libubus 是为了让 darwin 假实现给出同一条文案（文案是协议表面的一部分）。
Ubus_Error_Message :: proc(code: i32) -> string {
	if code >= 0 && code < i32(len(status_text)) {
		return status_text[code]
	}
	// 上游 out 分支：sprintf(err, "Unknown error: %d", error)
	return fmt.tprintf("Unknown error: %d", code)
}

// ---------------------------------------------------------------------------
// 跨层数据形状
// ---------------------------------------------------------------------------

// Call_Outcome 是一次 ubus 方法调用的结局类别（对应 CallResult.Outcome）。
Call_Outcome :: enum {
	Ok,              // 调用跑完；Ret 是返回码（0 成功，非 0 是 Status_*）
	Object_Not_Found, // ubus_lookup_id 找不到对象 → handler 回 -32000
	Internal,        // 本机故障（连不上/内存不够/发不出去）→ handler 回 -32603
}

// Call_Result 是一次 ubus 方法调用的原始结果（不含 JSON-RPC 信封，那是 handler 的事）。
Call_Result :: struct {
	outcome: Call_Outcome,
	ret:     i32,    // 仅 outcome == .Ok 时有意义
	reply:   string, // 仅 outcome == .Ok 且 ret == 0 时有意义；"" 表示无回复数据
}

// Uci_Option / Uci_Section 是 uci 配置数据的形状（菜单 depends.uci 的唯一数据源）。
Uci_Option :: struct {
	name:   string,
	is_list: bool,     // list 型 → ucode 里 sval 恒为数组
	values: []string,  // is_list == false 时恒 1 个元素
}

Uci_Section :: struct {
	name:      string,
	type_name: string,   // ucode 里的 s['.type']
	anonymous: bool,      // 匿名 section（@<type>）的 name 为 ""
	options:   []Uci_Option,
}

// ACL_Level 是 depends.acl 的三态判定（对齐上游 check_acl_depends）。
ACL_Level :: enum {
	Missing,    // 有组一个都没拿到 → 节点裁掉 / 403
	Read_Only,  // 全组都只有 read → 节点可见但只读
	Writable,   // 至少一组拿到 write → 正常
}

// ---------------------------------------------------------------------------
// 入站派发：对象注册表 + mollyGoHandle
// ---------------------------------------------------------------------------

// Object_Handler 是一个自有对象的入站处理：拿到 (method, params_json)，回 (状态码, 回复 JSON)。
// 回复串用 alloc 构造；所有权在返回时移交（mollyGoHandle 会拷进 C malloc 缓冲，注册表本身不持有）。
Object_Handler :: proc(method, params_json: string, alloc: mem.Allocator) -> (status: i32, reply: string)

object_registry :: struct {
	alloc:   mem.Allocator,
	objects: map[string]Object_Handler,
	ready:   bool,
}

reg: object_registry

// ensure_registry —— 首次用到时建表。注册表跨请求长生命周期 → 绑进程默认分配器，
// **绝不能**用调用方传入的 alloc（那可能是某请求/某入站调用的 arena，返回即回收）。
ensure_registry :: proc(_alloc: mem.Allocator) {
	if reg.ready {
		return
	}
	reg.alloc = runtime.default_allocator()
	reg.objects = make(map[string]Object_Handler, 0, reg.alloc)
	reg.ready = true
	register_builtin_objects()
}

// Register_Object —— 注册一个自有对象（s3c~s3f 的 session/uci/file/luci-rpc 由此接入）。
Register_Object :: proc(alloc: mem.Allocator, path: string, h: Object_Handler) {
	ensure_registry(alloc)
	reg.objects[path] = h
}

// Dispatch —— 入站调用的纯 Odin 核心（可单测，不碰 C ABI）。
// obj 未注册 → Status_Not_Supported（shim 只会把已注册的 molly 对象转发进来，走到这里说明漏注册）。
Dispatch :: proc(alloc: mem.Allocator, obj, method, params_json: string) -> (status: i32, reply: string) {
	ensure_registry(alloc)
	if h := reg.objects[obj]; h != nil {
		return h(method, params_json, alloc)
	}
	return Status_Not_Supported, ""
}

// mollyGoHandle —— shim.c 的 molly_ubus_handler 回调目标（C 侧声明见 shim.c:25-26）。
//
// extern int mollyGoHandle(const char *obj, const char *method,
//                          const char *params_json, char **reply_out);
//
// 契约：status != 0 时 shim **不** send_reply，把状态码交回 libubus；
// status == 0 且有回复时，*reply_out 收一块 C malloc 串（shim 侧 free()）。
//
// "c"：由 ubus 线程从 C 调入（C ABI）；C 不给 Odin 运行期 context，故进入即自建
// default_context + 默认分配器。回复缓冲必须用 libc.malloc 造（交回 shim 后由 C free 回收）。
@(export)
mollyGoHandle :: proc "c" (
	obj, method, params_json: cstring,
	reply_out: ^cstring,
) -> (code: i32) {
	context = runtime.default_context()
	// 每入站调用一个动态 arena：handler 的临时解析/构造都落这里，返回即整体回收。
	// 要长期存的东西（会话数据）由对象自己拷进 store_alloc；回复下面先拷进 libc.malloc 再销毁 arena。
	da: mem.Dynamic_Arena
	mem.dynamic_arena_init(&da, runtime.default_allocator(), runtime.default_allocator())
	defer mem.dynamic_arena_destroy(&da)
	context.allocator = mem.dynamic_arena_allocator(&da)

	o := obj != nil ? string(obj) : ""
	m := method != nil ? string(method) : ""
	p := params_json != nil ? string(params_json) : ""

	status, reply := Dispatch(context.allocator, o, m, p)
	if status == 0 && len(reply) > 0 {
		n := len(reply)
		buf := libc.malloc(c.size_t(n + 1))
		if buf == nil {
			return Status_No_Memory
		}
		dst := cast([^]u8)buf
		for i := 0; i < n; i += 1 {
			dst[i] = reply[i]
		}
		dst[n] = 0
		reply_out^ = cstring(dst)
	}
	return status
}

// ---------------------------------------------------------------------------
// 内置对象：molly.probe（唯一的平台无关探针；证明 event_bus + 派发接线，s3c~s3f 之前先立骨架）
// ---------------------------------------------------------------------------

register_builtin_objects :: proc() {
	reg.objects["molly.probe"] = probe_handler
	reg.objects["session"] = session_handler
	reg.objects["uci"] = uci_handler
	reg.objects["file"] = file_handler
	reg.objects["luci-rpc"] = luci_handler
}

probe_handler :: proc(method, params_json: string, alloc: mem.Allocator) -> (status: i32, reply: string) {
	switch method {
	case "ping":
		return Status_OK, `{"pong":"molly"}`
	case "notify":
		// linux 上是 ubus_notify(ctx, &molly.probe, "ping", …)；进程内等价物是往总线推一条
		// ——订阅者收到的帧同形（event: ping + {"hello":"world"}）。
		Publish("molly.probe", "ping", `{"hello":"world"}`)
		return Status_OK, `{"notified":"molly.probe"}`
	}
	return Status_Method_Not_Found, ""
}
