package backend

// luci-rpc 对象 —— molly 自持的 ubus 对象之一（对齐 Odin 版 src/backend/luci_object.odin）。
//
// 对象名是 **`luci-rpc`**（luci.c:2043），6 方法：文件/解析驱动的
// getBoardJSON / getDHCPLeases / getDUIDHints，与设备绑定的 getNetworkDevices /
// getWirelessDevices / getHostHints。**本文件只放平台无关的部分**；板级文件路径与
// 设备绑定走平台钩子（luci_darwin.go 回 StatusNotSupported，luci_linux.go M4 fail-closed，
// M5 接真实现）。
//
// 要点（照抄 Odin）：
//   - 这些方法**没有 ACL 检查**（上游 policy 里 luci 对象没有 session 字段，handler 也不查）。
//   - getBoardJSON：读板级描述文件（provider），失败/非 JSON → 9。
//   - getDHCPLeases：leasefile 发现走 uci `dhcp` config（dnsmasq/odhcpd section 的
//     `leasefile` option，回退 /tmp/dhcp.leases、/tmp/odhcpd.leases）；family 0/4/6，
//     其它整数 → 2，**非整数类型按缺省 0 处理**（blobmsg 的 policy 行为）。

import (
	"encoding/json"
	"os"
	"strconv"
	"strings"
	"time"
)

// callLuciRPC 实现 luci-rpc 对象的 6 个方法。返回 (reply, status)：
// status==0 成功，reply 是 JSON 文本（可为 ""）；status!=0 是 ubus 状态码。
func callLuciRPC(method, paramsJSON string) (string, int) {
	var params map[string]json.RawMessage
	if len(paramsJSON) > 0 {
		if err := json.Unmarshal([]byte(paramsJSON), &params); err != nil {
			params = nil
		}
	}

	switch method {
	case "getBoardJSON":
		return luciRPCGetBoardJSON()
	case "getDHCPLeases":
		return luciRPCGetDHCPLeases(params)
	case "getDUIDHints":
		return luciRPCGetDUIDHints()
	case "getNetworkDevices":
		return luciRPCNetworkDevices()
	case "getWirelessDevices":
		return luciRPCWirelessDevices()
	case "getHostHints":
		return luciRPCHostHints()
	}
	return "", StatusMethodNotFound
}

// luciGetFeatures 是 `luci` 对象的 getFeatures（rpcd-mod-luci 的 luci_get_features）。
//
// LuCI 前端在渲染导航**之前**调它，拿不到就整站报
// "RPC call to luci/getFeatures failed"，菜单一个都不出来。所以这一条是 molly
// 自持的：不依赖 rpcd 在不在。
//
// 值按目标设备的事实：ImmortalWrt 25.12 用 uci、不用 sysrepo → luci-sysrepo 为 false。
// 其余方法（getInitList / getMountPoints / getCPUInfo …）仍归 rpcd，见 internal_objects.go
// 的 `case "luci"`——只抢这一条，别把整个对象接过来。
func luciGetFeatures() (string, int) {
	return `{"features":{"luci-sysrepo":false}}`, StatusOK
}

// ---------------------------------------------------------------------------
// 租约模型与解析助手（纯函数，now 由调用方注入便于测试）
// ---------------------------------------------------------------------------

// luciRPCLeaseFile 是一个租约文件及其格式（odhcpd 行与 dnsmasq 行解析不同）。
type luciRPCLeaseFile struct {
	path   string
	odhcpd bool
}

// luciRPCLease 是上游 lease_entry 的等价物（只留回复要用的字段；地址只回第一个）。
type luciRPCLease struct {
	af       int    // 4 / 6
	expire   int64  // -1 = 永久
	iface    string // 空 = 无（dnsmasq 行没有 interface）
	hostname string
	mac      string // "aa:bb:cc:dd:ee:ff" 小写；空 = 无
	duid     string
	iaid     string
	addr     string // 第一个地址（上游 :2000 只回 addr[0]）
}

// luciRPCParseMAC 是 ether_aton 的等价解析：`aa:bb:cc:dd:ee:ff`（6 组、每组 2 个 hex、
// 冒号分隔）。成功返回小写规范化串，失败返回空。
func luciRPCParseMAC(s string) string {
	if len(s) != 17 {
		return ""
	}
	out := make([]byte, 17)
	for i := 0; i < 17; i++ {
		c := s[i]
		if i%3 == 2 {
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
			out[i] = c - 'A' + 'a'
		default:
			return ""
		}
	}
	return string(out)
}

// luciRPCDUID2EA 对齐 luci.c:296-330 duid2ea：入参是**已去冒号**的纯 hex 串。
// len 28 且前缀 00010001 → 偏移 16 的 6 字节；len 20 且前缀 00030001 → 偏移 8。
func luciRPCDUID2EA(duid string) string {
	if len(duid) == 0 {
		return ""
	}
	for i := 0; i < len(duid); i++ {
		c := duid[i]
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')) {
			return ""
		}
	}
	switch len(duid) {
	case 28:
		if duid[:8] == "00010001" {
			return luciRPCParseMAC(luciRPCDUIDtoMAC(duid[16:28]))
		}
	case 20:
		if duid[:8] == "00030001" {
			return luciRPCParseMAC(luciRPCDUIDtoMAC(duid[8:20]))
		}
	}
	return ""
}

// luciRPCDUIDtoMAC 把 12 个 hex 字符渲染成 "xx:xx:xx:xx:xx:xx"。
func luciRPCDUIDtoMAC(hex12 string) string {
	out := make([]byte, 17)
	for i := 0; i < 6; i++ {
		out[i*3] = hex12[i*2]
		out[i*3+1] = hex12[i*2+1]
		if i < 5 {
			out[i*3+2] = ':'
		}
	}
	return string(out)
}

// luciRPCStripColons 去掉串中所有 ':'。
func luciRPCStripColons(s string) string {
	out := make([]byte, 0, len(s))
	for i := 0; i < len(s); i++ {
		if s[i] != ':' {
			out = append(out, s[i])
		}
	}
	return string(out)
}

// luciRPCValidIP4 严格 IPv4：a.b.c.d，每段 0-255。
func luciRPCValidIP4(s string) bool {
	parts := strings.Split(s, ".")
	if len(parts) != 4 {
		return false
	}
	for _, p := range parts {
		if len(p) == 0 || len(p) > 3 {
			return false
		}
		n := 0
		for i := 0; i < len(p); i++ {
			c := p[i]
			if c < '0' || c > '9' {
				return false
			}
			n = n*10 + int(c-'0')
		}
		if n > 255 {
			return false
		}
	}
	return true
}

// luciRPCValidIP6：至少两个 ':' 且只含 hex/':'。上游用 inet_pton 严格校验——这里放宽
// 只影响「跳过非法行」的判定，租约文件是机器写的，风险可控（偏离记文档）。
func luciRPCValidIP6(s string) bool {
	colons := 0
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c == ':' {
			colons++
			continue
		}
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')) {
			return false
		}
	}
	return colons >= 2 && len(s) >= 2
}

// luciRPCExpireDnsmasq：dnsmasq（luci.c:567-574）：n>now → n-now；n>0 → 0；n==0 → -1（永久）。
func luciRPCExpireDnsmasq(n, now int64) int64 {
	if n > now {
		return n - now
	}
	if n > 0 {
		return 0
	}
	return -1
}

// luciRPCExpireOdhcpd：odhcpd（luci.c:525-531）：n>now → n-now；n>=0 → 0；n<0 → -1。
func luciRPCExpireOdhcpd(n, now int64) int64 {
	if n > now {
		return n - now
	}
	if n >= 0 {
		return 0
	}
	return -1
}

// luciRPCParseTS 解析一个带可选负号的十进制整数（对应上游 strtol/strtoul 的用法）。
func luciRPCParseTS(s string) (int64, bool) {
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
	var n int64
	for ; i < len(s); i++ {
		c := s[i]
		if c < '0' || c > '9' {
			return 0, false
		}
		n = n*10 + int64(c-'0')
	}
	if neg {
		n = -n
	}
	return n, true
}

// luciRPCParseDnsmasqLine 解析 dnsmasq 租约行（luci.c:561-634）：`ts mac ip hostname clientid`。
func luciRPCParseDnsmasqLine(line string, now int64) (luciRPCLease, bool) {
	var e luciRPCLease
	f := strings.Fields(line)
	if len(f) < 5 {
		return e, false
	}

	ts, ok := luciRPCParseTS(f[0])
	if !ok {
		return e, false
	}
	e.expire = luciRPCExpireDnsmasq(ts, now)
	e.mac = luciRPCParseMAC(f[1])

	if luciRPCValidIP6(f[2]) {
		e.af = 6
	} else if luciRPCValidIP4(f[2]) {
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
	switch {
	case e.af == 4 && len(duid) > 15 && duid[:3] == "ff:":
		// ff:<iaid-4-bytes>:<duid-x-bytes...>（冒号分隔）
		e.iaid = luciRPCStripColons(duid[3:14])
		e.duid = luciRPCStripColons(duid[15:])
	case e.af == 4 && len(duid) == 20 && duid[:3] == "01:":
		// 01:<mac-addr>：只在行内 MAC 字段解析失败时才用它兜底（上游 `if (!ea)`，:621）
		if e.mac == "" {
			e.mac = luciRPCParseMAC(duid[3:])
		}
		e.duid = ""
	case duid == "*":
		e.duid = ""
	default:
		e.duid = luciRPCStripColons(duid)
	}

	// luci.c:609-610 / :624-625
	if e.hostname == "*" {
		e.hostname = ""
	}
	// mac 兜底（luci.c:630-634）
	if e.mac == "" && e.duid != "" {
		e.mac = luciRPCDUID2EA(e.duid)
	}
	return e, true
}

// luciRPCParseOdhcpdLine 解析 odhcpd 租约行（luci.c:489-560）：
// `# iface duid_or_mac iaid_or_"ipv4" name ts id length addr/addr/…`。
func luciRPCParseOdhcpdLine(line string, now int64) (luciRPCLease, bool) {
	var e luciRPCLease
	f := strings.Fields(line)
	if len(f) < 8 || f[0] != "#" {
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
		e.mac = luciRPCParseMAC(id2)
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

	ts, ok := luciRPCParseTS(tsS)
	if !ok {
		return e, false
	}
	e.expire = luciRPCExpireOdhcpd(ts, now)

	// length 非 0 覆盖 mask（对回复无影响，但解析要照做以保持跳行行为一致）
	luciRPCParseTS(length)

	// 地址按 '/' 与空白切（strtok 的分隔符集合），逐个校验（luci.c:543-548）
	for _, a := range f[8:] {
		for _, piece := range strings.Split(a, "/") {
			if e.af == 6 && luciRPCValidIP6(piece) {
				if e.addr == "" {
					e.addr = piece
				}
			} else if e.af == 4 && luciRPCValidIP4(piece) {
				if e.addr == "" {
					e.addr = piece
				}
			}
		}
	}

	// mac 兜底（luci.c:550-554）
	if e.mac == "" && e.duid != "" {
		e.mac = luciRPCDUID2EA(e.duid)
	}
	return e, true
}

// luciRPCLeaseJSON 把一条租约转成 JSON 对象（字段顺序照上游：
// expires/interface/hostname/macaddr/duid/iaid/ipaddr；Go map 输出按键排序，语义等价）。
func luciRPCLeaseJSON(e luciRPCLease) map[string]any {
	obj := map[string]any{}
	// 上游 expire==-1 时 blobmsg_add_u8(expires, 0)——与「已过期」同形（:1978-1982）
	if e.expire == -1 {
		obj["expires"] = 0
	} else {
		obj["expires"] = e.expire
	}
	if e.iface != "" {
		obj["interface"] = e.iface
	}
	if e.hostname != "" {
		obj["hostname"] = e.hostname
	}
	if e.mac != "" {
		obj["macaddr"] = e.mac
	}
	if e.duid != "" {
		obj["duid"] = e.duid
	}
	if e.iaid != "" {
		obj["iaid"] = e.iaid
	}
	if e.addr != "" {
		key := "ipaddr"
		if e.af != 4 {
			key = "ip6addr"
		}
		obj[key] = e.addr
	}
	return obj
}

// luciRPCParseLeases 解析一个租约文件的全部行（逐行调对应的 parser）。
func luciRPCParseLeases(content string, isOdhcpd bool, now int64) []luciRPCLease {
	out := make([]luciRPCLease, 0, 8)
	for _, lineFull := range strings.Split(content, "\n") {
		line := strings.TrimSpace(lineFull)
		if line == "" {
			continue
		}
		var (
			e  luciRPCLease
			ok bool
		)
		if isOdhcpd {
			e, ok = luciRPCParseOdhcpdLine(line, now)
		} else {
			e, ok = luciRPCParseDnsmasqLine(line, now)
		}
		if ok {
			out = append(out, e)
		}
	}
	return out
}

// ---------------------------------------------------------------------------
// 方法
// ---------------------------------------------------------------------------

// luciRPCGetBoardJSON 对齐 luci.c:1895 附近 rpc_luci_get_board_json：把板级描述文件
// 原样作为回复；打不开/不是 JSON（或空对象）→ 9。
func luciRPCGetBoardJSON() (string, int) {
	data, err := os.ReadFile(luciRPCBoardPath())
	if err != nil {
		return "", StatusUnknownError
	}
	text := string(data)

	// 上游经 blobmsg_add_json_from_file：不是合法 JSON 就失败。这里只校验，
	// 回复仍用原文本（语义等价：blobmsg 重渲染只改空白）。
	var dummy any
	if err := json.Unmarshal(data, &dummy); err != nil {
		return "", StatusUnknownError
	}
	obj, isObj := dummy.(map[string]any)
	if !isObj || len(obj) == 0 {
		return "", StatusUnknownError
	}
	return text, StatusOK
}

// luciRPCLeaseFiles 是 leasefile 发现（luci.c:394-473）：uci dhcp config 的
// dnsmasq/odhcpd section。找不到对应 section 时回退 /tmp/dhcp.leases 与 /tmp/odhcpd.leases。
func luciRPCLeaseFiles() []luciRPCLeaseFile {
	files := make([]luciRPCLeaseFile, 0, 4)

	foundV4 := false
	foundV6 := false
	if sections, ok := uciConfigSections("dhcp"); ok {
		for i := range sections {
			s := &sections[i]
			path, has := sectionOptionString(s, "leasefile")
			if !has || path == "" {
				continue
			}
			switch s.TypeName {
			case "dnsmasq":
				files = append(files, luciRPCLeaseFile{path: path, odhcpd: false})
				foundV4 = true
			case "odhcpd":
				files = append(files, luciRPCLeaseFile{path: path, odhcpd: true})
				foundV6 = true
			}
		}
	}
	if !foundV4 {
		files = append(files, luciRPCLeaseFile{path: "/tmp/dhcp.leases", odhcpd: false})
	}
	if !foundV6 {
		files = append(files, luciRPCLeaseFile{path: "/tmp/odhcpd.leases", odhcpd: true})
	}
	return files
}

// luciRPCGetDHCPLeases 对齐 luci.c:1937-2027 rpc_luci_get_dhcp_leases。
func luciRPCGetDHCPLeases(params map[string]json.RawMessage) (string, int) {
	family := 0
	if raw, has := params["family"]; has {
		// blobmsg policy：非整数类型不当成错误，按缺省（family 0）处理。
		n := 0
		if b := firstNonSpace(raw); b == '-' || (b >= '0' && b <= '9') {
			var num json.Number
			if err := json.Unmarshal(raw, &num); err == nil {
				if iv, perr := strconv.ParseInt(num.String(), 10, 64); perr == nil {
					n = int(iv)
				}
			}
		}
		switch n {
		case 0, 4, 6:
			family = n
		default:
			return "", StatusInvalidArgument
		}
	}

	now := time.Now().Unix()

	doc := map[string]any{}
	for _, af := range []int{4, 6} {
		if family != 0 && family != af {
			continue
		}
		key := "dhcp6_leases"
		if af == 4 {
			key = "dhcp_leases"
		}
		arr := make([]any, 0, 4)

		// 与上游对齐：所有文件都解析，逐条按 af 过滤（lease_next + handler 的过滤）
		for _, f := range luciRPCLeaseFiles() {
			data, err := os.ReadFile(f.path)
			if err != nil {
				continue // add_leasefile fopen 失败 → 跳过
			}
			for _, e := range luciRPCParseLeases(string(data), f.odhcpd, now) {
				if e.af != af {
					continue
				}
				arr = append(arr, luciRPCLeaseJSON(e))
			}
		}
		doc[key] = arr
	}

	return marshalNoEscape(doc), StatusOK
}

// luciRPCGetDUIDHints 对齐 luci.c:1831-1900 附近 getDUIDHints：只取 v6 且有 duid 的租约，
// 按 key 去重（`duid` 或 `duid%iaid`），回复是以 key 为键的对象。
func luciRPCGetDUIDHints() (string, int) {
	now := time.Now().Unix()

	doc := map[string]any{}
	seen := map[string]bool{}

	for _, f := range luciRPCLeaseFiles() {
		data, err := os.ReadFile(f.path)
		if err != nil {
			continue
		}
		for _, e := range luciRPCParseLeases(string(data), f.odhcpd, now) {
			if e.af != 6 || e.duid == "" {
				continue
			}

			// 上游的 key：duid（无 iaid）或 duid%iaid（luci.c:1855-1859）
			key := e.duid
			if e.iaid != "" {
				key = e.duid + "%" + e.iaid
			}
			if seen[key] {
				continue
			}
			seen[key] = true

			obj := map[string]any{"duid": e.duid}
			if e.iface != "" {
				obj["interface"] = e.iface
			}
			if e.iaid != "" {
				obj["iaid"] = e.iaid
			}
			if e.hostname != "" {
				obj["hostname"] = e.hostname
			}
			if e.mac != "" {
				obj["macaddr"] = e.mac
			}
			doc[key] = obj
		}
	}

	return marshalNoEscape(doc), StatusOK
}
