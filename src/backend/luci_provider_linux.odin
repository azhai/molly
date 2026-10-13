package backend

// luci_provider_linux —— luci-rpc 设备绑定方法里「无 ubus 依赖」部分的 linux 真实现
// （对齐 internal/backend/luci_linux.go 的 luciRPCBoardPath / luciRPCNetworkDevices）。
//
// getNetworkDevices 只读 /sys/class/net + getifaddrs（经已装的 hook_get_ifaddrs），拼每设备一张
// 属性表。getWirelessDevices / getHostHints 还要 netifd 的 ubus 往返（luciInvokeExternal），那属于
// 出站 Backend provider，推迟到与 s4 handler 配对时再建；在此之前这两个钩子保持 nil，
// luci_ensure_hooks 会把它们退化成 host_luci_not_supported（回 8，fail-closed）——不影响本文件交付。
//
// 文件名后缀 _linux 让 Odin 只在 linux 目标编本文件：posix + Get_Ifaddrs 走真设备；宿主（darwin）那份
// 保持 hook_luci_board_path/network_devices 为 nil → host_luci_board_path（fixture）/ host_luci_not_supported。
//
// sysfs 读用 os.read_entire_file + strings.trim_space（对齐 luci.c 的 readstr：去首尾空白，打不开回空）；
// 列目录用 posix.opendir/readdir（保原始顺序，对齐 Go 特意用 Readdirnames 而非会排序的 ReadDir——
// brif/ports 顺序是契约）。所有产出落调用方 alloc（请求 arena）。

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:strconv"
import "core:encoding/json"
import "core:sys/posix"

// IFF_*（linux/if.h）——与 getifaddrs 的 ifa_flags 对应（luci.c:822-830）。
luci_IFF_UP ::           0x1
luci_IFF_BROADCAST ::    0x2
luci_IFF_LOOPBACK ::     0x8
luci_IFF_POINTOPOINT ::  0x10
luci_IFF_NOARP ::        0x80
luci_IFF_PROMISC ::      0x100
luci_IFF_MULTICAST ::    0x1000

// luci_read_sys —— 读一个 sysfs 文件并去首尾空白；打不开回 ""（对齐 luci.c readstr）。
luci_read_sys :: proc(path: string) -> string {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		return ""
	}
	return strings.trim_space(string(data))
}

// luci_read_sys_int —— sysfs 里读一个整数；解析失败按 0（对齐 Go 的 ParseUint/ParseInt err→0）。
luci_read_sys_int :: proc(path: string) -> i64 {
	s := luci_read_sys(path)
	if s == "" {
		return 0
	}
	n, ok := strconv.parse_int(s, 10)
	if !ok {
		return 0
	}
	return i64(n)
}

// luci_list_dir —— 列目录项（保原始顺序，跳过 . 与 ..）；打不开回 (nil,false)。
luci_list_dir :: proc(path: string, alloc: mem.Allocator) -> (names: []string, ok: bool) {
	d := posix.opendir(file_cstr(path))
	if d == nil {
		return nil, false
	}
	defer posix.closedir(d)
	out := make([dynamic]string, alloc)
	for {
		ent := posix.readdir(d)
		if ent == nil {
			break
		}
		name, _ := strings.clone_from_cstring(cast(cstring)(&ent.d_name[0]))
		if name == "." || name == ".." {
			continue
		}
		append(&out, name)
	}
	return out[:], true
}

// luci_bit —— v & mask != 0 ? 1 : 0。
luci_bit :: proc(v: u32, mask: u32) -> json.Value {
	if v & mask != 0 {
		return json.Integer(1)
	}
	return json.Integer(0)
}

// sysp —— 动态路径拼接（Odin 的 `+` 仅允许常量串，这里走 fmt.tprintf）。
sysp :: proc(base, sub: string) -> string {
	return fmt.tprintf("%s/%s", base, sub)
}

// last_path_elem —— 取路径最后一段（master readlink 的 basename）。
last_path_elem :: proc(p: string) -> string {
	if i := strings.last_index(p, "/"); i >= 0 {
		return p[i+1:]
	}
	return p
}

// luci_netdev_json —— 单个设备的属性表（luci.c:670-854）。addrs 是全量 ifaddrs，按 name 过滤。
luci_netdev_json :: proc(name: string, addrs: []If_Addr, alloc: mem.Allocator) -> json.Object {
	doc: json.Object = make(json.Object, alloc)
	doc["name"] = json.Value(json.String(name))
	base := sysp("/sys/class/net", name)

	// bridge（luci.c:670-698）：brif 目录能打开 → bridge=1 + ports + id + stp
	if ports, br_ok := luci_list_dir(sysp(base, "brif"), alloc); br_ok {
		doc["bridge"] = json.Integer(1)
		arr: json.Array = make(json.Array, alloc)
		for p in ports {
			append(&arr, json.Value(json.String(p)))
		}
		doc["ports"] = json.Value(arr)
		doc["id"] = json.Value(json.String(luci_read_sys(sysp(base, "bridge/bridge_id"))))
		stp: i64 = 0
		if luci_read_sys(sysp(base, "bridge/stp_state")) != "0" {
			stp = 1
		}
		doc["stp"] = json.Integer(stp)
	}

	// master（readlink 的 basename，luci.c:700-706）
	if link, ok := file_readlink(sysp(base, "master")); ok {
		doc["master"] = json.Value(json.String(last_path_elem(link)))
	}

	wireless: i64 = 0
	if luci_read_sys(sysp(base, "phy80211/index")) != "" {
		wireless = 1
	}
	doc["wireless"] = json.Integer(wireless)

	up: i64 = 0
	operstate := luci_read_sys(sysp(base, "operstate"))
	if operstate == "up" || operstate == "unknown" {
		up = 1
	}
	doc["up"] = json.Integer(up)

	if mtu := luci_read_sys_int(sysp(base, "mtu")); mtu > 0 {
		doc["mtu"] = json.Integer(mtu)
	}
	if qlen := luci_read_sys_int(sysp(base, "tx_queue_len")); qlen > 0 {
		doc["qlen"] = json.Integer(qlen)
	}

	// devtype（luci.c:726-738）：uevent 里的 DEVTYPE= 行，缺省 "ethernet"
	devtype := "ethernet"
	uevent := luci_read_sys(sysp(base, "uevent"))
	if idx := strings.index(uevent, "DEVTYPE="); idx >= 0 {
		rest := uevent[idx+len("DEVTYPE="):]
		if nl := strings.index_byte(rest, '\n'); nl >= 0 {
			devtype = rest[:nl]
		} else {
			devtype = rest
		}
	}
	doc["devtype"] = json.Value(json.String(devtype))

	// v4/v6 地址（luci.c:740-772），顺带把匹配记录的 flags OR 起来（luci.c:768/789）
	ifa_flags: u32 = 0
	families := [2]struct { fam: int, key: string }{
		{2, "ipaddrs"},
		{10, "ip6addrs"},
	}
	for fi in families {
		arr: json.Array = make(json.Array, alloc)
		for i := 0; i < len(addrs); i += 1 {
			a := &addrs[i]
			if a.name != name || a.family != fi.fam {
				continue
			}
			entry: json.Object = make(json.Object, alloc)
			entry["address"] = json.Value(json.String(a.addr))
			if a.netmask != "" {
				entry["netmask"] = json.Value(json.String(a.netmask))
			}
			if a.dstaddr != "" && a.flags & luci_IFF_POINTOPOINT != 0 {
				entry["remote"] = json.Value(json.String(a.dstaddr))
			} else if a.dstaddr != "" && a.flags & luci_IFF_BROADCAST != 0 {
				entry["broadcast"] = json.Value(json.String(a.dstaddr))
			}
			append(&arr, json.Value(entry))
			ifa_flags |= a.flags
		}
		doc[fi.key] = json.Value(arr)
	}

	// PACKET 信息（luci.c:774-809）：mac/type/ifindex/parent，只取第一个匹配项
	for i := 0; i < len(addrs); i += 1 {
		a := &addrs[i]
		if a.name != name || a.family != 17 {
			continue
		}
		if a.hatype == 1 {
			doc["mac"] = json.Value(json.String(a.mac))
		}
		doc["type"] = json.Integer(i64(a.hatype))
		doc["ifindex"] = json.Integer(i64(a.ifindex))

		// parent（luci.c:791-806）：iflink != ifindex 时找对应设备名
		iflink := luci_read_sys_int(sysp(base, "iflink"))
		if int(iflink) != a.ifindex {
			for j := 0; j < len(addrs); j += 1 {
				p := &addrs[j]
				if p.family != 17 || p.ifindex != int(iflink) {
					continue
				}
				doc["parent"] = json.Value(json.String(p.name))
				break
			}
		}
		break // 只取第一个 PACKET 匹配（luci.c:808）
	}

	// stats（luci.c:811-820）
	stats: json.Object = make(json.Object, alloc)
	stat_names := [10]string{
		"rx_bytes", "tx_bytes", "tx_errors", "rx_errors", "tx_packets",
		"rx_packets", "multicast", "collisions", "rx_dropped", "tx_dropped",
	}
	for sn in stat_names {
		stats[sn] = json.Integer(luci_read_sys_int(sysp(sysp(base, "statistics"), sn)))
	}
	doc["stats"] = json.Value(stats)

	// flags（luci.c:822-830）
	flags: json.Object = make(json.Object, alloc)
	flags["up"] = luci_bit(ifa_flags, luci_IFF_UP)
	flags["broadcast"] = luci_bit(ifa_flags, luci_IFF_BROADCAST)
	flags["promisc"] = luci_bit(ifa_flags, luci_IFF_PROMISC)
	flags["loopback"] = luci_bit(ifa_flags, luci_IFF_LOOPBACK)
	flags["noarp"] = luci_bit(ifa_flags, luci_IFF_NOARP)
	flags["multicast"] = luci_bit(ifa_flags, luci_IFF_MULTICAST)
	flags["pointtopoint"] = luci_bit(ifa_flags, luci_IFF_POINTOPOINT)
	doc["flags"] = json.Value(flags)

	// link（luci.c:832-854）
	link: json.Object = make(json.Object, alloc)
	if speed_s := luci_read_sys(sysp(base, "speed")); speed_s != "" {
		if v, ok := strconv.parse_int(speed_s, 10); ok {
			link["speed"] = json.Integer(i64(v))
		}
	}
	if duplex := luci_read_sys(sysp(base, "duplex")); duplex != "" {
		link["duplex"] = json.Value(json.String(duplex))
	}
	if luci_read_sys_int(sysp(base, "carrier")) == 1 {
		link["carrier"] = json.Integer(1)
	} else {
		link["carrier"] = json.Integer(0)
	}
	link["changes"] = json.Integer(luci_read_sys_int(sysp(base, "carrier_changes")))
	link["up_count"] = json.Integer(luci_read_sys_int(sysp(base, "carrier_up_count")))
	link["down_count"] = json.Integer(luci_read_sys_int(sysp(base, "carrier_down_count")))
	doc["link"] = json.Value(link)

	return doc
}

// linux_network_devices —— /sys/class/net 每个设备一张表（luci.c:860-896）。
// getifaddrs 失败也继续（只是没有地址信息）。
linux_network_devices :: proc(alloc: mem.Allocator) -> (i32, string) {
	addrs := Get_Ifaddrs(alloc)
	doc: json.Object = make(json.Object, alloc)
	if names, ok := luci_list_dir("/sys/class/net", alloc); ok {
		for n in names {
			doc[n] = json.Value(luci_netdev_json(n, addrs, alloc))
		}
	}
	return Status_OK, json_unparse(json.Value(doc))
}

// linux_board_path —— 真机板级描述文件固定 /etc/board.json（对齐 luciRPCBoardPath）。
linux_board_path :: proc(alloc: mem.Allocator) -> string {
	_ = alloc
	return "/etc/board.json"
}

// linux_wireless_devices —— 代理 netifd 的 `network.wireless status`，重塑时丢掉所有 iwinfo 键，
// 再按接口/radio 各补一份 iwinfo（对齐 Go luciRPCWirelessDevices / luci.c:1098-1190）。
//
// 上游语义逐条照抄：
//   - 对象找不到（lookup 失败或连不上总线）→ Status_Not_Found(4)；ret≠0 或回复空 → Status_Unknown_Error(9)。
//   - 逐 radio/接口**丢原 iwinfo 键**，接口级补 Iwinfo_JSON(ifname,false)，radio 级补 Iwinfo_JSON(dev,true)；
//     dev 取「第一个拿到 iwinfo 的接口名」，没有则用 radio 名。
//   - interfaces 键只在其为数组时重塑后回填；非数组直接丢弃（上游 blobmsg 只收 table）。
//   - 其余键原样拷贝。整数用 json.parse_string 解（Odin 的 json.Number 保留整数值），
//     回编不改精度/格式（对齐 Go 的 UseNumber）。
linux_wireless_devices :: proc(alloc: mem.Allocator) -> (i32, string) {
	res := Call_Object("network.wireless", "status", "", "", alloc)
	if res.outcome != .Ok {
		return Status_Not_Found, "" // 上游：对象不存在/总线起不来 → NOT_FOUND（:1187）
	}
	if res.ret != 0 || res.reply == "" {
		return Status_Unknown_Error, ""
	}

	decoded, perr := json.parse_string(res.reply, .JSON, true, alloc)
	if perr != nil {
		return Status_Unknown_Error, ""
	}
	status_obj, ok := decoded.(json.Object)
	if !ok {
		return Status_Unknown_Error, ""
	}

	// add_iwinfo —— 解析一份 iwinfo JSON 文本并挂进目标对象；成功回 true。
	// （Odin 命名嵌套 proc 不自动捕获外层变量，alloc 显式传入。）
	add_iwinfo := proc(dst: ^json.Object, dev: string, phy_only: bool, alloc: mem.Allocator) -> bool {
		if dev == "" {
			return false
		}
		iw, ok := Iwinfo_JSON(dev, phy_only, alloc)
		if !ok {
			return false
		}
		pv, err := json.parse_string(iw, .JSON, true, alloc)
		if err != nil {
			return false
		}
		dst^["iwinfo"] = pv
		return true
	}

	out: json.Object = make(json.Object, alloc)
	for radio_name, radio_val in status_obj {
		radio, ok := radio_val.(json.Object)
		if !ok {
			continue // 上游只收 table（:1108-1110）
		}
		r_out: json.Object = make(json.Object, alloc)
		first_ifname := "" // 第一个能取到 iwinfo 的接口名（:1151）
		for k, v in radio {
			if k == "iwinfo" {
				continue // :1120-1122
			}
			if k == "interfaces" {
				arr, ok := v.(json.Array)
				if !ok {
					continue // 类型不对 → 整个键丢弃（:1124-1125）
				}
				i_out: json.Array = make(json.Array, alloc)
				for iface_val in arr {
					iface, ok := iface_val.(json.Object)
					if !ok {
						continue // 只收 table（:1132-1133）
					}
					clean: json.Object = make(json.Object, alloc)
					ifname := ""
					for ik, iv in iface {
						if ik == "iwinfo" {
							continue // :1143-1144
						}
						if ik == "ifname" {
							if s, is_str := iv.(json.String); is_str {
								ifname = string(s)
							}
						}
						clean[ik] = iv
					}
					// 接口级 iwinfo（phy_only=false）；第一个成功的 ifname 记给 radio 级用。
					if add_iwinfo(&clean, ifname, false, alloc) && first_ifname == "" {
						first_ifname = ifname
					}
					append(&i_out, json.Value(clean))
				}
				r_out["interfaces"] = json.Value(i_out)
				continue
			}
			r_out[k] = v // 其余属性原样拷贝（blobmsg_add_blob，:1158-1160）
		}

		// radio 级 iwinfo（phy_only=true）：没有接口能取到时用 radio 名试（:1163-1165）。
		radio_dev := first_ifname
		if radio_dev == "" {
			radio_dev = radio_name
		}
		add_iwinfo(&r_out, radio_dev, true, alloc)

		out[radio_name] = json.Value(r_out)
	}

	return Status_OK, json_unparse(json.Value(out))
}

@(init)
install_linux_luci_hooks :: proc "contextless" () {
	hook_luci_board_path       = linux_board_path
	hook_luci_network_devices  = linux_network_devices
	hook_luci_wireless_devices = linux_wireless_devices
}
