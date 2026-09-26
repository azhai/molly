// Package backend —— 平台相关的 ubus 访问层（uci 待第 6 步之后的 dispatcher 用到再接）。
//
// 分层方式（计划决策 2）：build tag + 同名 proc，**不引入 vtable**。
// 只有两个实现，共享层直接调 `backend.list_objects` / `backend.call_object` 就行；
// 签名漂移会在编译期暴露，因为 macOS 上每次构建走的都是 darwin 那一份。
//
//   linux.odin   `#+build linux`  —— 真 libubus / libblobmsg_json / libubox
//   darwin.odin  `#+build darwin` —— 假数据，让 HTTP / 路由 / JSON 在 macOS 上跑通
//
// Odin 不允许「只声明不实现」的 proc，所以本文件不写 proc 声明，只放跨平台契约的
// 说明、共享的常量/类型，以及两边都会用的纯函数。
//
// ---------------------------------------------------------------------------
// list_objects(path, alloc) -> (json, err, ok)
//
// GET /ubus/list 与 GET /ubus/list/<path> 的响应正文（Content-Type: application/json）。
//
//   path == ""   → 列全部对象：
//                  {"<对象路径>": {"<方法名>": {"<参数名>": "<类型>"}, …}, …}
//   path != ""   → 只列该对象，**不带外层对象名**：
//                  {"<方法名>": {"<参数名>": "<类型>"}, …}
//
// <类型> 只允许六个取值：boolean / number / string / array / object / unknown。
// 这是上游 uhttpd `uh_ubus_list_cb` 的逐字映射（`ubus.c:630-649`），不是自创。
//
// ok == false 时 err 是 ubus 侧的错误码（真机上就是 `ubus_lookup` 的返回值，
// 例如对象不存在 = UBUS_STATUS_NOT_FOUND），handler 负责转成
// 500 + {"code":err,"message":ubus_error_message(err)}（上游 `ubus.c:249-253`）。
//
// ---------------------------------------------------------------------------
// call_object(obj_path, method, params_json, sid, alloc) -> Call_Result
//
// 一次 ubus 方法调用的原始结果。**不含** JSON-RPC 信封：信封（jsonrpc/id/result/
// error 的组装、-32700/-32600/-32601/-32602 这些纯协议错误）是 handler 的事，
// 见 src/handlers/ubus_http.odin。
//
//   params_json  handler 重新序列化过的 params 值（JSON object 文本，或 "" 表示没
//                有 params）。真机上它会被 blobmsg_add_json_from_string 展开成
//                blobmsg table——与上游 uh_ubus_send_request 逐个 blobmsg_add_blob
//                得到的结果等价（`blobmsg_add_object` 就是平铺键值，不套外层）。
//   sid          会话 id，作为 `ubus_rpc_session` 追加进请求。
//
// 各字段语义见 Call_Outcome / Call_Result。
//
// alloc 由调用方给（handler 传每请求 arena），返回的 string 生命周期同之；
// 两个实现都不得返回需要调用方 free 的堆内存。
//
// ---------------------------------------------------------------------------
// uci_config_sections(config, alloc) -> (sections: []Uci_Section, ok: bool)
//
// --- P3-3（S2）新增的 delta / savedir 契约 ---
// uci_set_savedir(sid) -> bool
//   把 uci 的 delta 保存目录切到本会话的目录（RPC_UCI_SAVEDIR_PREFIX "<sid>"，
//   即 /var/run/rpcd/uci-<sid>）；sid 为空时用 "/tmp/.uci"（rpcd uci.c:288-303）。
//   linux：真调用；darwin：空实现（假数据没有 delta 存储，返回 true 让读路径照常跑）。
// uci_state_sections(config, alloc) -> (sections: []Uci_Section, status: int)
//   `state` 方法专用：savedir 切到 "/var/state"（已提交态）后加载（uci.c:619-620）。
//   status 是 ubus 状态码：0 成功、4 不存在、8 该平台不支持（darwin）。
// uci_delta_changes(config, alloc) -> (changes: []Uci_Change, status: int)
//   `changes` 方法的数据源（p->saved_delta，uci.c:1250-1251 / :1281-1289）。
//   darwin 返回一组固定的假 delta（tests/fixtures 的约定），linux 真枚举。
// uci_commit(config, alloc) -> int
// uci_revert(config, alloc) -> int
//   提交/丢弃该 config 的 delta，返回 ubus 状态码（uci.c:1324-1379）。
//   darwin 两者都回 8（NOT_SUPPORTED）：按决策，写路径只在 linux 上实现。
// 注意：`uci_set_savedir` 是**每次调用**都要做的（上游在 read/write_access 里做，
// 见 uci.c:311-337），所以 get/changes/... 每个方法入口都先调它。
//
// 菜单 `depends.uci` 的**唯一**数据来源（src/luci/menu.odin 的 check_uci_depends）。
// 上游 ucode 是 `uci.load(conf)` + `uci.foreach` / `uci.get_all`（`dispatcher.uc:236-264`），
// 这里一次交出一个 config 的全部 section，**判定逻辑留在 src/luci**——与上游同层。
//
//   ok == false             config 读不到（不存在 / 解析失败）；调用方按「0 个 section」
//                           处理，与上游 `uci.load` 失败后 foreach 找不到东西等价
//   Uci_Section.name        具名 section 的名字；匿名 section（`@<type>`）是 ""
//   Uci_Section.type_name   ucode 里的 `s['.type']`（options 为字符串时用它比对，:199-201）
//   Uci_Section.anonymous   与 C 结构体同义，仅供信息展示
//   Uci_Option.is_list      uci 的 list 型 → ucode 里 `sval` 是数组（哪怕只有一个元素）
//   Uci_Option.values       is_list == false 时恒 1 个元素
//
// 两个实现都不得返回需要调用方 free 的堆内存；字符串生命周期与 alloc 相同。
//
// ---------------------------------------------------------------------------
// start_ubus_server() -> bool
//
// P3-1（ADR `.ai-agents/adr/0001-ubus-uloop-thread.md`）：起一个**专用线程**跑 uloop，
// 并用它自己的 ubus context 注册 molly 提供的对象（P3-2…P3-5 是
// session / uci / file / luci；现在只有探针对象 `molly.probe`，用来证明这条路通）。
//
//   true    线程已起来（连接与注册结果由该线程自己打日志）
//   false   本平台没有 ubus（darwin）或线程创建失败——HTTP 服务不受影响，
//           只是 molly 不提供 ubus 对象（过渡期行为，P2 决策 7）
//
// 为什么单独一个 ctx、单独一个线程：libubus 非线程安全，且 uloop_run 会阻塞；
// HTTP 线程继续在自己的 client ctx 上做同步 invoke（linux.odin 的 g_ctx）。
package backend

import "core:fmt"
import "core:mem"

// ---------------------------------------------------------------------------
// ubus 状态码与错误文案
// ---------------------------------------------------------------------------

// enum ubus_msg_status（/Users/ryan/openwrt-sdks/src/ubus/ubusmsg.h:120-136）
UBUS_STATUS_OK                :: 0
UBUS_STATUS_INVALID_COMMAND   :: 1
UBUS_STATUS_INVALID_ARGUMENT  :: 2
UBUS_STATUS_METHOD_NOT_FOUND  :: 3
UBUS_STATUS_NOT_FOUND         :: 4
UBUS_STATUS_NO_DATA           :: 5
UBUS_STATUS_PERMISSION_DENIED :: 6
UBUS_STATUS_TIMEOUT           :: 7
UBUS_STATUS_NOT_SUPPORTED     :: 8
UBUS_STATUS_UNKNOWN_ERROR     :: 9
UBUS_STATUS_CONNECTION_FAILED :: 10
UBUS_STATUS_NO_MEMORY         :: 11
UBUS_STATUS_PARSE_ERROR       :: 12
UBUS_STATUS_SYSTEM_ERROR      :: 13

// libubus.c:26-41 的 __ubus_strerror 表，逐字抄下来。
@(private)
UBUS_STATUS_TEXT := [14]string{
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

// libubus.c:60-75 的 ubus_strerror()，一处实现两个平台共用。
//
// 不直接调 libubus 的 ubus_strerror 是为了让 darwin 的假实现给出**同一条**文案
// （它 `#+build darwin`，链不到 libubus）；文案本身是我们要复刻的协议表面的一部分，
// 抄成常量后两边不可能各自漂移。另外上游那个实现用的是一个 static char[32] 缓冲区，
// 在「一连接一线程」下并不安全；这里改成写进调用方的 arena。
ubus_error_message :: proc(code: int, alloc: mem.Allocator) -> string {
	if code >= 0 && code < len(UBUS_STATUS_TEXT) {
		return UBUS_STATUS_TEXT[code]
	}
	// 上游的 out 分支：sprintf(err, "Unknown error: %d", error)
	return fmt.aprintf("Unknown error: %d", code, allocator = alloc)
}

// ---------------------------------------------------------------------------
// 调用结果
// ---------------------------------------------------------------------------

Call_Outcome :: enum {
	// ubus 调用跑完了。ret 是返回码：0 成功，非 0 是远端/总线的错误码
	// （UBUS_STATUS_*），handler 回 error{code:ret, message:ubus_error_message(ret)}。
	Ok,
	// ubus_lookup_id 找不到对象 → handler 回 -32000 Object not found
	// （上游 uh_ubus_call 的 ERROR_OBJECT，`ubus.c:885-888`）。
	Object_Not_Found,
	// 本机故障：ctx 连不上 / 内存不够 / 请求发不出去 → handler 回 -32603 Internal error
	// （上游 ubus_invoke_async 失败那条分支，`ubus.c:588-590`）。
	Internal,
}

Call_Result :: struct {
	outcome: Call_Outcome,
	// 仅 outcome == .Ok 时有意义
	ret: int,
	// 仅 outcome == .Ok 且 ret == 0 时有意义。
	//   ""    没有回复数据（上游回 `"result": null`）
	//   "{…}" 回复表，可直接当 JSON 片段拼进响应
	reply: string,
}

// ---------------------------------------------------------------------------
// uci 数据结构（契约见本文件顶部）
// ---------------------------------------------------------------------------

// uci 的 pending change（i.e. delta）。`changes` 方法把它渲染成
// ["<type>", "<section>", "<name>?", "<value>?"]（rpcd uci.c:1189-1222）。
// type 字符串与 enum 的对应：Add="add"、Remove="remove"、Change="set"、
// Rename="rename"、Reorder="order"、List_Add="list-add"、List_Del="list-del"。
Uci_Change_Kind :: enum {
	Add,
	Remove,
	Change,
	Rename,
	Reorder,
	List_Add,
	List_Del,
}

Uci_Change :: struct {
	kind:    Uci_Change_Kind,
	section: string,
	// 没名字时是空串（上游只在 d->e.name 非空时才加这一项）
	name:    string,
	// 空串 = 上游不加 value 项（`order` 例外：value 是序号）
	value:   string,
}

Uci_Option :: struct {
	name:    string,
	is_list: bool,
	values:  []string,
}

Uci_Section :: struct {
	name:      string,
	type_name: string,
	anonymous: bool,
	options:   []Uci_Option,
}