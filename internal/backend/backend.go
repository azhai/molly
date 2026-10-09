// Package backend —— 平台相关的 ubus 访问层，是 molly 的能力接缝（capability seam）。
//
// 与 Odin 版 molly 的 src/backend 一一对应，两个 provider：
//
//	linux.go   //go:build linux   真 libubus / libblobmsg_json / libubox（M5 接 cgo）
//	darwin.go  //go:build darwin  假数据，让 HTTP / 路由 / JSON 信封在 macOS 上跑通
//
// 两个文件提供同一个 Backend 接口和同名 New()：签名漂移会在编译期暴露，
// 与 Odin 版「同名 proc、按平台选实现」语义等价，改用 interface 更合 Go 习惯。
//
// ---------------------------------------------------------------------------
// ListObjects(path) -> (jsonText, errCode, ok)
//
// GET /ubus/list 与 GET /ubus/list/<path> 的响应正文（Content-Type: application/json）。
//
//	path == ""   列全部对象：{"<对象路径>":{"<方法>":{"<参数>":"<类型>"},…},…}
//	path != ""   只列该对象，**不带外层对象名**：{"<方法>":{"<参数>":"<类型>"},…}
//
// <类型> 只有六个取值：boolean / number / string / array / object / unknown。
// ok == false 时 errCode 是 ubus 侧状态码（真机上是 ubus_lookup 的返回值，
// 例如对象不存在 = StatusNotFound），由 handler 转成
// 500 + {"code":errCode,"message":UbusErrorMessage(errCode)}。
//
// ---------------------------------------------------------------------------
// CallObject(objPath, method, paramsJSON, sid) -> CallResult
//
// 一次 ubus 方法调用的原始结果。**不含** JSON-RPC 信封：信封（jsonrpc/id/result/
// error 的组装、-32700/-32600/-32601/-32602 这些纯协议错误）是 handler 的事，
// 见 internal/handlers/ubus.go。
//
//	paramsJSON  handler 重排过的 params（JSON object 文本，或 "" 表示没有 params）。
//	            真机上它会被 blobmsg_add_json_from_string 展开成 blobmsg table。
//	sid         会话 id，作为 ubus_rpc_session 追加进请求。
//
// 各字段语义见 CallResult。
package backend

import "fmt"

// ubus 状态码：enum ubus_msg_status（ubusmsg.h:120-136）。
const (
	StatusOK               = 0
	StatusInvalidCommand   = 1
	StatusInvalidArgument  = 2
	StatusMethodNotFound   = 3
	StatusNotFound         = 4
	StatusNoData           = 5
	StatusPermissionDenied = 6
	StatusTimeout          = 7
	StatusNotSupported     = 8
	StatusUnknownError     = 9
	StatusConnectionFailed = 10
	StatusNoMemory         = 11
	StatusParseError       = 12
	StatusSystemError      = 13
)

// 文案表逐字抄 libubus.c 的 __ubus_strerror（libubus.c:26-41）。下标即状态码。
var statusText = [14]string{
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

// UbusErrorMessage 复刻 libubus 的 ubus_strerror。
//
// 不直接调 libubus 是为了让 darwin 假实现给出**同一条**文案（它链不到 libubus）：
// 文案本身是协议表面的一部分，抄成常量后两个平台不可能各自漂移。
func UbusErrorMessage(code int) string {
	if code >= 0 && code < len(statusText) {
		return statusText[code]
	}
	// 上游的 out 分支：sprintf(err, "Unknown error: %d", error)
	return fmt.Sprintf("Unknown error: %d", code)
}

// CallOutcome 见 CallResult。
type CallOutcome int

const (
	// OutcomeOk：ubus 调用跑完了。Ret 是返回码（0 成功，非 0 是 UBUS_STATUS_*）。
	OutcomeOk CallOutcome = iota
	// OutcomeObjectNotFound：ubus_lookup_id 找不到对象 → handler 回 -32000。
	OutcomeObjectNotFound
	// OutcomeInternal：本机故障（连不上 / 内存不够 / 发不出去）→ handler 回 -32603。
	OutcomeInternal
)

// CallResult 是一次 ubus 方法调用的原始结果。
type CallResult struct {
	Outcome CallOutcome
	// 仅 OutcomeOk 时有意义。
	Ret int
	// 仅 OutcomeOk 且 Ret == 0 时有意义。
	//   ""    没有回复数据（Rest 形态回 "result": null）
	//   "{…}" 回复表，可直接当 JSON 片段拼进响应
	Reply string
}

// UciOption / UciSection 是 uci 配置数据的形状，对应 Odin 版 backend.odin 的同名契约。
//
// 菜单 depends.uci 的唯一数据来源（src/luci/menu.odin 的 check_uci_depends）：
// 一次交出一个 config 的全部 section，判定逻辑留在 internal/luci。
//
//	IsList           uci 的 list 型 → ucode 里 sval 是数组（哪怕只有一个元素）
//	Values           IsList == false 时恒 1 个元素
//	TypeName         ucode 里的 `s['.type']`（options 为字符串时用它比对）
//	Anonymous        匿名 section（`@<type>`）的 Name 是 ""
type UciOption struct {
	Name   string
	IsList bool
	Values []string
}

type UciSection struct {
	Name      string
	TypeName  string
	Anonymous bool
	Options   []UciOption
}

// ACLLevel 是 `depends.acl` 的三态判定结果，对齐上游 check_acl_depends
// （dispatcher.uc:312-331）与 Odin 版 backend.session_acl_level：
//
//	ACLWritable 要求的组里至少一个拿到 write → 正常
//	ACLReadOnly 全组都只有 read                  → 节点可见但只读
//	ACLMissing  有组一个都没拿到                 → 节点裁掉 / 403
type ACLLevel int

const (
	ACLMissing ACLLevel = iota
	ACLReadOnly
	ACLWritable
)

// Backend 是 ubus 访问的接缝。handler 只依赖这个接口，不依赖任何平台库。
type Backend interface {
	ListObjects(path string) (jsonText string, errCode int, ok bool)
	CallObject(objPath, method, paramsJSON, sid string) CallResult
	// UciConfigSections 是菜单 depends.uci 的数据源（见 UciSection）。
	UciConfigSections(config string) ([]UciSection, bool)
	// SessionACLLevel 给出 sid 对 depends.acl 列出的组的权限档位。
	SessionACLLevel(sid string, groups []string) ACLLevel
	// SessionAccessUbus 是 HTTP 侧的前置 ACL 校验（uhttpd 的 uh_ubus_allowed）：
	// sid 对 scope="ubus"、object=对象名、function=方法名 是否有权限。fail-closed。
	SessionAccessUbus(sid, object, function string) bool
	// SessionSelfService 报告 sid 能否对**自己**的会话直接调 session 的
	// get/set/unset/destroy（uhttpd 那道自服务例外，不走 ubus scope 的 ACL）。
	// 桥接态（会话归总线上的 rpcd）下实现按 sid 形态放行，真正的有效性交给
	// 被转发的 rpcd session 对象兜底。
	SessionSelfService(sid, method string) bool
}
