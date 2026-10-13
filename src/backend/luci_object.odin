package backend

// luci-rpc —— molly 自持的 ubus 对象之一（对齐 internal/backend/luci_object.go，后者对照
// rpcd-mod-luci 的 luci.c）。
//
// 对象名是 **`luci-rpc`**（luci.c:2043），6 方法：文件/解析驱动的 getBoardJSON /
// getDHCPLeases / getDUIDHints，与设备绑定的 getNetworkDevices / getWirelessDevices /
// getHostHints。**本文件只放平台无关的部分**；板级文件路径与设备绑定走平台钩子
// （宿主默认回 Status_Not_Supported，阶段 3h 由 linux 平台文件接真实现）。
//
// 要点（照抄 Go）：
//   - 这些方法**没有 ACL 检查**（上游 policy 里 luci 对象没有 session 字段，handler 也不查）。
//   - getBoardJSON：读板级描述文件（provider），失败/非 JSON/空对象 → 9。
//   - getDHCPLeases：leasefile 发现走 uci `dhcp` config（dnsmasq/odhcpd section 的
//     `leasefile` option，回退 /tmp/dhcp.leases、/tmp/odhcpd.leases）；family 0/4/6，
//     其它整数 → 2，**非整数类型按缺省 0 处理**（blobmsg 的 policy 行为）。

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:time"
import "core:encoding/json"

// ---------------------------------------------------------------------------
// 平台钩子（宿主默认实现；阶段 3h 由 linux/darwin 平台文件覆盖）
// ---------------------------------------------------------------------------

hook_luci_board_path:       proc(alloc: mem.Allocator) -> string
hook_luci_network_devices:  proc(alloc: mem.Allocator) -> (i32, string)
hook_luci_wireless_devices: proc(alloc: mem.Allocator) -> (i32, string)
hook_luci_host_hints:       proc(alloc: mem.Allocator) -> (i32, string)
luci_hooks_ready : bool

// host_luci_board_path —— getBoardJSON 读的板级描述文件。真机是 /etc/board.json；
// 宿主用仓库 fixture。GOMOLLY_BOARD_JSON 可覆盖（smoke.sh 会设绝对路径），否则相对
// 进程 cwd（约定从仓库根启动）走 tests/fixtures/board.json。
host_luci_board_path :: proc(alloc: mem.Allocator) -> string {
	if p, ok := os.lookup_env("GOMOLLY_BOARD_JSON", alloc); ok && p != "" {
		return p
	}
	return "tests/fixtures/board.json"
}

// host_luci_not_supported —— 设备绑定方法（getNetworkDevices 等）绑 sysfs / netifd /
// netlink / ifaddrs，宿主（darwin）没有 → 与 uci 写路径同一决策：回 8。
host_luci_not_supported :: proc(alloc: mem.Allocator) -> (i32, string) {
	_ = alloc
	return Status_Not_Supported, ""
}

luci_ensure_hooks :: proc() {
	if luci_hooks_ready {
		return
	}
	if hook_luci_board_path == nil {
		hook_luci_board_path = host_luci_board_path
	}
	if hook_luci_network_devices == nil {
		hook_luci_network_devices = host_luci_not_supported
	}
	if hook_luci_wireless_devices == nil {
		hook_luci_wireless_devices = host_luci_not_supported
	}
	if hook_luci_host_hints == nil {
		hook_luci_host_hints = host_luci_not_supported
	}
	luci_hooks_ready = true
}

// ---------------------------------------------------------------------------
// 租约模型（纯函数，now 由调用方注入便于测试）
// ---------------------------------------------------------------------------

// Luci_Lease_File 是一个租约文件及其格式（odhcpd 行与 dnsmasq 行解析不同）。
Luci_Lease_File :: struct {
	path:   string,
	odhcpd: bool,
}

// Luci_Lease 是上游 lease_entry 的等价物（只留回复要用的字段；地址只回第一个）。
Luci_Lease :: struct {
	af:       int,   // 4 / 6
	expire:   i64,   // -1 = 永久
	iface:    string, // 空 = 无（dnsmasq 行没有 interface）
	hostname: string,
	mac:      string, // "aa:bb:cc:dd:ee:ff" 小写；空 = 无
	duid:     string,
	iaid:     string,
	addr:     string, // 第一个地址（上游 :2000 只回 addr[0]）
}

// luci_parse_mac —— ether_aton 的等价解析：`aa:bb:cc:dd:ee:ff`（6 组、每组 2 个 hex、冒号分隔）。
// 成功返回小写规范化串，失败返回空。
luci_parse_mac :: proc(s: string) -> string {
	if len(s) != 17 {
		return ""
	}
	out: [17]u8
	for i := 0; i < 17; i += 1 {
		c := s[i]
		if i % 3 == 2 {
			if c != ':' {
				return ""
			}
			out[i] = ':'
			continue
		}
		if c >= '0' && c <= '9' {
			out[i] = c
		} else if c >= 'a' && c <= 'f' {
			out[i] = c
		} else if c >= 'A' && c <= 'F' {
			out[i] = c - 'A' + 'a'
		} else {
			return ""
		}
	}
	res, _ := strings.clone(string(out[:]))
	return res
}

// luci_duid_to_mac —— 把 12 个 hex 字符渲染成 "xx:xx:xx:xx:xx:xx"。
luci_duid_to_mac :: proc(hex12: string) -> string {
	out: [17]u8
	for i := 0; i < 6; i += 1 {
		out[i*3] = hex12[i*2]
		out[i*3+1] = hex12[i*2+1]
		if i < 5 {
			out[i*3+2] = ':'
		}
	}
	res, _ := strings.clone(string(out[:]))
	return res
}

// luci_duid2ea —— 对齐 luci.c:296-330 duid2ea：入参是**已去冒号**的纯 hex 串。
// len 28 且前缀 00010001 → 偏移 16 的 6 字节；len 20 且前缀 00030001 → 偏移 8。
luci_duid2ea :: proc(duid: string) -> string {
	if len(duid) == 0 {
		return ""
	}
	for i := 0; i < len(duid); i += 1 {
		c := duid[i]
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')) {
			return ""
		}
	}
	if len(duid) == 28 && duid[0:8] == "00010001" {
		return luci_parse_mac(luci_duid_to_mac(duid[16:28]))
	}
	if len(duid) == 20 && duid[0:8] == "00030001" {
		return luci_parse_mac(luci_duid_to_mac(duid[8:20]))
	}
	return ""
}

// luci_strip_colons —— 去掉串中所有 ':'。
luci_strip_colons :: proc(s: string) -> string {
	out := make([dynamic]u8)
	for i := 0; i < len(s); i += 1 {
		if s[i] != ':' {
			append(&out, s[i])
		}
	}
	res, _ := strings.clone(string(out[:]))
	return res
}

// luci_valid_ip4 —— 严格 IPv4：a.b.c.d，每段 0-255。
luci_valid_ip4 :: proc(s: string) -> bool {
	parts, err := strings.split(s, ".")
	if err != nil {
		return false
	}
	if len(parts) != 4 {
		return false
	}
	for p in parts {
		if len(p) == 0 || len(p) > 3 {
			return false
		}
		n := 0
		for i := 0; i < len(p); i += 1 {
			c := p[i]
			if c < '0' || c > '9' {
				return false
			}
			n = n*10 + int(c - '0')
		}
		if n > 255 {
			return false
		}
	}
	return true
}

// luci_valid_ip6 —— 至少两个 ':' 且只含 hex/':'。上游用 inet_pton 严格校验——这里放宽
// 只影响「跳过非法行」的判定，租约文件是机器写的，风险可控（偏离记文档）。
luci_valid_ip6 :: proc(s: string) -> bool {
	colons := 0
	for i := 0; i < len(s); i += 1 {
		c := s[i]
		if c == ':' {
			colons += 1
			continue
		}
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')) {
			return false
		}
	}
	return colons >= 2 && len(s) >= 2
}

// luci_expire_dnsmasq —— dnsmasq（luci.c:567-574）：n>now → n-now；n>0 → 0；n==0 → -1（永久）。
luci_expire_dnsmasq :: proc(n, now: i64) -> i64 {
	if n > now {
		return n - now
	}
	if n > 0 {
		return 0
	}
	return -1
}

// luci_expire_odhcpd —— odhcpd（luci.c:525-531）：n>now → n-now；n>=0 → 0；n<0 → -1。
luci_expire_odhcpd :: proc(n, now: i64) -> i64 {
	if n > now {
		return n - now
	}
	if n >= 0 {
		return 0
	}
	return -1
}

// luci_parse_ts —— 解析一个带可选负号的十进制整数（对应上游 strtol/strtoul 的用法）。
luci_parse_ts :: proc(s: string) -> (i64, bool) {
	if len(s) == 0 {
		return 0, false
	}
	neg := false
	start := 0
	if s[0] == '-' {
		neg = true
		start = 1
	}
	if len(s) == start {
		return 0, false
	}
	n: i64 = 0
	for j := start; j < len(s); j += 1 {
		c := s[j]
		if c < '0' || c > '9' {
			return 0, false
		}
		n = n*10 + i64(c - '0')
	}
	if neg {
		n = -n
	}
	return n, true
}

// luci_parse_dnsmasq_line —— 解析 dnsmasq 租约行（luci.c:561-634）：`ts mac ip hostname clientid`。
luci_parse_dnsmasq_line :: proc(line: string, now: i64) -> (Luci_Lease, bool) {
	e: Luci_Lease
	f, ferr := strings.fields(line)
	if ferr != nil || len(f) < 5 {
		return e, false
	}

	ts, ok := luci_parse_ts(f[0])
	if !ok {
		return e, false
	}
	e.expire = luci_expire_dnsmasq(ts, now)
	e.mac = luci_parse_mac(f[1])

	if luci_valid_ip6(f[2]) {
		e.af = 6
	} else if luci_valid_ip4(f[2]) {
		e.af = 4
	} else {
		return e, false
	}
	e.addr = f[2]

	// !mac && af==v4 → 跳行（v6 无 MAC 合法，luci.c:599-600）
	if e.mac == "" && e.af == 4 {
		return e, false
	}

	e.hostname = f[3]
	duid := f[4]

	// clientid 的四种形态（luci.c:612-628）
	if e.af == 4 && len(duid) > 15 && duid[0:3] == "ff:" {
		// ff:<iaid-4-bytes>:<duid-x-bytes...>（冒号分隔）
		e.iaid = luci_strip_colons(duid[3:14])
		e.duid = luci_strip_colons(duid[15:])
	} else if e.af == 4 && len(duid) == 20 && duid[0:3] == "01:" {
		// 01:<mac-addr>：只在行内 MAC 字段解析失败时才用它兜底（上游 `if (!ea)`，:621）
		if e.mac == "" {
			e.mac = luci_parse_mac(duid[3:])
		}
		e.duid = ""
	} else if duid == "*" {
		e.duid = ""
	} else {
		e.duid = luci_strip_colons(duid)
	}

	// luci.c:609-610
	if e.hostname == "*" {
		e.hostname = ""
	}
	// mac 兜底（luci.c:630-634）
	if e.mac == "" && e.duid != "" {
		e.mac = luci_duid2ea(e.duid)
	}
	return e, true
}

// luci_parse_odhcpd_line —— 解析 odhcpd 租约行（luci.c:489-560）：
// `# iface duid_or_mac iaid_or_"ipv4" name ts id length addr/addr/…`。
luci_parse_odhcpd_line :: proc(line: string, now: i64) -> (Luci_Lease, bool) {
	e: Luci_Lease
	f, ferr := strings.fields(line)
	if ferr != nil || len(f) < 8 || f[0] != "#" {
		return e, false
	}

	e.iface = f[1]
	id2 := f[2]
	iaid := f[3]
	hostname := f[4]
	tsS := f[5]
	length := f[7]

	if iaid == "ipv4" {
		// v4 形态：第二字段是 MAC，duid/iaid 都置空（luci.c:506-511）
		e.af = 4
		e.mac = luci_parse_mac(id2)
	} else {
		e.af = 6
		e.duid = id2
		e.iaid = iaid
	}

	if hostname != "-" {
		e.hostname = hostname
	}
	if e.duid == "-" {
		e.duid = ""
	}

	ts, ok := luci_parse_ts(tsS)
	if !ok {
		return e, false
	}
	e.expire = luci_expire_odhcpd(ts, now)

	// length 非 0 覆盖 mask（对回复无影响，但解析要照做以保持跳行行为一致）
	luci_parse_ts(length)

	// 地址按 '/' 与空白切（strtok 的分隔符集合），逐个校验（luci.c:543-548）
	for i := 8; i < len(f); i += 1 {
		pieces, perr := strings.split(f[i], "/")
		if perr != nil {
			continue
		}
		for piece in pieces {
			if e.af == 6 && luci_valid_ip6(piece) {
				if e.addr == "" {
					e.addr = piece
				}
			} else if e.af == 4 && luci_valid_ip4(piece) {
				if e.addr == "" {
					e.addr = piece
				}
			}
		}
	}

	// mac 兜底（luci.c:550-554）
	if e.mac == "" && e.duid != "" {
		e.mac = luci_duid2ea(e.duid)
	}
	return e, true
}

// luci_lease_json —— 把一条租约转成 JSON 对象（上游 expire==-1 时 blobmsg_add_u8(expires, 0)）。
luci_lease_json :: proc(e: Luci_Lease) -> json.Object {
	obj: json.Object = make(json.Object)
	exp := e.expire
	if exp == -1 {
		exp = 0
	}
	obj["expires"] = json.Integer(exp)
	if e.iface != "" {
		obj["interface"] = json.String(e.iface)
	}
	if e.hostname != "" {
		obj["hostname"] = json.String(e.hostname)
	}
	if e.mac != "" {
		obj["macaddr"] = json.String(e.mac)
	}
	if e.duid != "" {
		obj["duid"] = json.String(e.duid)
	}
	if e.iaid != "" {
		obj["iaid"] = json.String(e.iaid)
	}
	if e.addr != "" {
		if e.af == 4 {
			obj["ipaddr"] = json.String(e.addr)
		} else {
			obj["ip6addr"] = json.String(e.addr)
		}
	}
	return obj
}

// luci_parse_leases —— 解析一个租约文件的全部行（逐行调对应的 parser）。
luci_parse_leases :: proc(content: string, is_odhcpd: bool, now: i64) -> []Luci_Lease {
	out := make([dynamic]Luci_Lease)
	lines, err := strings.split(content, "\n")
	if err != nil {
		return out[:]
	}
	for line_full in lines {
		line := strings.trim_space(line_full)
		if line == "" {
			continue
		}
		e: Luci_Lease
		ok: bool
		if is_odhcpd {
			e, ok = luci_parse_odhcpd_line(line, now)
		} else {
			e, ok = luci_parse_dnsmasq_line(line, now)
		}
		if ok {
			append(&out, e)
		}
	}
	return out[:]
}

// ---------------------------------------------------------------------------
// leasefile 发现（luci.c:394-473）
// ---------------------------------------------------------------------------

// luci_lease_files —— uci dhcp config 的 dnsmasq/odhcpd section 的 leasefile；
// 找不到对应 section 时回退 /tmp/dhcp.leases 与 /tmp/odhcpd.leases。
luci_lease_files :: proc(alloc: mem.Allocator) -> []Luci_Lease_File {
	files := make([dynamic]Luci_Lease_File)
	found_v4 := false
	found_v6 := false

	session_ensure_store()
	if sections, ok := hook_uci_sections("dhcp", alloc); ok {
		for i := 0; i < len(sections); i += 1 {
			s := &sections[i]
			path, has := section_option_string(s, "leasefile")
			if !has || path == "" {
				continue
			}
			if s.type_name == "dnsmasq" {
				append(&files, Luci_Lease_File{path = path, odhcpd = false})
				found_v4 = true
			} else if s.type_name == "odhcpd" {
				append(&files, Luci_Lease_File{path = path, odhcpd = true})
				found_v6 = true
			}
		}
	}
	if !found_v4 {
		append(&files, Luci_Lease_File{path = "/tmp/dhcp.leases", odhcpd = false})
	}
	if !found_v6 {
		append(&files, Luci_Lease_File{path = "/tmp/odhcpd.leases", odhcpd = true})
	}
	return files[:]
}

// ---------------------------------------------------------------------------
// 方法
// ---------------------------------------------------------------------------

// luci_get_board_json —— 对齐 rpc_luci_get_board_json：把板级描述文件原样作为回复；
// 打不开/不是 JSON（或空对象）→ 9。
luci_get_board_json :: proc(alloc: mem.Allocator) -> (i32, string) {
	text_path := hook_luci_board_path(alloc)
	data, err := os.read_entire_file(text_path, alloc)
	if err != nil {
		return Status_Unknown_Error, ""
	}
	// 上游经 blobmsg_add_json_from_file：不是合法 JSON 就失败。这里只校验，
	// 回复仍用原文本（语义等价：blobmsg 重渲染只改空白）。
	dummy, perr := json.parse_string(string(data), .JSON, true, alloc)
	if perr != nil {
		return Status_Unknown_Error, ""
	}
	obj, is_obj := dummy.(json.Object)
	if !is_obj || len(obj) == 0 {
		return Status_Unknown_Error, ""
	}
	return Status_OK, string(data)
}

// luci_get_dhcp_leases —— 对齐 luci.c:1937-2027 rpc_luci_get_dhcp_leases。
luci_get_dhcp_leases :: proc(params: json.Object, alloc: mem.Allocator) -> (i32, string) {
	family := 0
	if raw, has := params["family"]; has {
		// blobmsg policy：非整数类型不当成错误，按缺省（family 0）处理。
		if iv, ok := raw.(json.Integer); ok {
			n := int(iv)
			if n == 0 || n == 4 || n == 6 {
				family = n
			} else {
				return Status_Invalid_Argument, ""
			}
		}
	}

	now := time.to_unix_seconds(time.now())

	afs := [2]int{4, 6}
	doc: json.Object = make(json.Object)
	for af in afs {
		if family != 0 && family != af {
			continue
		}
		key := "dhcp6_leases"
		if af == 4 {
			key = "dhcp_leases"
		}
		arr: json.Array = make(json.Array)

		// 与上游对齐：所有文件都解析，逐条按 af 过滤（lease_next + handler 的过滤）
		for f in luci_lease_files(alloc) {
			data, rerr := os.read_entire_file(f.path, alloc)
			if rerr != nil {
				continue // add_leasefile fopen 失败 → 跳过
			}
			for e in luci_parse_leases(string(data), f.odhcpd, now) {
				if e.af != af {
					continue
				}
				append(&arr, json.Value(luci_lease_json(e)))
			}
		}
		doc[key] = json.Value(arr)
	}

	return Status_OK, json_unparse(json.Value(doc))
}

// luci_get_duid_hints —— 对齐 getDUIDHints：只取 v6 且有 duid 的租约，按 key 去重
// （`duid` 或 `duid%iaid`），回复是以 key 为键的对象。
luci_get_duid_hints :: proc(alloc: mem.Allocator) -> (i32, string) {
	now := time.to_unix_seconds(time.now())

	doc: json.Object = make(json.Object)
	seen: map[string]bool

	for f in luci_lease_files(alloc) {
		data, rerr := os.read_entire_file(f.path, alloc)
		if rerr != nil {
			continue
		}
		for e in luci_parse_leases(string(data), f.odhcpd, now) {
			if e.af != 6 || e.duid == "" {
				continue
			}
			// 上游的 key：duid（无 iaid）或 duid%iaid（luci.c:1855-1859）
			key := e.duid
			if e.iaid != "" {
				key = fmt.tprintf("%s%%%s", e.duid, e.iaid)
			}
			if seen[key] {
				continue
			}
			seen[key] = true

			obj: json.Object = make(json.Object)
			obj["duid"] = json.String(e.duid)
			if e.iface != "" {
				obj["interface"] = json.String(e.iface)
			}
			if e.iaid != "" {
				obj["iaid"] = json.String(e.iaid)
			}
			if e.hostname != "" {
				obj["hostname"] = json.String(e.hostname)
			}
			if e.mac != "" {
				obj["macaddr"] = json.String(e.mac)
			}
			doc[key] = json.Value(obj)
		}
	}

	return Status_OK, json_unparse(json.Value(doc))
}

// ---------------------------------------------------------------------------
// 入口（注册为 "luci-rpc" 对象）
// ---------------------------------------------------------------------------

luci_handler :: proc(method, params_json: string, alloc: mem.Allocator) -> (status: i32, reply: string) {
	luci_ensure_hooks()

	params: json.Object
	if len(params_json) > 0 {
		if v, err := json.parse_string(params_json, .JSON, true, context.allocator); err == nil {
			if o, ok := v.(json.Object); ok {
				params = o
			}
		}
	}
	if params == nil {
		params = make(json.Object)
	}

	switch method {
	case "getBoardJSON":      return luci_get_board_json(alloc)
	case "getDHCPLeases":     return luci_get_dhcp_leases(params, alloc)
	case "getDUIDHints":      return luci_get_duid_hints(alloc)
	case "getNetworkDevices": return hook_luci_network_devices(alloc)
	case "getWirelessDevices": return hook_luci_wireless_devices(alloc)
	case "getHostHints":      return hook_luci_host_hints(alloc)
	}
	return Status_Method_Not_Found, ""
}
