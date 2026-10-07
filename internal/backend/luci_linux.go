//go:build linux

package backend

// luci-rpc 的 linux 平台钩子（luci_object.go 调用；luci_darwin.go 有同名同签名的另一份）。
//
// 三个设备绑定方法的真实现，逐一对应 Odin 版 src/backend/linux.odin：
//   getNetworkDevices  → /sys/class/net 遍历 + getifaddrs（luci.c:860-896）
//   getWirelessDevices → 代理 netifd 的 network.wireless status，重塑时补 iwinfo（luci.c:1098-1190）
//   getHostHints       → netlink 邻居 / uci / ethers / ifaddrs / rrdns 五源按优先级合并（luci.c:1192-1828）
//
// C 侧（shim.c）已把 getifaddrs / netlink / dlopen libiwinfo 的字节解析做完，这里只做
// sysfs 读取、优先级合并与 JSON 组装。
//
// 刻意的偏离（记文档）：
//   - 外部对象（network.wireless / network.rrdns）用同步 ubus_invoke，超时用包默认 30s；
//     Odin 用 30s（wireless）/ 1s（rrdns）。rrdns 请求自带的 timeout=250 才是真正的界，
//     这里的差别只在「rrdns 完全无响应」时可见，不影响输出。

import (
	"encoding/json"
	"net"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/azhai/molly/internal/cbind"
)

// luciRPCBoardPath：真机是 /etc/board.json（luci.c 的 blobmsg_add_json_from_file 路径）。
func luciRPCBoardPath() string { return "/etc/board.json" }

// ---------------------------------------------------------------------------
// getNetworkDevices（luci.c:860-896）
// ---------------------------------------------------------------------------

// IFF_*（linux/if.h）——与 getifaddrs 的 ifa_flags 对应。
const (
	luciIFFUp           = 0x1
	luciIFFBroadcast    = 0x2
	luciIFFLoopback     = 0x8
	luciIFFPointToPoint = 0x10
	luciIFFNoARP        = 0x80
	luciIFFPromisc      = 0x100
	luciIFFMulticast    = 0x1000
)

// luciReadSys 对齐 luci.c 的 readstr：读文件、去首尾空白；打不开返回空串。
func luciReadSys(path string) string {
	data, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(data))
}

// luciListDir 列目录项（保留目录原始顺序，跳过 . 与 ..）；打不开返回 (nil,false)。
// 用 Open+Readdirnames，不用 os.ReadDir（后者会排序，改变 brif/ports 顺序）。
func luciListDir(path string) ([]string, bool) {
	f, err := os.Open(path)
	if err != nil {
		return nil, false
	}
	defer f.Close()
	names, err := f.Readdirnames(-1)
	if err != nil {
		return nil, false
	}
	out := make([]string, 0, len(names))
	for _, n := range names {
		if n == "." || n == ".." {
			continue
		}
		out = append(out, n)
	}
	return out, true
}

// luciNetdevJSON 是单个设备的属性表（luci.c:670-854）。
func luciNetdevJSON(name string, addrs []cbind.IfAddr) map[string]any {
	obj := map[string]any{"name": name}

	// bridge（luci.c:670-698）：brif 目录能打开 → bridge=1 + ports + id + stp
	if ports, ok := luciListDir("/sys/class/net/" + name + "/brif"); ok {
		obj["bridge"] = 1
		obj["ports"] = ports
		obj["id"] = luciReadSys("/sys/class/net/" + name + "/bridge/bridge_id")
		stp := 0
		if luciReadSys("/sys/class/net/"+name+"/bridge/stp_state") != "0" {
			stp = 1
		}
		obj["stp"] = stp
	}

	// master（readlink 的 basename，luci.c:700-706）
	if link, err := os.Readlink("/sys/class/net/" + name + "/master"); err == nil {
		obj["master"] = link[strings.LastIndex(link, "/")+1:]
	}

	wireless := 0
	if luciReadSys("/sys/class/net/"+name+"/phy80211/index") != "" {
		wireless = 1
	}
	obj["wireless"] = wireless

	operstate := luciReadSys("/sys/class/net/" + name + "/operstate")
	up := 0
	if operstate == "up" || operstate == "unknown" {
		up = 1
	}
	obj["up"] = up

	if mtu, err := strconv.ParseUint(luciReadSys("/sys/class/net/"+name+"/mtu"), 10, 64); err == nil && mtu > 0 {
		obj["mtu"] = int64(mtu)
	}
	if qlen, err := strconv.ParseUint(luciReadSys("/sys/class/net/"+name+"/tx_queue_len"), 10, 64); err == nil && qlen > 0 {
		obj["qlen"] = int64(qlen)
	}

	// devtype（luci.c:726-738）：uevent 里的 DEVTYPE= 行，缺省 "ethernet"
	devtype := "ethernet"
	uevent := luciReadSys("/sys/class/net/" + name + "/uevent")
	if idx := strings.Index(uevent, "DEVTYPE="); idx >= 0 {
		rest := uevent[idx+len("DEVTYPE="):]
		if nl := strings.IndexByte(rest, '\n'); nl >= 0 {
			devtype = rest[:nl]
		} else {
			devtype = rest
		}
	}
	obj["devtype"] = devtype

	// v4/v6 地址（luci.c:740-772），顺带把 flags OR 起来（luci.c:768/789）
	var ifaFlags uint32
	for _, fi := range []struct {
		family uint32
		key    string
	}{{2, "ipaddrs"}, {10, "ip6addrs"}} {
		arr := make([]any, 0, 2)
		for i := range addrs {
			a := &addrs[i]
			if a.Name != name || uint32(a.Family) != fi.family {
				continue
			}
			entry := map[string]any{"address": a.Addr}
			if a.Netmask != "" {
				entry["netmask"] = a.Netmask
			}
			if a.DstAddr != "" && uint32(a.Flags)&luciIFFPointToPoint != 0 {
				entry["remote"] = a.DstAddr
			} else if a.DstAddr != "" && uint32(a.Flags)&luciIFFBroadcast != 0 {
				entry["broadcast"] = a.DstAddr
			}
			arr = append(arr, entry)
			ifaFlags |= a.Flags
		}
		obj[fi.key] = arr
	}

	// PACKET 信息（luci.c:774-809）：mac/type/ifindex/parent，只取第一个匹配项
	for i := range addrs {
		a := &addrs[i]
		if a.Name != name || a.Family != 17 {
			continue
		}
		if a.HAType == 1 {
			obj["mac"] = a.MAC
		}
		obj["type"] = a.HAType
		obj["ifindex"] = a.IfIndex

		// parent（luci.c:791-806）：iflink != ifindex 时找对应设备名
		if iflink, err := strconv.ParseInt(luciReadSys("/sys/class/net/"+name+"/iflink"), 10, 64); err == nil && int(iflink) != a.IfIndex {
			for j := range addrs {
				p := &addrs[j]
				if p.Family != 17 || p.IfIndex != int(iflink) {
					continue
				}
				obj["parent"] = p.Name
				break
			}
		}
		break // 只取第一个 PACKET 匹配（luci.c:808）
	}

	// stats（luci.c:811-820）
	stats := map[string]any{}
	for _, sn := range []string{
		"rx_bytes", "tx_bytes", "tx_errors", "rx_errors", "tx_packets",
		"rx_packets", "multicast", "collisions", "rx_dropped", "tx_dropped",
	} {
		v, _ := strconv.ParseUint(luciReadSys("/sys/class/net/"+name+"/statistics/"+sn), 10, 64)
		stats[sn] = int64(v)
	}
	obj["stats"] = stats

	// flags（luci.c:822-830）
	obj["flags"] = map[string]any{
		"up":           luciBit(ifaFlags, luciIFFUp),
		"broadcast":    luciBit(ifaFlags, luciIFFBroadcast),
		"promisc":      luciBit(ifaFlags, luciIFFPromisc),
		"loopback":     luciBit(ifaFlags, luciIFFLoopback),
		"noarp":        luciBit(ifaFlags, luciIFFNoARP),
		"multicast":    luciBit(ifaFlags, luciIFFMulticast),
		"pointtopoint": luciBit(ifaFlags, luciIFFPointToPoint),
	}

	// link（luci.c:832-854）
	link := map[string]any{}
	if speed := luciReadSys("/sys/class/net/" + name + "/speed"); speed != "" {
		if v, err := strconv.ParseInt(speed, 10, 64); err == nil {
			link["speed"] = v
		}
	}
	if duplex := luciReadSys("/sys/class/net/" + name + "/duplex"); duplex != "" {
		link["duplex"] = duplex
	}
	carrier, _ := strconv.ParseInt(luciReadSys("/sys/class/net/"+name+"/carrier"), 10, 64)
	if carrier == 1 {
		link["carrier"] = 1
	} else {
		link["carrier"] = 0
	}
	changes, _ := strconv.ParseInt(luciReadSys("/sys/class/net/"+name+"/carrier_changes"), 10, 64)
	link["changes"] = changes
	upCount, _ := strconv.ParseInt(luciReadSys("/sys/class/net/"+name+"/carrier_up_count"), 10, 64)
	link["up_count"] = upCount
	downCount, _ := strconv.ParseInt(luciReadSys("/sys/class/net/"+name+"/carrier_down_count"), 10, 64)
	link["down_count"] = downCount
	obj["link"] = link

	return obj
}

func luciBit(v, mask uint32) int {
	if v&mask != 0 {
		return 1
	}
	return 0
}

// luciRPCNetworkDevices 对齐 luci.c:860-896：/sys/class/net 每个设备一张表。
// getifaddrs 失败也继续（只是没有地址信息）。
func luciRPCNetworkDevices() (string, int) {
	addrs := cbind.GetIfaddrs()

	doc := map[string]any{}
	if names, ok := luciListDir("/sys/class/net"); ok {
		for _, n := range names {
			doc[n] = luciNetdevJSON(n, addrs)
		}
	}
	return marshalNoEscape(doc), StatusOK
}

// ---------------------------------------------------------------------------
// getWirelessDevices（luci.c:1098-1190）
// ---------------------------------------------------------------------------

// luciDecodeJSON 用 UseNumber 解码，保留整数原样（避免 float64 精度/格式漂移）。
func luciDecodeJSON(s string) (any, bool) {
	dec := json.NewDecoder(strings.NewReader(s))
	dec.UseNumber()
	var v any
	if err := dec.Decode(&v); err != nil {
		return nil, false
	}
	return v, true
}

// luciInvokeExternal 同步调用外部 ubus 对象（netifd 的 network.wireless / network.rrdns）。
// 返回 (回复 JSON, 对象是否存在, ubus 返回码)；found=false 表示 lookup 失败（对象不存在）。
// 私有总线模式下系统对象挂在系统总线上，故用 sysConn()。
func luciInvokeExternal(obj, method, paramsJSON string) (string, bool, int) {
	ubusMu.Lock()
	defer ubusMu.Unlock()

	ctx := sysConn()
	if ctx == nil {
		return "", false, StatusConnectionFailed
	}
	id, e := ctx.LookupID(obj)
	if e != 0 {
		return "", false, e
	}
	reply, ret := ctx.Invoke(id, method, paramsJSON, "")
	return reply, true, ret
}

// luciRPCWirelessDevices 对齐 luci.c:1098-1190：代理 network.wireless status，
// 重塑时丢掉所有 iwinfo 键，再按接口/radio 各补一份 iwinfo。
func luciRPCWirelessDevices() (string, int) {
	raw, found, ret := luciInvokeExternal("network.wireless", "status", "")
	if !found {
		return "", StatusNotFound // 上游：invoke_ubus 起不来 → NOT_FOUND（:1187）
	}
	if ret != 0 || raw == "" {
		return "", StatusUnknownError
	}

	decoded, ok := luciDecodeJSON(raw)
	if !ok {
		return "", StatusUnknownError
	}
	statusObj, ok := decoded.(map[string]any)
	if !ok {
		return "", StatusUnknownError
	}

	out := make(map[string]any, len(statusObj))
	for radioName, radioVal := range statusObj {
		radio, ok := radioVal.(map[string]any)
		if !ok {
			continue // 上游只收 table（:1108-1110）
		}
		rOut := make(map[string]any, len(radio))
		firstIfname := "" // 上游：第一个能取到 iwinfo 的接口名（:1151）
		for k, v := range radio {
			if k == "iwinfo" {
				continue // :1120-1122
			}
			if k == "interfaces" {
				arr, ok := v.([]any)
				if !ok {
					continue // 类型不对 → 跳过整个键（:1124-1125）
				}
				iOut := make([]any, 0, len(arr))
				for _, ifaceVal := range arr {
					iface, ok := ifaceVal.(map[string]any)
					if !ok {
						continue // 只收 table（:1132-1133）
					}
					clean := make(map[string]any, len(iface))
					ifname := ""
					for ik, iv := range iface {
						if ik == "iwinfo" {
							continue // :1143-1144
						}
						if ik == "ifname" {
							if s, isStr := iv.(string); isStr {
								ifname = s
							}
						}
						clean[ik] = iv
					}
					// 接口级 iwinfo（phy_only=false）；第一个成功的 ifname 给 radio 级用
					if ifname != "" {
						if iw, ok := cbind.IwinfoJSON(ifname, false); ok {
							if pv, ok := luciDecodeJSON(iw); ok {
								clean["iwinfo"] = pv
								if firstIfname == "" {
									firstIfname = ifname
								}
							}
						}
					}
					iOut = append(iOut, clean)
				}
				rOut["interfaces"] = iOut
				continue
			}
			rOut[k] = v // 其余属性原样拷贝（blobmsg_add_blob，:1158-1160）
		}

		// radio 级 iwinfo（phy_only=true）：没有接口能取到时用 radio 名试（:1163-1165）
		radioDev := firstIfname
		if radioDev == "" {
			radioDev = radioName
		}
		if iw, ok := cbind.IwinfoJSON(radioDev, true); ok {
			if pv, ok := luciDecodeJSON(iw); ok {
				rOut["iwinfo"] = pv
			}
		}

		out[radioName] = rOut
	}

	return marshalNoEscape(out), StatusOK
}

// ---------------------------------------------------------------------------
// getHostHints（luci.c:1192-1828）
//
// 五个来源按优先级合并（数字越大越靠前）：
//   netlink 邻居表 10、/etc/ethers 50、dhcp 租约 100、getifaddrs 200、uci 静态租约 250
//
// 两个上游行为要照抄（golden 对比会看到）：
//  1. uci 静态租约的 `ip` 实际从不生效（见 Odin linux.odin 文件头注释 1）——只贡献 MAC + hostname。
//  2. rrdns 补主机名：v6 只在缺主机名时填，v4 覆盖；对象不存在时静默跳过。
// ---------------------------------------------------------------------------

const (
	luciPrioNL          = 10
	luciPrioEther       = 50
	luciPrioLeasefile   = 100
	luciPrioIfaddrs     = 200
	luciPrioStaticLease = 250
)

type luciHintAddr struct {
	af   int // 4 / 6
	prio int
	addr string
}

type luciHint struct {
	hostname string
	v4       []luciHintAddr
	v6       []luciHintAddr
}

// luciHintGet 取（或建）一个 MAC 的 hint。
func luciHintGet(hints map[string]*luciHint, mac string) *luciHint {
	if h, ok := hints[mac]; ok {
		return h
	}
	h := &luciHint{}
	hints[mac] = h
	return h
}

// luciAddrBytes 地址的字节日表示（比较用；IPv4 顶级 4 字节，IPv6 16 字节）。
func luciAddrBytes(af int, addr string) []byte {
	ip := net.ParseIP(addr)
	if ip == nil {
		return nil
	}
	if af == 4 {
		return ip.To4()
	}
	if !strings.Contains(addr, ":") {
		return nil
	}
	return ip.To16()
}

// luciHintAddAddr 对齐 luci.c:1279-1320：同族同地址去重，只有更高优先级才更新。
func luciHintAddAddr(h *luciHint, af, prio int, addr string) {
	list := &h.v4
	if af != 4 {
		list = &h.v6
	}
	for i := range *list {
		if (*list)[i].addr != addr {
			continue
		}
		if prio > (*list)[i].prio {
			(*list)[i].prio = prio
		}
		return
	}
	*list = append(*list, luciHintAddr{af: af, prio: prio, addr: addr})
}

// luciHintSort 插入排序：prio DESC，同 prio 比地址字节 ASC（luci.c:1219-1234）。
func luciHintSort(list []luciHintAddr) {
	for i := 1; i < len(list); i++ {
		cur := list[i]
		j := i - 1
		for j >= 0 {
			other := list[j]
			less := false
			if cur.prio != other.prio {
				less = cur.prio > other.prio
			} else {
				a := luciAddrBytes(cur.af, cur.addr)
				b := luciAddrBytes(other.af, other.addr)
				if a != nil && b != nil && len(a) == len(b) {
					cmp := 0
					for k := 0; k < len(a); k++ {
						if a[k] != b[k] {
							cmp = int(a[k]) - int(b[k])
							break
						}
					}
					less = cmp < 0
				}
			}
			if !less {
				break
			}
			list[j+1] = other
			j--
		}
		list[j+1] = cur
	}
}

// --- 来源 1：netlink 邻居表（luci.c:1236-1425）-----------------------------

func luciGetHostHintsNL(hints map[string]*luciHint) {
	for _, nb := range cbind.GetNeighbors() {
		mac := luciRPCParseMAC(nb.MAC)
		if mac == "" {
			continue
		}
		af := 4
		if strings.Contains(nb.IP, ":") {
			af = 6
		}
		luciHintAddAddr(luciHintGet(hints, mac), af, luciPrioNL, nb.IP)
	}
}

// --- 来源 2/3/5：/etc/ethers、dhcp 租约、uci 静态租约 ----------------------

func luciGetHostHintsEther(hints map[string]*luciHint) {
	data, err := os.ReadFile("/etc/ethers")
	if err != nil {
		return // 文件不存在：直接跳过（luci.c:1434-1437）
	}
	for _, line := range strings.Split(string(data), "\n") {
		f := strings.Fields(line)
		if len(f) < 1 {
			continue
		}
		mac := luciRPCParseMAC(f[0])
		if mac == "" {
			continue
		}
		h := luciHintGet(hints, mac)
		if len(f) < 2 {
			continue
		}
		// 第二个字段是 v4 → 当地址加（prio 50）；否则当主机名（luci.c:1446-1456）
		if luciRPCValidIP4(f[1]) {
			luciHintAddAddr(h, 4, luciPrioEther, f[1])
		} else if h.hostname == "" {
			h.hostname = f[1]
		}
	}
}

func luciGetHostHintsUCI(hints map[string]*luciHint) {
	// 静态租约（dhcp config 的 host section，prio 250）
	// 注意：`ip` 照抄上游**不生效**（见本节头注释 1）。
	if sections, ok := uciConfigSections("dhcp"); ok {
		for i := range sections {
			s := &sections[i]
			if s.TypeName != "host" {
				continue
			}
			name := ""
			var macs []string
			for _, o := range s.Options {
				switch o.Name {
				case "name":
					if len(o.Values) > 0 {
						name = o.Values[0]
					}
				case "mac":
					if o.IsList {
						macs = o.Values
					} else if len(o.Values) > 0 {
						// 单一字符串里可以有空格分隔的多个 MAC（luci.c:1523-1527）
						macs = strings.Fields(o.Values[0])
					}
				}
			}
			for _, m := range macs {
				mac := luciRPCParseMAC(m)
				if mac == "" {
					continue
				}
				h := luciHintGet(hints, mac)
				if name != "" && h.hostname == "" {
					h.hostname = name
				}
			}
		}
	}

	// dhcp 租约文件（prio 100，luci.c:1555-1575）
	now := time.Now().Unix()
	for _, f := range luciRPCLeaseFiles() {
		data, err := os.ReadFile(f.path)
		if err != nil {
			continue
		}
		for _, e := range luciRPCParseLeases(string(data), f.odhcpd, now) {
			if e.mac == "" {
				continue
			}
			h := luciHintGet(hints, e.mac)
			if e.addr != "" {
				luciHintAddAddr(h, e.af, luciPrioLeasefile, e.addr)
			}
			if e.hostname != "" && h.hostname == "" {
				h.hostname = e.hostname
			}
		}
	}
}

// --- 来源 4：getifaddrs（luci.c:1584-1658）--------------------------------

func luciGetHostHintsIfaddrs(hints map[string]*luciHint) {
	addrs := cbind.GetIfaddrs()
	if addrs == nil {
		return
	}

	// 按设备名聚合：MAC（AF_PACKET）+ 第一个 v4 + 第一个 v6
	type luciHintDevice struct{ mac, v4, v6 string }
	devices := map[string]*luciHintDevice{}

	for i := range addrs {
		a := &addrs[i]
		d := devices[a.Name]
		if d == nil {
			d = &luciHintDevice{}
			devices[a.Name] = d
		}
		switch a.Family {
		case 17: // AF_PACKET
			if a.HALen == 6 && d.mac == "" {
				d.mac = a.MAC
			}
		case 10: // AF_INET6
			if d.v6 == "" {
				d.v6 = a.Addr
			}
		case 2: // AF_INET
			if d.v4 == "" {
				d.v4 = a.Addr
			}
		}
	}

	for _, d := range devices {
		if d.mac == "" || (d.v4 == "" && d.v6 == "") {
			continue
		}
		h := luciHintGet(hints, d.mac)
		if d.v4 != "" {
			luciHintAddAddr(h, 4, luciPrioIfaddrs, d.v4)
		}
		if d.v6 != "" {
			luciHintAddAddr(h, 6, luciPrioIfaddrs, d.v6)
		}
	}
}

// --- 收尾：rrdns（可选）+ 组装回复（luci.c:1709-1808）---------------------

// luciHintV6RRDNSOK：非 ::（未指定）、非 link-local（fe80::/10）、非 ULA（fc00::/7）。
func luciHintV6RRDNSOK(addr string) bool {
	b := luciAddrBytes(6, addr)
	if b == nil {
		return false
	}
	unspecified := true
	for _, v := range b {
		if v != 0 {
			unspecified = false
			break
		}
	}
	if unspecified {
		return false
	}
	if b[0] == 0xfe && (b[1]&0xc0) == 0x80 {
		return false
	}
	if (b[0] & 0xfe) == 0xfc {
		return false
	}
	return true
}

// luciHostHintsRRDNS 对齐 luci.c:1709-1808：一次 network.rrdns lookup 把主机名补进 hint。
func luciHostHintsRRDNS(hints map[string]*luciHint) {
	addrs := make([]string, 0, 8)
	for _, h := range hints {
		for _, a := range h.v4 {
			addrs = append(addrs, a.addr)
		}
		for _, a := range h.v6 {
			if luciHintV6RRDNSOK(a.addr) {
				addrs = append(addrs, a.addr)
			}
		}
	}
	if len(addrs) == 0 {
		return
	}

	params := marshalNoEscape(map[string]any{
		"addrs":   addrs,
		"timeout": 250,
		"limit":   len(addrs),
	})
	raw, found, ret := luciInvokeExternal("network.rrdns", "lookup", params)
	if !found || ret != 0 || raw == "" {
		return // 对象不存在 / 调用失败：静默跳过（上游同）
	}

	decoded, ok := luciDecodeJSON(raw)
	if !ok {
		return
	}
	obj, ok := decoded.(map[string]any)
	if !ok {
		return
	}

	// 回复是 {地址: 主机名}：v6 只在缺主机名时填，v4 覆盖（luci.c:1680-1701）
	for addrKey, val := range obj {
		name, isStr := val.(string)
		if !isStr || name == "" {
			continue
		}
		for _, h := range hints {
			for _, a := range h.v6 {
				if a.addr == addrKey {
					if h.hostname == "" {
						h.hostname = name
					}
					break
				}
			}
			for _, a := range h.v4 {
				if a.addr == addrKey {
					h.hostname = name
					break
				}
			}
		}
	}
}

// luciRPCHostHints 对齐 luci.c:1192-1828：五源合并后以 MAC 为键输出。
func luciRPCHostHints() (string, int) {
	hints := map[string]*luciHint{}

	luciGetHostHintsNL(hints)
	luciGetHostHintsUCI(hints)
	luciGetHostHintsEther(hints)
	luciGetHostHintsIfaddrs(hints)
	luciHostHintsRRDNS(hints) // rrdns 补主机名（对象不存在就跳过）

	out := make(map[string]any, len(hints))
	for mac, h := range hints {
		luciHintSort(h.v4)
		luciHintSort(h.v6)

		obj := map[string]any{}
		v4 := make([]any, 0, len(h.v4))
		for _, a := range h.v4 {
			v4 = append(v4, a.addr)
		}
		obj["ipaddrs"] = v4
		v6 := make([]any, 0, len(h.v6))
		for _, a := range h.v6 {
			v6 = append(v6, a.addr)
		}
		obj["ip6addrs"] = v6
		if h.hostname != "" {
			obj["name"] = h.hostname
		}
		out[mac] = obj
	}

	return marshalNoEscape(out), StatusOK
}
