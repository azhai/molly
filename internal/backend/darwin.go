//go:build darwin

package backend

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"syscall"
)

// macOS（开发机）上的假数据实现。
//
// 目的不是模拟 ubus 语义，而是让「HTTP 层 → 路由 → JSON 信封」这条链路在没有
// 设备的情况下也能端到端验收。**它不代表设备契约**：真机形状以 `ubus list -v`
// 抓的样本为准。
//
// JSON 形状严格按上游 uhttpd 生成，见 backend.go 的契约说明。

// 下面四段是「单个对象的签名」，即 GET /ubus/list/<path> 的完整正文。
// 方法名与参数按 rpcd 提供的对象写，参数名取常见调用形态——**不是**接口文档，
// 只当结构样本用。冒号后面不留空格：CallObject 用 `"<方法名>":` 做子串判断来
// 伪造「未知方法」，格式一变那个判断就失效。
const (
	sessionSig = `{"access":{"ubus_rpc_session":"string","object":"string","function":"string","scope":"string"},` +
		`"create":{"*":"object"},` +
		`"destroy":{"ubus_rpc_session":"string"},` +
		`"exists":{"ubus_rpc_session":"string"},` +
		`"get":{"ubus_rpc_session":"string"},` +
		`"grant":{"ubus_rpc_session":"string","scope":"string","objects":"array"},` +
		`"list":{"*":"object"},` +
		`"login":{"username":"string","password":"string","timeout":"number"},` +
		`"revoke":{"ubus_rpc_session":"string","scope":"string","objects":"array"},` +
		`"set":{"ubus_rpc_session":"string","*":"object"},` +
		`"unset":{"ubus_rpc_session":"string","*":"object"},` +
		`"update":{"ubus_rpc_session":"string","*":"object"}}`

	uciSig = `{"add":{"config":"string","type":"string","*":"object"},` +
		`"changes":{"config":"string"},` +
		`"commit":{"config":"string"},` +
		`"configs":{},` +
		`"delete":{"config":"string","section":"string","option":"string"},` +
		`"get":{"config":"string","section":"string","option":"string","type":"string"},` +
		`"order":{"config":"string","sections":"array"},` +
		`"rename":{"config":"string","section":"string","option":"string","name":"string"},` +
		`"set":{"config":"string","section":"string","type":"string","values":"object"},` +
		`"state":{"config":"string","section":"string","option":"string","type":"string","default":"string"}}`

	fileSig = `{"exec":{"command":"string","params":"array","env":"object"},` +
		`"list":{"path":"string"},` +
		`"read":{"path":"string","base64":"boolean","data":"string"},` +
		`"remove":{"path":"string"},` +
		`"stat":{"path":"string"},` +
		`"write":{"path":"string","data":"string","append":"boolean","base64":"boolean","mode":"number"}}`

	luciSig = `{"getBlockInfo":{"name":"string","extended":"boolean"},` +
		`"getBoardJSON":{},` +
		`"getDHCPLeases":{},` +
		`"getInitList":{"name":"string"},` +
		`"getLocaltime":{},` +
		`"getNetworkDevices":{},` +
		`"getRealtimeStats":{},` +
		`"getTimezones":{},` +
		`"getUSBDevices":{},` +
		`"setInitAction":{"name":"string","action":"string"},` +
		`"setLocaltime":{"zonename":"string","time":"number"},` +
		`"setPassword":{"user":"string","password":"string"}}`

	// molly 自持的 luci-rpc（6 方法）。假对象表里必须有它，否则 /ubus 的
	// 「对象存在性」预检会把它判成不存在 → -32000。
	luciRPCSig = `{"getBoardJSON":{},` +
		`"getDHCPLeases":{"family":"number"},` +
		`"getDUIDHints":{},` +
		`"getHostHints":{},` +
		`"getNetworkDevices":{},` +
		`"getWirelessDevices":{}}`

	// molly.probe：linux 上由 ubus 线程真注册（方法 ping + notify）；darwin 这里
	// 放一份，让上游的 `ubus call molly.probe …` 形态在 macOS 上也能被判存在。
	probeSig = `{"notify":{},"ping":{}}`
)

// 对象路径 → 签名。顺序按路径排，模仿 ubus 的 avl 有序输出。
var fakeObjects = []struct{ path, sig string }{
	{"file", fileSig},
	{"luci", luciSig},
	{"luci-rpc", luciRPCSig},
	{"molly.probe", probeSig},
	{"session", sessionSig},
	{"uci", uciSig},
}

// GET /ubus/list 的正文：把上面几段拼进一层对象名。用常量拼接保证两个端点
// 永远一致。
const fakeList = `{"file":` + fileSig +
	`,"luci":` + luciSig +
	`,"luci-rpc":` + luciRPCSig +
	`,"molly.probe":` + probeSig +
	`,"session":` + sessionSig +
	`,"uci":` + uciSig +
	`}`

// New 返回当前平台的 provider。
func New() Backend { return darwinBackend{} }

type darwinBackend struct{}

func (darwinBackend) ListObjects(path string) (string, int, bool) {
	if path == "" {
		return fakeList, 0, true
	}
	for _, o := range fakeObjects {
		if o.path == path {
			return o.sig, 0, true
		}
	}
	// 真机上 ubus_lookup 对不存在的路径返回 StatusNotFound，handler 于是回
	// 500 + {"code":4,"message":"Not found"}，这里保持一致。
	return "", StatusNotFound, false
}

func (darwinBackend) CallObject(objPath, method, paramsJSON, sid string) CallResult {
	// molly 自有对象（session/uci/file/luci-rpc/molly.probe）走平台无关的真实现。
	// 与 linux 完全同构（同一个 callOwnObject），保证两个平台跑的是同一份 handler 逻辑。
	if reply, status, handled := callOwnObject(objPath, method, paramsJSON, sid); handled {
		if status != 0 {
			return CallResult{Outcome: OutcomeOk, Ret: status}
		}
		return CallResult{Outcome: OutcomeOk, Ret: 0, Reply: reply}
	}

	sig := ""
	for _, o := range fakeObjects {
		if o.path == objPath {
			sig = o.sig
			break
		}
	}
	if sig == "" {
		return CallResult{Outcome: OutcomeObjectNotFound}
	}
	// 方法在不在，用假数据自己的签名做子串判断就够了。真机上这个判断发生在
	// ubusd/rpcd 那边，未知方法回 StatusMethodNotFound。
	if !strings.Contains(sig, `"`+method+`":`) {
		return CallResult{Outcome: OutcomeOk, Ret: StatusMethodNotFound}
	}

	// 回显入参，用来证明 obj / method / sid / params 四个值确实传到了这一层。
	// **不是设备契约**，别照它写前端。
	p := paramsJSON
	if p == "" {
		p = "{}"
	}
	reply, err := marshalEcho(objPath, method, sid, p)
	if err != nil {
		return CallResult{Outcome: OutcomeInternal}
	}
	return CallResult{Outcome: OutcomeOk, Ret: 0, Reply: reply}
}

// echo 用结构体而不是拼字符串：字段顺序固定（object/method/sid/params），
// 且 sid 会被正确转义，不会拼出非法 JSON。
type echo struct {
	Object string          `json:"object"`
	Method string          `json:"method"`
	Sid    string          `json:"sid"`
	Params json.RawMessage `json:"params"`
}

func marshalEcho(objPath, method, sid, params string) (string, error) {
	b, err := json.Marshal(map[string]echo{"echo": {objPath, method, sid, json.RawMessage(params)}})
	if err != nil {
		return "", err
	}
	return string(b), nil
}

// ---------------------------------------------------------------------------
// 平台钩子（session.go 调用；linux.go 有同名同签名的另一份）
//
// darwin 替三样东西：
//   1. uci 数据源（菜单 depends.uci 与 /etc/config/rpcd 的 login section）
//   2. 密码校验（linux 用 /etc/shadow + crypt，macOS 上没有等价环境）
//   3. acl.d 目录（linux 是 /usr/share/rpcd/acl.d，macOS 用仓库 fixture）
// ---------------------------------------------------------------------------

type fakeConfig struct {
	name     string
	sections []UciSection
}

// fakeUCI 模拟一台「配了 network 的 lan/wan/wg0、system 的 ntp」的设备，让
// depends.uci 的每种形态都能在 macOS 上被断言到——config 有 section、具名 section、
// 匿名 section 按 `@<type>` 匹配、option 值精确匹配、以及「config 存在但没有 section」。
//
// **不是设备契约**：真机取值来自 /etc/config（M5 验证）。
var fakeUCI = []fakeConfig{
	{
		name: "network",
		sections: []UciSection{
			{
				Name:     "lan",
				TypeName: "interface",
				Options: []UciOption{
					{Name: "proto", Values: []string{"static"}},
					{Name: "ifname", Values: []string{"br-lan"}},
					{Name: "ipaddr", Values: []string{"192.168.1.1"}},
				},
			},
			{Name: "wan", TypeName: "interface", Options: []UciOption{{Name: "proto", Values: []string{"dhcp"}}}},
			{Name: "wg0", TypeName: "interface", Options: []UciOption{{Name: "proto", Values: []string{"wireguard"}}}},
			// 匿名 section（真机上的 network.@switch[0]）：名字为空，只能按 @type 匹配
			{
				Name:      "",
				TypeName:  "switch",
				Anonymous: true,
				Options:   []UciOption{{Name: "name", Values: []string{"switch0"}}},
			},
		},
	},
	{
		name: "system",
		sections: []UciSection{
			{
				Name:     "ntp",
				TypeName: "timeserver",
				Options: []UciOption{
					{Name: "enabled", Values: []string{"1"}},
					{Name: "server", IsList: true, Values: []string{"0.openwrt.pool.ntp.org", "1.openwrt.pool.ntp.org"}},
				},
			},
		},
	},
	// 存在但没有 section 的 config：上游 `true` 形态必须判**不**满足
	{name: "empty-config"},
	// login 契约来自 /etc/config/rpcd 的 login section（session.c:855-924）。真机默认就是
	// `option username 'root'` + `option password '$p$root'`，这里照抄一份，好让 login 的
	// 成功/失败分支都能在 macOS 上被断言。
	{
		name: "rpcd",
		sections: []UciSection{
			{
				Name:     "login",
				TypeName: "login",
				Options: []UciOption{
					{Name: "username", Values: []string{"root"}},
					{Name: "password", Values: []string{"$p$root"}},
					{Name: "read", IsList: true, Values: []string{"*"}},
					{Name: "write", IsList: true, Values: []string{"*"}},
				},
			},
		},
	},
	// getDHCPLeases 的 leasefile 发现走 uci `dhcp` config（M4 用）。
	{
		name: "dhcp",
		sections: []UciSection{
			{
				Name:     "dnsmasq",
				TypeName: "dnsmasq",
				Options:  []UciOption{{Name: "leasefile", Values: []string{"/tmp/molly-dhcp.leases"}}},
			},
			{
				Name:     "odhcpd",
				TypeName: "odhcpd",
				Options:  []UciOption{{Name: "leasefile", Values: []string{"/tmp/molly-odhcpd.leases"}}},
			},
		},
	},
}

func uciConfigSections(config string) ([]UciSection, bool) {
	for _, c := range fakeUCI {
		if c.name == config {
			return c.sections, true
		}
	}
	return nil, false
}

// sessionVerifyPassword 的假凭据约定（session 的断言按这个来）：
//
//	"$p$root"（真机默认配置的写法） → 密码必须是 "test1234"
//	空 hash                        → 任何密码都通过
//	其它                           → 明文相等才算通过
func sessionVerifyPassword(hash, password string) bool {
	if len(hash) == 0 {
		return true
	}
	if hash == "$p$root" {
		return password == "test1234"
	}
	return hash == password
}

// sessionACLDir：真机是 /usr/share/rpcd/acl.d（session.h 的 RPC_SESSION_ACL_DIR）；
// darwin 用仓库 fixture。fixture 不在 molly/ 下，相对路径不可靠，所以 GOMOLLY_ACL_DIR
// 可以覆盖（tests/smoke.sh 会设成绝对路径）。
func sessionACLDir() string {
	if d := os.Getenv("GOMOLLY_ACL_DIR"); d != "" {
		return d
	}
	return filepath.Join("tests", "fixtures", "acl.d")
}

// fileStatMeta 是 file_object.go 的 fileStatJSON 用的平台钩子：stat 的 atime/ctime
// （秒）与 inode（截到 u32），对齐 Odin file_stat_dump_json（file_object.odin:355-358）。
// darwin 的 Stat_t 字段名是 Atimespec/Ctimespec/Ino。
func fileStatMeta(info os.FileInfo) (atime, ctime, inode int64) {
	st, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		mt := info.ModTime().Unix()
		return mt, mt, 0
	}
	return st.Atimespec.Sec, st.Ctimespec.Sec, int64(uint32(st.Ino))
}

// UciConfigSections / SessionACLLevel 是 Backend 接口在 darwin 上的实现。
func (darwinBackend) UciConfigSections(config string) ([]UciSection, bool) {
	return uciConfigSections(config)
}

func (darwinBackend) SessionAccessUbus(sid, object, function string) bool {
	return SessionAccessUbus(sid, object, function)
}

func (darwinBackend) SessionSelfService(sid, method string) bool {
	return SessionSelfService(sid, method)
}

// sseWatchStart / sseWatchStop：darwin 没有 ubusd，事件由 `molly.probe` 的 `notify`
// 直接 Publish，所以平台侧无事可做（对应 Odin darwin.odin 的空实现）。
func sseWatchStart(string) bool { return true }
func sseWatchStop(string)       {}

func (darwinBackend) SessionACLLevel(sid string, groups []string) ACLLevel {
	return SessionACLLevel(sid, groups)
}

// SetUbusSocket / StartServer：macOS 上没有 ubusd，也没有要注册的对象，两者都是空操作
// （linux.go 有同名同签名的另一份，行为见那里）。
func SetUbusSocket(string) {}

func StartServer(string) int { return 0 }

// SetSessionOnBus：macOS 上没有总线可接，桥接态恒不成立（空操作）。
func SetSessionOnBus(bool) {}

// EnsureDeps：macOS 没有 ubusd / rpcd，也没有总线可探，空操作（linux.go 有另一份）。
func EnsureDeps() {}
