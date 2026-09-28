package backend

// ---------------------------------------------------------------------------
// luci-rpc 对象（P3-5，6 方法全实现——S1…S2d 各分片都已收口）
//
// 契约：luci@d6167ea 的 `libs/rpcd-mod-luci/src/luci.c`（本地 /tmp/r8/luci-all/）。
// 对象名是 **`luci-rpc`**（luci.c:2043），6 方法（:2033-2040）：文件/解析驱动的
// `getBoardJSON`/`getDHCPLeases`，与设备绑定的 `getNetworkDevices`/`getWirelessDevices`/
// `getHostHints`/`getDUIDHints`（netlink 邻居表 + iwinfo + getifaddrs）。**本文件只放
// 平台无关的部分**；设备绑定走 provider（linux 真实现，darwin 回 NOT_SUPPORTED(8)）。
//
// 契约摘要与行号见 .ai-memory/p3-luci-server.md 的 P3-5 节。要点：
//   - 这些方法**没有 ACL 检查**（上游 policy 里 luci 对象没有 session 字段，handler 也不查）。
//   - getBoardJSON：读 /etc/board.json（provider），失败/非 JSON → 9。
//   - getDHCPLeases：leasefile 发现走 uci `dhcp` config（dnsmasq/odhcpd section 的
//     `leasefile` option，回退 /tmp/dhcp.leases、/tmp/odhcpd.leases）；family
//     0/4/6，其它整数 → 2，**非整数类型按缺省 0 处理**（blobmsg 的 policy 行为）。
// ---------------------------------------------------------------------------

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:time"

LUCI_STATUS_OK :: 0
LUCI_STATUS_INVALID_ARGUMENT :: 2
LUCI_STATUS_NOT_FOUND :: 4
LUCI_STATUS_NOT_SUPPORTED :: 8
LUCI_STATUS_UNKNOWN_ERROR :: 9

Luci_Lease_File :: struct {
	path:   string,
	odhcpd: bool,
}

// 上游 lease_entry 的等价物（只留回复要用的字段；地址只回第一个）。
Luci_Lease :: struct {
	af:       int, // 4 / 6
	expire:   int, // -1 = 永久
	iface:    string, // 空 = 无（dnsmasq 行没有 interface）
	hostname: string,
	mac:      string, // "aa:bb:cc:dd:ee:ff" 小写；空 = 无
	duid:     string,
	iaid:     string,
	addr:     string, // 第一个地址（上游 :2000 只回 addr[0]）
}

// ---------------------------------------------------------------------------
// 解析助手（纯函数，now 由调用方注入便于测试）
// ---------------------------------------------------------------------------

// ether_aton 的等价解析：`aa:bb:cc:dd:ee:ff`（6 组、每组 2 个 hex、冒号分隔）。
// 成功返回小写规范化串，失败返回空。
@(private)
luci_parse_mac :: proc(s: string, alloc: mem.Allocator) -> string {
	if len(s) != 17 {
		return ""
	}
	out: [17]u8
	hex := "0123456789abcdef"
	for i := 0; i < 17; i += 1 {
		c := s[i]
		if i % 3 == 2 {
			if c != ':' {
				return ""
			}
			out[i] = ':'
			continue
		}
		switch {
		case c >= '0' && c <= '9':
			out[i] = c
		case c >= 'a' && c <= 'f':
			out[i] = c
		case c >= 'A' && c <= 'F':
			out[i] = hex[digits_val(c)]
		case:
			return ""
		}
	}
	// 注意：string(out[:]) 是**别名**不是拷贝——out 是栈上数组，返回后内容失效
	// 必须显式用调用方的 alloc：不带分配器的 clone 落到 context.allocator，在设备上
	// 就是「每次租约解析泄漏 17 字节 × 条目数」（单测里表现为 `leak` 警告）。
	return strings.clone(string(out[:]), alloc)
}

digits_val :: proc(c: u8) -> int {
	switch {
	case c >= '0' && c <= '9':
		return int(c - '0')
	case c >= 'a' && c <= 'f':
		return int(c - 'a' + 10)
	}
	return int(c - 'A' + 10)
}

// luci.c:296-330 duid2ea：入参是**已去冒号**的纯 hex 串。
// len 28 且前缀 00010001 → 偏移 16 的 6 字节；len 20 且前缀 00030001 → 偏移 8。
@(private)
luci_duid2ea :: proc(duid: string, alloc: mem.Allocator) -> string {
	if len(duid) == 0 {
		return ""
	}
	for c in duid {
		ok := (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
		if !ok {
			return ""
		}
	}
	switch len(duid) {
	case 28:
		if duid[:8] == "00010001" {
			return luci_parse_mac(duid_to_mac(duid[16:28], alloc), alloc)
		}
	case 20:
		if duid[:8] == "00030001" {
			return luci_parse_mac(duid_to_mac(duid[8:20], alloc), alloc)
		}
	}
	return ""
}

// 12 个 hex 字符 → "xx:xx:xx:xx:xx:xx"
@(private)
duid_to_mac :: proc(hex12: string, alloc: mem.Allocator) -> string {
	out: [17]u8
	for i := 0; i < 6; i += 1 {
		out[i * 3] = hex12[i * 2]
		out[i * 3 + 1] = hex12[i * 2 + 1]
		if i < 5 {
			out[i * 3 + 2] = ':'
		}
	}
	return strings.clone(string(out[:]), alloc)
}

strip_colons :: proc(s: string, alloc: mem.Allocator) -> string {
	out := make([dynamic]u8, 0, len(s), alloc)
	for c in s {
		if c != ':' {
			append(&out, u8(c))
		}
	}
	return string(out[:])
}

// 严格 IPv4：a.b.c.d，每段 0-255
@(private)
luci_valid_ip4 :: proc(s: string) -> bool {
	parts := strings.split(s, ".", context.allocator)
	defer delete(parts)
	if len(parts) != 4 {
		return false
	}
	for p in parts {
		if len(p) == 0 || len(p) > 3 {
			return false
		}
		n := 0
		for c in p {
			if c < '0' || c > '9' {
				return false
			}
			n = n * 10 + int(c - '0')
		}
		if n > 255 {
			return false
		}
	}
	return true
}

// 宽松 IPv6：至少两个 ':' 且只含 hex/':'。上游用 inet_pton 严格校验——这里放宽
// 只影响「跳过非法行」的判定，租约文件是机器写的，风险可控（偏离记文档）。
@(private)
luci_valid_ip6 :: proc(s: string) -> bool {
	colons := 0
	for c in s {
		if c == ':' {
			colons += 1
			continue
		}
		ok := (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
		if !ok {
			return false
		}
	}
	return colons >= 2 && len(s) >= 2
}

// ts → expire 的两条规则（**不同**，照抄）：
//   dnsmasq（luci.c:567-574）：n>now → n-now；n>0 → 0；n==0 → -1（永久）
//   odhcpd （luci.c:525-531）：n>now → n-now；n>=0 → 0；n<0 → -1
@(private)
luci_expire_dnsmasq :: proc(n, now: int) -> int {
	if n > now {
		return n - now
	}
	if n > 0 {
		return 0
	}
	return -1
}

@(private)
luci_expire_odhcpd :: proc(n, now: int) -> int {
	if n > now {
		return n - now
	}
	if n >= 0 {
		return 0
	}
	return -1
}

parse_ts :: proc(s: string) -> (int, bool) {
	if len(s) == 0 {
		return 0, false
	}
	neg := false
	i := 0
	if s[0] == '-' {
		neg = true
		i = 1
		if len(s) == 1 {
			return 0, false
		}
	}
	n := 0
	for ; i < len(s); i += 1 {
		c := s[i]
		if c < '0' || c > '9' {
			return 0, false
		}
		n = n * 10 + int(c - '0')
	}
	if neg {
		n = -n
	}
	return n, true
}

// dnsmasq 租约行（luci.c:561-634）：`ts mac ip hostname clientid`
@(private)
luci_parse_dnsmasq_line :: proc(line: string, now: int, alloc: mem.Allocator) -> (Luci_Lease, bool) {
	e: Luci_Lease
	f := strings.fields(line, alloc)
	if len(f) < 5 {
		return e, false
	}

	ts, ok := parse_ts(f[0])
	if !ok {
		return e, false
	}
	e.expire = luci_expire_dnsmasq(ts, now)
	e.mac = luci_parse_mac(f[1], alloc)

	if luci_valid_ip6(f[2]) {
		e.af = 6
	} else if luci_valid_ip4(f[2]) {
		e.af = 4
	} else {
		return e, false
	}
	e.addr = f[2]

	// !mac && af==v4 → 跳行（v6 无 MAC 合法，luci.c:599-600）
	if len(e.mac) == 0 && e.af == 4 {
		return e, false
	}

	e.hostname = f[3]
	duid := f[4]

	// clientid 的四种形态（luci.c:612-628）
	if e.af == 4 && len(duid) > 15 && duid[:3] == "ff:" {
		// ff:<iaid-4-bytes>:<duid-x-bytes...>（冒号分隔）
		e.iaid = strip_colons(duid[3:14], alloc)
		e.duid = strip_colons(duid[15:], alloc)
	} else if e.af == 4 && len(duid) == 20 && duid[:3] == "01:" {
		// 01:<mac-addr>：只在行内 MAC 字段解析失败时才用它兜底（上游 `if (!ea)`，:621）
		if len(e.mac) == 0 {
			e.mac = luci_parse_mac(duid[3:], alloc)
		}
		e.duid = ""
	} else if duid == "*" {
		e.duid = ""
	} else {
		e.duid = strip_colons(duid, alloc)
	}

	// luci.c:609-610 / :624-625
	if e.hostname == "*" {
		e.hostname = ""
	}
	// mac 兜底（luci.c:630-634）
	if len(e.mac) == 0 && len(e.duid) > 0 {
		e.mac = luci_duid2ea(e.duid, alloc)
	}
	return e, true
}

// odhcpd 租约行（luci.c:489-560）：
// `# iface duid_or_mac iaid_or_"ipv4" name ts id length addr/addr/…`
@(private)
luci_parse_odhcpd_line :: proc(line: string, now: int, alloc: mem.Allocator) -> (Luci_Lease, bool) {
	e: Luci_Lease
	f := strings.fields(line, alloc)
	if len(f) < 8 || f[0] != "#" {
		return e, false
	}

	e.iface = f[1]
	id2 := f[2]
	iaid := f[3]
	hostname := f[4]
	ts_s := f[5]
	length := f[7]

	if iaid == "ipv4" {
		// v4 形态：第二字段是 MAC，duid/iaid 都置空（luci.c:506-511）
		e.af = 4
		e.mac = luci_parse_mac(id2, alloc)
	} else {
		e.af = 6
		e.duid = id2
		e.iaid = iaid
	}

	hostname_ok := true
	if hostname == "-" {
		hostname_ok = false
	}
	if hostname_ok {
		e.hostname = hostname
	}
	if e.duid == "-" {
		e.duid = ""
	}

	ts, ok := parse_ts(ts_s)
	if !ok {
		return e, false
	}
	e.expire = luci_expire_odhcpd(ts, now)

	// length 非 0 覆盖 mask（对回复无影响，但解析要照做以保持跳行行为一致）
	if n, pok := parse_ts(length); pok && n != 0 {
		_ = n
	}

	// 地址按 '/' 与空白切（strtok 的分隔符集合），逐个校验（luci.c:543-548）
	for a in f[8:] {
		for piece in strings.split(a, "/", alloc) {
			if e.af == 6 && luci_valid_ip6(piece) {
				if len(e.addr) == 0 {
					e.addr = piece
				}
			} else if e.af == 4 && luci_valid_ip4(piece) {
				if len(e.addr) == 0 {
					e.addr = piece
				}
			}
		}
	}

	// mac 兜底（luci.c:550-554）
	if len(e.mac) == 0 && len(e.duid) > 0 {
		e.mac = luci_duid2ea(e.duid, alloc)
	}
	return e, true
}

// 一条租约 → JSON（字段顺序照上游：expires/interface/hostname/macaddr/duid/iaid/ipaddr）
@(private)
luci_lease_json :: proc(e: Luci_Lease, alloc: mem.Allocator) -> json.Value {
	obj := make(json.Object, 7, alloc)
	// 上游 expire==-1 时 blobmsg_add_u8(expires, 0)——与「已过期」同形（:1978-1982）
	if e.expire == -1 {
		obj["expires"] = json.Value(json.Integer(0))
	} else {
		obj["expires"] = json.Value(json.Integer(i64(e.expire)))
	}
	if len(e.iface) > 0 {
		obj["interface"] = json.Value(json.String(e.iface))
	}
	if len(e.hostname) > 0 {
		obj["hostname"] = json.Value(json.String(e.hostname))
	}
	if len(e.mac) > 0 {
		obj["macaddr"] = json.Value(json.String(e.mac))
	}
	if len(e.duid) > 0 {
		obj["duid"] = json.Value(json.String(e.duid))
	}
	if len(e.iaid) > 0 {
		obj["iaid"] = json.Value(json.String(e.iaid))
	}
	if len(e.addr) > 0 {
		key := e.af == 4 ? "ipaddr" : "ip6addr"
		obj[key] = json.Value(json.String(e.addr))
	}
	return json.Value(obj)
}

// 解析一个租约文件的全部行（逐行调对应的 parser）
@(private)
luci_parse_leases :: proc(content: string, is_odhcpd: bool, now: int, alloc: mem.Allocator) -> []Luci_Lease {
	out := make([dynamic]Luci_Lease, 0, 8, alloc)
	for line_full in strings.split(content, "\n", alloc) {
		line := strings.trim_space(line_full)
		if len(line) == 0 {
			continue
		}
		e: Luci_Lease
		ok: bool
		if is_odhcpd {
			e, ok = luci_parse_odhcpd_line(line, now, alloc)
		} else {
			e, ok = luci_parse_dnsmasq_line(line, now, alloc)
		}
		if ok {
			append(&out, e)
		}
	}
	return out[:]
}

// ---------------------------------------------------------------------------
// 方法
// ---------------------------------------------------------------------------

// luci.c:1895 附近 rpc_luci_get_board_json：把 /etc/board.json 原样作为回复；
// 打不开/不是 JSON → 9。
@(private)
luci_method_get_board_json :: proc(alloc: mem.Allocator) -> (string, int) {
	path := luci_board_json_path()
	data, err := os.read_entire_file(path, alloc)
	if err != nil {
		return "", LUCI_STATUS_UNKNOWN_ERROR
	}
	text := string(data)

	// 上游经 blobmsg_add_json_from_file：不是合法 JSON 就失败。这里只校验，
	// 回复仍用原文本（语义等价：blobmsg 重渲染只改空白）。
	dummy: json.Value
	if json.unmarshal(transmute([]byte)(text), &dummy, .JSON, alloc) != nil {
		return "", LUCI_STATUS_UNKNOWN_ERROR
	}
	if obj, is_obj := dummy.(json.Object); !is_obj || len(obj) == 0 {
		return "", LUCI_STATUS_UNKNOWN_ERROR
	}
	return text, LUCI_STATUS_OK
}

// leasefile 发现（luci.c:394-473）：uci dhcp config 的 dnsmasq/odhcpd section。
// 找不到对应 section 时回退 /tmp/dhcp.leases 与 /tmp/odhcpd.leases。
@(private)
luci_lease_files :: proc(alloc: mem.Allocator) -> []Luci_Lease_File {
	files := make([dynamic]Luci_Lease_File, 0, 4, alloc)

	found_v4 := false
	found_v6 := false
	if sections, ok := uci_config_sections("dhcp", alloc); ok {
		for s in sections {
			path: string
			for o in s.options {
				if o.name == "leasefile" && len(o.values) > 0 {
					path = o.values[0]
					break
				}
			}
			if len(path) == 0 {
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

// luci.c:1937-2027 rpc_luci_get_dhcp_leases。
@(private)
luci_method_get_dhcp_leases :: proc(params: json.Object, alloc: mem.Allocator) -> (string, int) {
	family := 0
	if v, has := params["family"]; has {
		n, is_int := v.(json.Integer)
		if !is_int {
			// blobmsg policy 类型不符 → 当作缺省（family 0）
			n = 0
		}
		switch n {
		case 0, 4, 6:
			family = int(n)
		case:
			return "", LUCI_STATUS_INVALID_ARGUMENT
		}
	}

	now := int(time.to_unix_seconds(time.now()))

	doc := make(json.Object, 2, alloc)

	afs := [2]int{4, 6}
	for af in afs {
		if family != 0 && family != af {
			continue
		}
		key := af == 4 ? "dhcp_leases" : "dhcp6_leases"
		arr := make([dynamic]json.Value, 0, 4, alloc)

		// 与上游对齐：所有文件都解析，逐条按 af 过滤（lease_next + handler 的过滤）
		for f in luci_lease_files(alloc) {
			data, err := os.read_entire_file(f.path, alloc)
			if err != nil {
				continue // add_leasefile fopen 失败 → 跳过
			}
			for e in luci_parse_leases(string(data), f.odhcpd, now, alloc) {
				if e.af != af {
					continue
				}
				append(&arr, luci_lease_json(e, alloc))
			}
		}

		doc[key] = json.Value(json.Array(arr))
	}

	return session_marshal(json.Value(doc), alloc), LUCI_STATUS_OK
}

// ---------------------------------------------------------------------------
// getDUIDHints（S2a；luci.c:1831-1900 附近）
//
// 只取 v6 且有 duid 的租约，按 key 去重（`duid` 或 `duid%iaid`），回复是
// 以 key 为键的对象：{interface?, duid, iaid?, hostname?, macaddr?}。
// 完全可移植（复用 S1 的租约文件发现与解析）。
// ---------------------------------------------------------------------------
@(private)
luci_method_get_duid_hints :: proc(alloc: mem.Allocator) -> (string, int) {
	now := int(time.to_unix_seconds(time.now()))

	doc := make(json.Object, 4, alloc)
	seen := make(map[string]bool, 4, alloc)

	for f in luci_lease_files(alloc) {
		data, err := os.read_entire_file(f.path, alloc)
		if err != nil {
			continue
		}
		for e in luci_parse_leases(string(data), f.odhcpd, now, alloc) {
			if e.af != 6 || len(e.duid) == 0 {
				continue
			}

			// 上游的 key：duid（无 iaid）或 duid%iaid（luci.c:1855-1859 的
			// sprintf("%s%s%s", duid, "%", iaid)）——用拼接避免 fmt 的 %% 转义歧义
			key := len(e.iaid) > 0 ? strings.concatenate({e.duid, "%", e.iaid}, alloc) : e.duid
			if seen[key] {
				continue
			}
			seen[key] = true

			obj := make(json.Object, 5, alloc)
			if len(e.iface) > 0 {
				obj["interface"] = json.Value(json.String(e.iface))
			}
			obj["duid"] = json.Value(json.String(e.duid))
			if len(e.iaid) > 0 {
				obj["iaid"] = json.Value(json.String(e.iaid))
			}
			if len(e.hostname) > 0 {
				obj["hostname"] = json.Value(json.String(e.hostname))
			}
			if len(e.mac) > 0 {
				obj["macaddr"] = json.Value(json.String(e.mac))
			}
			doc[key] = json.Value(obj)
		}
	}

	return session_marshal(json.Value(doc), alloc), LUCI_STATUS_OK
}

// luci-rpc 的调用入口（与 session_call / uci_call / file_call 同形）。
luci_call :: proc(method: string, params_json: string, alloc: mem.Allocator) -> (reply: string, status: int) {
	params := make(json.Object, 0, alloc)
	if len(params_json) > 0 {
		doc: json.Value
		if err := json.unmarshal(transmute([]byte)(params_json), &doc, .JSON, alloc); err == nil {
			if obj, is_obj := doc.(json.Object); is_obj {
				params = obj
			}
		}
	}

	switch method {
	case "getBoardJSON":
		return luci_method_get_board_json(alloc)
	case "getDHCPLeases":
		return luci_method_get_dhcp_leases(params, alloc)
	case "getDUIDHints":
		return luci_method_get_duid_hints(alloc)
	case "getNetworkDevices":
		// S2b：sysfs + getifaddrs，linux-only（darwin 的 provider 回 8）
		return luci_network_devices_json(alloc)
	case "getWirelessDevices":
		// S2c：代理 netifd 的 network.wireless status，linux-only
		return luci_wireless_devices_json(alloc)
	case "getHostHints":
		// S2d：netlink/ethers/租约/ifaddrs/静态租约 五源合并，linux-only
		return luci_host_hints_json(alloc)
	case:
		return "", 3 // METHOD_NOT_FOUND
	}
}
