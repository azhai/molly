package backend

// luci_host_hints_linux —— luci-rpc.getHostHints 的 linux 真实现（对齐 Go
// internal/backend/luci_linux.go 的 luciRPCHostHints / luci.c:1192-1828）。
//
// 五个来源按优先级合并（数字越大越靠前），以 MAC 为键产出一张表：
//   netlink 邻居表 10、/etc/ethers 50、dhcp 租约文件 100、getifaddrs 200、uci 静态租约 250
// 收尾再问一次 netifd 的 network.rrdns（对象不存在/失败就静默跳过）补主机名。
//
// 刻意照抄的上游行为（golden 对比会看到）：
//   1. uci 静态租约的 `ip` 从不生效——只贡献 MAC + hostname。
//   2. rrdns 补名：v6 只在缺主机名时填，v4 覆盖。
//
// 文件名 _linux：宿主（darwin）没有 sysfs/netifd/netlink，那份保持 hook 为 nil →
// host_luci_not_supported（回 8）。邻居/ifaddrs/iwinfo 三钩子由 iwinfo_provider_linux 装好，
// 这里直接用 Get_Neighbors / Get_Ifaddrs；租约发现/解析复用 luci_object.odin 的跨平台件。

import "core:mem"
import "core:os"
import "core:strings"
import "core:time"
import "core:net"
import "core:encoding/json"

// 优先级（luci.c）。
hint_prio_nl     :: 10
hint_prio_ether  :: 50
hint_prio_lease  :: 100
hint_prio_ifaddr :: 200
hint_prio_static :: 250

// Hint_Addr —— 一条地址（同 MAC 同族去重，只保留更高优先级）。
Hint_Addr :: struct {
	af:   int, // 4 / 6
	prio: int,
	addr: string,
}

// Hint —— 一个 MAC 的合并结果。v4/v6 各一条 dynamic（落请求 arena）。
Hint :: struct {
	hostname: string,
	v4:       [dynamic]Hint_Addr,
	v6:       [dynamic]Hint_Addr,
}

Hint_Map :: map[string]^Hint

// hint_get —— 取（或建）一个 MAC 的 hint。
hint_get :: proc(hints: ^Hint_Map, mac: string, alloc: mem.Allocator) -> ^Hint {
	if h, has := hints^[mac]; has {
		return h
	}
	h := new(Hint, alloc)
	h.v4 = make([dynamic]Hint_Addr, alloc)
	h.v6 = make([dynamic]Hint_Addr, alloc)
	hints^[mac] = h
	return h
}

// hint_add_addr —— 同族同地址去重，只有更高优先级才更新（luci.c:1279-1320）。
hint_add_addr :: proc(h: ^Hint, af, prio: int, addr: string) {
	list := &h.v6
	if af == 4 {
		list = &h.v4
	}
	for i := 0; i < len(list^); i += 1 {
		if list^[i].addr != addr {
			continue
		}
		if prio > list^[i].prio {
			list^[i].prio = prio
		}
		return
	}
	append(list, Hint_Addr{af = af, prio = prio, addr = addr})
}

// addr_raw —— 地址的字节日表示（比较用）；n=0 表示解析失败。af==4→4 字节，否则 16 字节。
addr_raw :: proc(af: int, addr: string) -> (b: [16]u8, n: int) {
	if af == 4 {
		a4, ok := net.parse_ip4_address(addr)
		if !ok {
			return b, 0
		}
		arr := transmute([4]u8)(a4)
		copy(b[0:4], arr[:])
		return b, 4
	}
	if ! strings.contains(addr, ":") {
		return b, 0
	}
	a6, ok := net.parse_ip6_address(addr)
	if !ok {
		return b, 0
	}
	arr := transmute([16]u8)(a6)
	copy(b[0:16], arr[:])
	return b, 16
}

// addr_less —— 插入排序比较：prio DESC，同 prio 比地址字节 ASC（luci.c:1219-1234）。
addr_less :: proc(cur, other: Hint_Addr) -> bool {
	if cur.prio != other.prio {
		return cur.prio > other.prio
	}
	cb, cn := addr_raw(cur.af, cur.addr)
	ob, on := addr_raw(other.af, other.addr)
	if cn == 0 || on == 0 || cn != on {
		return false
	}
	for i := 0; i < cn; i += 1 {
		if cb[i] != ob[i] {
			return cb[i] < ob[i]
		}
	}
	return false
}

// hint_sort —— 插入排序（保持上游顺序语义；同 prio 才比字节，稳定即可）。
hint_sort :: proc(list: ^[dynamic]Hint_Addr) {
	for i := 1; i < len(list^); i += 1 {
		cur := list^[i]
		j := i - 1
		for j >= 0 {
			if ! addr_less(cur, list^[j]) {
				break
			}
			list^[j+1] = list^[j]
			j -= 1
		}
		list^[j+1] = cur
	}
}

// hint_v6_rrdns_ok —— 非 ::、非 link-local(fe80::/10)、非 ULA(fc00::/7)。
hint_v6_rrdns_ok :: proc(addr: string) -> bool {
	b, n := addr_raw(6, addr)
	if n != 16 {
		return false
	}
	unspecified := true
	for i := 0; i < 16; i += 1 {
		if b[i] != 0 {
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

// --- 来源 1：netlink 邻居表 ------------------------------------------------

host_hints_nl :: proc(hints: ^Hint_Map, alloc: mem.Allocator) {
	for nb in Get_Neighbors(alloc) {
		mac := luci_parse_mac(nb.mac)
		if mac == "" {
			continue
		}
		af := 4
		if strings.contains(nb.ip, ":") {
			af = 6
		}
		hint_add_addr(hint_get(hints, mac, alloc), af, hint_prio_nl, nb.ip)
	}
}

// --- 来源 2：/etc/ethers ---------------------------------------------------

host_hints_ether :: proc(hints: ^Hint_Map, alloc: mem.Allocator) {
	data, err := os.read_entire_file("/etc/ethers", alloc)
	if err != nil {
		return // 文件不存在：直接跳过（luci.c:1434-1437）
	}
	lines, _ := strings.split(string(data), "\n", alloc)
	for line in lines {
		f := strings.fields(line, alloc)
		if len(f) < 1 {
			continue
		}
		mac := luci_parse_mac(f[0])
		if mac == "" {
			continue
		}
		h := hint_get(hints, mac, alloc)
		if len(f) < 2 {
			continue
		}
		// 第二个字段是 v4 → 当地址加（prio 50）；否则当主机名（luci.c:1446-1456）
		if luci_valid_ip4(f[1]) {
			hint_add_addr(h, 4, hint_prio_ether, f[1])
		} else if h.hostname == "" {
			h.hostname = f[1]
		}
	}
}

// --- 来源 3/5：dhcp 租约文件 + uci 静态租约 --------------------------------

host_hints_uci :: proc(hints: ^Hint_Map, alloc: mem.Allocator) {
	// 静态租约（dhcp config 的 host section，prio 250）；`ip` 照抄上游**不生效**。
	if sections, ok := hook_uci_sections("dhcp", alloc); ok {
		for i := 0; i < len(sections); i += 1 {
			s := &sections[i]
			if s.type_name != "host" {
				continue
			}
			name := ""
			macs: []string
			for o in s.options {
				if o.name == "name" {
					if len(o.values) > 0 {
						name = o.values[0]
					}
				} else if o.name == "mac" {
					if o.is_list {
						macs = o.values
					} else if len(o.values) > 0 {
						// 单一字符串里可以有空格分隔的多个 MAC（luci.c:1523-1527）
						macs = strings.fields(o.values[0], alloc)
					}
				}
			}
			for m in macs {
				mac := luci_parse_mac(m)
				if mac == "" {
					continue
				}
				h := hint_get(hints, mac, alloc)
				if name != "" && h.hostname == "" {
					h.hostname = name
				}
			}
		}
	}

	// dhcp 租约文件（prio 100，luci.c:1555-1575）
	now := time.to_unix_seconds(time.now())
	for f in luci_lease_files(alloc) {
		data, rerr := os.read_entire_file(f.path, alloc)
		if rerr != nil {
			continue
		}
		for e in luci_parse_leases(string(data), f.odhcpd, now) {
			if e.mac == "" {
				continue
			}
			h := hint_get(hints, e.mac, alloc)
			if e.addr != "" {
				hint_add_addr(h, e.af, hint_prio_lease, e.addr)
			}
			if e.hostname != "" && h.hostname == "" {
				h.hostname = e.hostname
			}
		}
	}
}

// --- 来源 4：getifaddrs ----------------------------------------------------

Hint_Device :: struct {
	mac, v4, v6: string
}

host_hints_ifaddrs :: proc(hints: ^Hint_Map, alloc: mem.Allocator) {
	addrs := Get_Ifaddrs(alloc)
	if addrs == nil {
		return
	}

	// 按设备名聚合：MAC（AF_PACKET）+ 第一个 v4 + 第一个 v6
	devices: map[string]Hint_Device = make(map[string]Hint_Device, alloc)
	for i := 0; i < len(addrs); i += 1 {
		a := &addrs[i]
		d, _ := devices[a.name]
		switch a.family {
		case 17: // AF_PACKET
			if a.halen == 6 && d.mac == "" {
				d.mac = a.mac
			}
		case 10: // AF_INET6
			if d.v6 == "" {
				d.v6 = a.addr
			}
		case 2: // AF_INET
			if d.v4 == "" {
				d.v4 = a.addr
			}
		}
		devices[a.name] = d
	}

	for _, d in devices {
		if d.mac == "" || (d.v4 == "" && d.v6 == "") {
			continue
		}
		h := hint_get(hints, d.mac, alloc)
		if d.v4 != "" {
			hint_add_addr(h, 4, hint_prio_ifaddr, d.v4)
		}
		if d.v6 != "" {
			hint_add_addr(h, 6, hint_prio_ifaddr, d.v6)
		}
	}
}

// --- 收尾：rrdns（可选）-----------------------------------------------------

host_hints_rrdns :: proc(hints: ^Hint_Map, alloc: mem.Allocator) {
	addrs := make([dynamic]string, alloc)
	for _, h in hints^ {
		for a in h.v4 {
			append(&addrs, a.addr)
		}
		for a in h.v6 {
			if hint_v6_rrdns_ok(a.addr) {
				append(&addrs, a.addr)
			}
		}
	}
	if len(addrs) == 0 {
		return
	}

	params_obj: json.Object = make(json.Object, alloc)
	arr: json.Array = make(json.Array, alloc)
	for a in addrs {
		append(&arr, json.Value(json.String(a)))
	}
	params_obj["addrs"] = json.Value(arr)
	params_obj["timeout"] = json.Integer(250)
	params_obj["limit"] = json.Integer(len(addrs))

	res := Call_Object("network.rrdns", "lookup", json_unparse(json.Value(params_obj)), "", alloc)
	if res.outcome != .Ok || res.ret != 0 || res.reply == "" {
		return // 对象不存在 / 调用失败：静默跳过（上游同）
	}
	decoded, perr := json.parse_string(res.reply, .JSON, true, alloc)
	if perr != nil {
		return
	}
	obj, is_obj := decoded.(json.Object)
	if !is_obj {
		return
	}

	// 回复是 {地址: 主机名}：v6 只在缺主机名时填，v4 覆盖（luci.c:1680-1701）
	for addr_key, val in obj {
		name_v, is_str := val.(json.String)
		if !is_str {
			continue
		}
		name := string(name_v)
		if name == "" {
			continue
		}
		for _, h in hints^ {
			for a in h.v6 {
				if a.addr == addr_key {
					if h.hostname == "" {
						h.hostname = name
					}
					break
				}
			}
			for a in h.v4 {
				if a.addr == addr_key {
					h.hostname = name
					break
				}
			}
		}
	}
}

// linux_host_hints —— getHostHints 入口（luci.c:1192-1828）：五源合并 + rrdns 后以 MAC 为键输出。
linux_host_hints :: proc(alloc: mem.Allocator) -> (i32, string) {
	hints: Hint_Map = make(Hint_Map, alloc)

	host_hints_nl(&hints, alloc)
	host_hints_uci(&hints, alloc)
	host_hints_ether(&hints, alloc)
	host_hints_ifaddrs(&hints, alloc)
	host_hints_rrdns(&hints, alloc)

	out: json.Object = make(json.Object, alloc)
	for mac, h in hints {
		hint_sort(&h.v4)
		hint_sort(&h.v6)

		obj: json.Object = make(json.Object, alloc)
		a4: json.Array = make(json.Array, alloc)
		for e in h.v4 {
			append(&a4, json.Value(json.String(e.addr)))
		}
		obj["ipaddrs"] = json.Value(a4)
		a6: json.Array = make(json.Array, alloc)
		for e in h.v6 {
			append(&a6, json.Value(json.String(e.addr)))
		}
		obj["ip6addrs"] = json.Value(a6)
		if h.hostname != "" {
			obj["name"] = json.Value(json.String(h.hostname))
		}
		out[mac] = json.Value(obj)
	}

	return Status_OK, json_unparse(json.Value(out))
}

@(init)
install_linux_host_hints_hook :: proc "contextless" () {
	hook_luci_host_hints = linux_host_hints
}
