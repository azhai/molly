#+build darwin
package backend

// macOS（开发机）上的假数据实现。
//
// 目的不是模拟 ubus 语义，而是让「HTTP 层 → 路由 → JSON 正文」这条链路在没有
// 设备的情况下也能端到端验收。**它不代表设备契约**：真机形状以 `ubus list -v`
// 抓的样本为准（风险 R7）。
//
// JSON 形状严格按上游 uhttpd 生成，见 backend.odin 的契约说明。

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:strings"

// 下面四段是「单个对象的签名」，即 GET /ubus/list/<path> 的完整正文。
// 方法名与参数按 rpcd 提供的四个对象（session / uci / file / luci）写，
// 参数名取常见调用形态——但不要拿它当接口文档，只当结构样本用。
//
// 注意：冒号后面不留空格。call_object 用 `"<方法名>":` 做子串判断来伪造
// 「未知方法」这个错误分支，格式一变那个判断就失效。

SESSION_SIG :: `{"access":{"ubus_rpc_session":"string","object":"string","function":"string","scope":"string"},` +
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

UCI_SIG :: `{"add":{"config":"string","type":"string","*":"object"},` +
	`"changes":{"config":"string"},` +
	`"commit":{"config":"string"},` +
	`"configs":{},` +
	`"delete":{"config":"string","section":"string","option":"string"},` +
	`"get":{"config":"string","section":"string","option":"string","type":"string"},` +
	`"order":{"config":"string","sections":"array"},` +
	`"rename":{"config":"string","section":"string","option":"string","name":"string"},` +
	`"set":{"config":"string","section":"string","type":"string","values":"object"},` +
	`"state":{"config":"string","section":"string","option":"string","type":"string","default":"string"}}`

FILE_SIG :: `{"exec":{"command":"string","params":"array","env":"object"},` +
	`"list":{"path":"string"},` +
	`"read":{"path":"string","base64":"boolean","data":"string"},` +
	`"remove":{"path":"string"},` +
	`"stat":{"path":"string"},` +
	`"write":{"path":"string","data":"string","append":"boolean","base64":"boolean","mode":"number"}}`

LUCI_SIG :: `{"getBlockInfo":{"name":"string","extended":"boolean"},` +
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

// 对象路径 → 签名。顺序按路径排，模仿 ubus 的 avl 有序输出。
@(private)
// P3-5 起 molly 自持 luci-rpc（6 方法）。假对象表里必须有它，否则 /ubus 的
// 「对象存在性」预检（P3-6 的 ACL 前一步）会把它判成不存在 → -32000。
LUCI_RPC_SIG :: `{"getBoardJSON":{},` +
	`"getDHCPLeases":{"family":"number"},` +
	`"getDUIDHints":{},` +
	`"getHostHints":{},` +
	`"getNetworkDevices":{},` +
	`"getWirelessDevices":{}}`

// P3-7/P3-9：`molly.probe` 在 linux 上由 ubus 线程真注册（方法 `ping` + `notify`）。
// darwin 这里也放一份，`notify` 直接推事件总线（没有 ubusd 可发），于是
// `/ubus/subscribe` 的 SSE 链路在 macOS 上也能被端到端驱动——两个平台用**同一条命令**
// （`ubus call molly.probe notify` / `POST /ubus/call/molly.probe method=notify`）。
PROBE_SIG :: `{"notify":{},"ping":{}}`

FAKE_OBJECTS :: [?]struct {
	path: string,
	sig:  string,
}{
	{"file", FILE_SIG},
	{"luci", LUCI_SIG},
	{"luci-rpc", LUCI_RPC_SIG},
	{"molly.probe", PROBE_SIG},
	{"session", SESSION_SIG},
	{"uci", UCI_SIG},
}

// GET /ubus/list 的正文：把上面几段拼进一层对象名。用常量拼接（不是运行期
// 拼字符串）保证两个端点永远一致，也省掉每请求的分配。
FAKE_LIST :: `{"file":` + FILE_SIG +
	`,"luci":` + LUCI_SIG +
	`,"luci-rpc":` + LUCI_RPC_SIG +
	`,"molly.probe":` + PROBE_SIG +
	`,"session":` + SESSION_SIG +
	`,"uci":` + UCI_SIG +
	`}`

list_objects :: proc(path: string, alloc: mem.Allocator) -> (json: string, err: int, ok: bool) {
	if len(path) == 0 {
		return FAKE_LIST, 0, true
	}
	for o in FAKE_OBJECTS {
		if o.path == path {
			return o.sig, 0, true
		}
	}
	// 假数据里没有的对象。真机上 ubus_lookup 对不存在的路径返回
	// UBUS_STATUS_NOT_FOUND，handler 于是回 500 + {"code":4,"message":"Not found"}
	// （上游 ubus.c:249-253），这里保持一致。
	return "", UBUS_STATUS_NOT_FOUND, false
}

call_object :: proc(obj_path: string, method: string, params_json: string, sid: string, alloc: mem.Allocator) -> Call_Result {
	// session 是 molly 自己提供的 ubus 对象（P3-2），不是假数据：走真实现，
	// 这样 macOS 上就能用 /ubus/call/session 覆盖它的完整行为链
	// （login → get/set/access/grant…），与设备上 ucode 调它的路径同构。
	if obj_path == "session" {
		// sid 注入与 linux 侧一致：上游 uhttpd 在对象 params 里追加 ubus_rpc_session
		// （linux.odin 的 call_object 用 blobmsg_add_string 做同一件事）
		params := params_json
		if len(sid) > 0 {
			params = inject_rpc_session(params_json, sid, alloc)
		}
		reply, status := session_call(method, params, alloc)
		if status != 0 {
			return {outcome = .Ok, ret = status}
		}
		return {outcome = .Ok, ret = 0, reply = reply}
	}

	// file 也是 molly 自己的对象（P3-4 第一批：`read` 与路径/权限核心已实现，其余回 8）。
	// 与 uci 不同，file 是**平台无关的真实现**（只用 core:os 与 realpath），所以 macOS 上
	// 断言的就是设备上跑的那份代码。sid 注入同上。
	if obj_path == "file" {
		params := params_json
		if len(sid) > 0 {
			params = inject_rpc_session(params_json, sid, alloc)
		}
		reply, status := file_call(method, params, alloc)
		if status != 0 {
			return {outcome = .Ok, ret = status}
		}
		return {outcome = .Ok, ret = 0, reply = reply}
	}

	// uci 同样是 molly 自己提供的对象（P3-3 的 S1：`configs`/`get` 已实现，其余方法
	// 回 NOT_SUPPORTED(8)——见 uci_object.odin 顶部）。sid 注入与上面的 session 分支一致。
	if obj_path == "uci" {
		params := params_json
		if len(sid) > 0 {
			params = inject_rpc_session(params_json, sid, alloc)
		}
		reply, status := uci_call(method, params, alloc)
		if status != 0 {
			return {outcome = .Ok, ret = status}
		}
		return {outcome = .Ok, ret = 0, reply = reply}
	}

	// luci-rpc（P3-5 的 S1：getBoardJSON / getDHCPLeases；其余方法回 8）。
	// 注意对象名是 `luci-rpc`（luci.c:2043），smoke 探针打在假对象 `luci` 上不受影响。
	if obj_path == "luci-rpc" {
		params := params_json
		if len(sid) > 0 {
			params = inject_rpc_session(params_json, sid, alloc)
		}
		reply, status := luci_call(method, params, alloc)
		if status != 0 {
			return {outcome = .Ok, ret = status}
		}
		return {outcome = .Ok, ret = 0, reply = reply}
	}

	// P3-7/P3-9：`molly.probe` 的 `notify` —— darwin 没有 ubusd，所以直接往事件总线
	// 推一条（linux 侧是 `ubus_notify(ctx, &molly.probe, "ping", …)`，结果同形：
	// 订阅者收到 `event: ping` + `data: {"hello":"world"}`）。
	if obj_path == "molly.probe" && method == "notify" {
		event_bus_publish("molly.probe", "ping", `{"hello":"world"}`, alloc)
		return {outcome = .Ok, ret = 0, reply = `{"notified":"molly.probe"}`}
	}

	sig := ""
	for o in FAKE_OBJECTS {
		if o.path == obj_path {
			sig = o.sig
			break
		}
	}
	if len(sig) == 0 {
		return {outcome = .Object_Not_Found}
	}

	// 方法在不在，用假数据自己的签名做子串判断就够了。真机上这个判断发生在
	// ubusd/rpcd 那边，未知方法回 UBUS_STATUS_METHOD_NOT_FOUND；这里伪造同一个
	// 错误码，好让 handler 的「invoke 返回非 0」分支在 macOS 上也能被测到。
	if !strings.contains(sig, fmt.aprintf(`"%s":`, method, allocator = alloc)) {
		return {outcome = .Ok, ret = UBUS_STATUS_METHOD_NOT_FOUND}
	}

	// 回显入参，用来证明 obj / method / sid / params 四个值确实传到了这一层。
	// **不是设备契约**，别照它写前端。
	p := params_json
	if len(p) == 0 {
		p = "{}"
	}
	reply := fmt.aprintf(
		// JSON 的花括号要写两遍：Odin 的 fmt 把单个 '{' 当动词起始符
		`{{"echo":{{"object":"%s","method":"%s","sid":"%s","params":%s}}}}`,
		obj_path,
		method,
		sid,
		p,
		allocator = alloc,
	)
	return {outcome = .Ok, ret = 0, reply = reply}
}

// ---------------------------------------------------------------------------
// uci 存在性检查（菜单的 depends.uci）
// ---------------------------------------------------------------------------

// 假配置：模拟一台「配了 network 的 lan/wan/wg0、system 的 ntp」的设备，让
// depends.uci 的每种形态都能在 macOS 上被断言到——config 有 section、具名
// section、匿名 section 按 `@<type>` 匹配、option 值精确匹配、以及「config 存在
// 但没有 section」。
//
// **不是设备契约**：真机上的取值来自 /etc/config（第 7 步验证）。
@(private)
Fake_Config :: struct {
	name:     string,
	sections: []Uci_Section,
}

@(private)
FAKE_UCI: []Fake_Config = {
	{
		name = "network",
		sections = []Uci_Section{
			{
				name = "lan",
				type_name = "interface",
				options = []Uci_Option{
					{name = "proto", values = []string{"static"}},
					{name = "ifname", values = []string{"br-lan"}},
					{name = "ipaddr", values = []string{"192.168.1.1"}},
				},
			},
			{
				name = "wan",
				type_name = "interface",
				options = []Uci_Option{{name = "proto", values = []string{"dhcp"}}},
			},
			{
				name = "wg0",
				type_name = "interface",
				options = []Uci_Option{{name = "proto", values = []string{"wireguard"}}},
			},
			// 匿名 section（真机上的 network.@switch[0]）：名字为空，只能按 @type 匹配
			{
				name = "",
				type_name = "switch",
				anonymous = true,
				options = []Uci_Option{{name = "name", values = []string{"switch0"}}},
			},
		},
	},
	{
		name = "system",
		sections = []Uci_Section{
			{
				name = "ntp",
				type_name = "timeserver",
				options = []Uci_Option{
					{name = "enabled", values = []string{"1"}},
					{
						name = "server",
						is_list = true,
						values = []string{"0.openwrt.pool.ntp.org", "1.openwrt.pool.ntp.org"},
					},
				},
			},
		},
	},
	// 存在但没有 section 的 config：上游 `true` 形态必须判**不**满足
	{name = "empty-config", sections = {}},
	// P3-2 的 login 契约来自 /etc/config/rpcd 的 login section（session.c:855-924）。
	// 真机默认就是 `option username 'root'` + `option password '$p$root'`（rpcd 包自带的
	// rpcd.config），这里照抄一份，好让 login 的成功/失败分支都能在 macOS 上被断言。
	{
		name = "rpcd",
		sections = []Uci_Section{
			{
				name = "login",
				type_name = "login",
				options = []Uci_Option{
					{name = "username", values = []string{"root"}},
					{name = "password", values = []string{"$p$root"}},
					{name = "read", is_list = true, values = []string{"*"}},
					{name = "write", is_list = true, values = []string{"*"}},
				},
			},
		},
	},
	// P3-5：getDHCPLeases 的 leasefile 发现走 uci `dhcp` config 的 `dnsmasq`/`odhcpd`
	// section（luci.c:394-473）。leasefile 指向 /tmp 固定路径，测试自己写租约文件进去。
	{
		name = "dhcp",
		sections = []Uci_Section{
			{
				name = "dnsmasq",
				type_name = "dnsmasq",
				options = []Uci_Option{
					{name = "leasefile", values = []string{"/tmp/molly-dhcp.leases"}},
				},
			},
			{
				name = "odhcpd",
				type_name = "odhcpd",
				options = []Uci_Option{
					{name = "leasefile", values = []string{"/tmp/molly-odhcpd.leases"}},
				},
			},
		},
	},
}

// ---------------------------------------------------------------------------
// ubus 服务端（P3-1）
// ---------------------------------------------------------------------------

// darwin 没有 ubusd：服务端对象不可用。HTTP 与 dispatcher 照常（走假数据），
// 所以这里返回 false 只是让 main 打一行「未启动」，不影响任何验证路径。
start_ubus_server :: proc() -> bool {
	return false
}

// ---------------------------------------------------------------------------
// P3-2：session 对象在 darwin 侧的两个替身
// ---------------------------------------------------------------------------

// session 对象本身是**真实现**（session.odin 是平台无关的逻辑），darwin 只替两样：
//   1. 密码校验——linux 用 /etc/shadow + crypt()，macOS 上没有等价环境
//   2. /etc/config/rpcd 的 login section——来自上面 FAKE_UCI 里的假数据
//
// 假凭据约定（src/backend/session_test.odin 与 tests/http_smoke.sh 都按这个来）：
//   "$p$root"（真机默认配置的写法） → 密码必须是 "test1234"
//   其它 hash                       → 明文相等才算通过
session_verify_password :: proc(hash, password: string, alloc: mem.Allocator) -> bool {
	if len(hash) == 0 {
		return true // 没设密码：任何密码都通过（session.c:824-828）
	}
	if hash == "$p$root" {
		return password == "test1234"
	}
	return hash == password
}

// 把 sid 追加进对象调用的 params（等价于 linux.odin 里那句 blobmsg_add_string）。
// 入参不是 JSON 对象或解析失败时，退回「只有 ubus_rpc_session」的对象。
@(private)
inject_rpc_session :: proc(params_json, sid: string, alloc: mem.Allocator) -> string {
	obj := make(map[string]json.Value, 0, alloc)
	if len(params_json) > 0 {
		doc: json.Value
		if err := json.unmarshal(transmute([]byte)(params_json), &doc, .JSON, alloc); err == nil {
			if o, is_obj := doc.(json.Object); is_obj {
				for k, v in o {
					obj[k] = v
				}
			}
		}
	}
	obj["ubus_rpc_session"] = sid

	out, err := json.unparse(json.Value(json.Object(obj)), {spec = .JSON}, alloc)
	if err != nil {
		return params_json
	}
	return transmute(string)(out)
}

uci_config_sections :: proc(config: string, alloc: mem.Allocator) -> (sections: []Uci_Section, ok: bool) {
	for c in FAKE_UCI {
		if c.name == config {
			return c.sections, true
		}
	}
	return nil, false
}

// ---------------------------------------------------------------------------
// P3-3（S2）的 delta / savedir 契约（见 backend.odin 顶部的说明）
//
// darwin 的 uci 是**只读**假数据：没有 delta 存储，所以 savedir 切换是空实现；
// 但 `changes` 必须能在 macOS 上被断言形状，于是给 network 配一份固定的假 delta
// （uci_object_test.odin 与 tests/http_smoke.sh 都按这份约定）。
// `state`/`commit`/`revert` 一律回 NOT_SUPPORTED(8)：按决策，写路径只在 linux 上实现。
// ---------------------------------------------------------------------------

@(private)
FAKE_DELTA := [?]Uci_Change{
	{kind = .Change, section = "lan", name = "ipaddr", value = "10.0.0.1"},
	{kind = .List_Add, section = "lan", name = "dns", value = "9.9.9.9"},
	{kind = .Remove, section = "wan", name = "proto"},
	{kind = .Reorder, section = "lan", value = "3"},
	{kind = .Add, section = "wg1"},
	// section 为空 → 上游整条丢掉（uci.c:1202-1203），这里放一条来钉住这个行为
	{kind = .Change, name = "ignored"},
}

// 空实现：假数据没有 delta 目录可切（返回 true 让读路径照常跑）。
uci_set_savedir :: proc(sid: string) -> bool {
	return true
}

// `state` 要读「已提交态」（/var/state），darwin 没有这个目录 → 不支持。
uci_state_sections :: proc(config: string, alloc: mem.Allocator) -> (sections: []Uci_Section, status: int) {
	return nil, UCI_STATUS_NOT_SUPPORTED
}

// 只有 network 有假 delta（与 FAKE_UCI 对得上）；其它 config 回空数组。
uci_delta_changes :: proc(sid, config: string, alloc: mem.Allocator) -> (changes: []Uci_Change, status: int) {
	known := false
	for c in FAKE_UCI {
		if c.name == config {
			known = true
			break
		}
	}
	if !known {
		// linux 侧 uci_load 会失败 → 4（uci.c:1244-1245）；假数据也照这个来
		return nil, UCI_STATUS_NOT_FOUND
	}
	if config != "network" {
		return nil, UCI_STATUS_OK
	}
	return FAKE_DELTA[:], UCI_STATUS_OK
}

// ---------------------------------------------------------------------------
// P3-3（S3）写事务：darwin **不实现**
//
// 按决策（写路径只在 linux 上实现），这里一律 NOT_SUPPORTED(8)。注意方法层的
// **参数校验与 ACL 检查在 provider 之前**，所以 darwin 上仍然能断言 2（缺参/非法名）
// 与 6（没权限），校验通过之后才落到这里回 8。
// ---------------------------------------------------------------------------

Uci_Write_Txn :: struct {
	unused: u8,
}

uci_write_begin :: proc(sid, config: string, alloc: mem.Allocator) -> (^Uci_Write_Txn, int) {
	return nil, UCI_STATUS_NOT_SUPPORTED
}

uci_write_end :: proc(txn: ^Uci_Write_Txn) {}

uci_write_sections :: proc(txn: ^Uci_Write_Txn, alloc: mem.Allocator) -> ([]Uci_Section, int) {
	return nil, UCI_STATUS_NOT_SUPPORTED
}

uci_write_add_section :: proc(txn: ^Uci_Write_Txn, type_name, name: string, alloc: mem.Allocator) -> (string, int) {
	return "", UCI_STATUS_NOT_SUPPORTED
}

uci_write_merge_set :: proc(
	txn: ^Uci_Write_Txn,
	section, option: string,
	value: json.Value,
	alloc: mem.Allocator,
) -> int {
	return UCI_STATUS_NOT_SUPPORTED
}

uci_write_add_value :: proc(
	txn: ^Uci_Write_Txn,
	section, option: string,
	value: json.Value,
	alloc: mem.Allocator,
) -> int {
	return UCI_STATUS_NOT_SUPPORTED
}

uci_write_save :: proc(txn: ^Uci_Write_Txn) -> int {
	return UCI_STATUS_NOT_SUPPORTED
}

uci_write_delete :: proc(
	txn: ^Uci_Write_Txn,
	section: string,
	form: Uci_Delete_Form,
	names: []string,
	alloc: mem.Allocator,
) -> int {
	return UCI_STATUS_NOT_SUPPORTED
}

uci_write_rename :: proc(
	txn: ^Uci_Write_Txn,
	section, option, new_name: string,
	alloc: mem.Allocator,
) -> int {
	return UCI_STATUS_NOT_SUPPORTED
}

// 返回「找到了吗」——darwin 上没有实现，永远是 false（调用方据此回 4）。
uci_write_reorder :: proc(txn: ^Uci_Write_Txn, section: string, pos: int, alloc: mem.Allocator) -> bool {
	return false
}

// apply 系（S4）：提交要走 libuci、reload 要 fork/exec，darwin 都不做 → 8。
// 注意方法层里「有没有待确认的 apply」（→ 5）与参数校验（→ 2）在 provider 之前，
// 所以 darwin 上仍然能断言 5 与 2。
uci_apply_config :: proc(config: string, no_delta: bool, alloc: mem.Allocator) -> int {
	return UCI_STATUS_NOT_SUPPORTED
}

uci_reload_config :: proc(alloc: mem.Allocator) -> int {
	return UCI_STATUS_NOT_SUPPORTED
}

uci_commit :: proc(sid, config: string, alloc: mem.Allocator) -> int {
	return UCI_STATUS_NOT_SUPPORTED
}

uci_revert :: proc(sid, config: string, alloc: mem.Allocator) -> int {
	return UCI_STATUS_NOT_SUPPORTED
}

// 设备上是 /etc/config/* 的字母序列表（libuci 内部用 glob），这里就是假配置表的名字。
// P3-3 的 `configs` 方法用它（uci.c:1390）。
uci_list_configs :: proc(alloc: mem.Allocator) -> (names: []string, ok: bool) {
	out := make([dynamic]string, 0, len(FAKE_UCI), alloc)
	for c in FAKE_UCI {
		append(&out, c.name)
	}
	return out[:], true
}

// P3-5：getBoardJSON 读的板级描述文件。真机是 /etc/board.json（luci.c 的
// blobmsg_add_json_from_file 路径）；darwin 用仓库里的 fixture（相对仓库根，
// 测试从根目录跑）。
luci_board_json_path :: proc() -> string {
	return "tests/fixtures/board.json"
}

// P3-6：acl.d 目录。真机是 /usr/share/rpcd/acl.d（session.h 的 RPC_SESSION_ACL_DIR）；
// darwin 用仓库 fixture（相对仓库根，测试从根目录跑）。
session_acl_dir :: proc() -> string {
	return "tests/fixtures/acl.d"
}

// P3-5 S2b：getNetworkDevices 绑定 sysfs（/sys/class/net），darwin 上没有——
// 与 uci 写路径同一决策：linux-only，darwin 回 8。
luci_network_devices_json :: proc(alloc: mem.Allocator) -> (string, int) {
	return "", LUCI_STATUS_NOT_SUPPORTED
}

// P3-5 S2c：getWirelessDevices 代理 netifd 的 `network.wireless status`——
// darwin 没有 netifd/ubusd，回 8。
luci_wireless_devices_json :: proc(alloc: mem.Allocator) -> (string, int) {
	return "", LUCI_STATUS_NOT_SUPPORTED
}

// P3-5 S2d：getHostHints 绑 netlink 邻居表 / /etc/ethers / ifaddrs——darwin 回 8。
luci_host_hints_json :: proc(alloc: mem.Allocator) -> (string, int) {
	return "", LUCI_STATUS_NOT_SUPPORTED
}

// ---------------------------------------------------------------------------
// P3-7 S2 的平台钩子：darwin 没有 ubusd，事件由 `molly.probe/emit`（**测试专用**）
// 直接推进 `event_bus_publish`，所以这里什么都不用做。
// linux 侧要真的 register_subscriber + subscribe，见 linux.odin。
// ---------------------------------------------------------------------------

sse_watch_start :: proc(path: string) -> bool {
	return true
}

sse_watch_stop :: proc(path: string) {
}