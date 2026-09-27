package backend

import "core:encoding/json"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

// luci.c:296-330 duid2ea
@(test)
test_luci_duid2ea :: proc(t: ^testing.T) {
	alloc, ar := mk_arena()
	defer drop_arena(ar)

	// DUID-LLT（00010001 前缀，28 位 hex）：MAC 在偏移 16
	// 00010001 <10 hex 时间/标识> aabbccddeeff
	testing.expect(
		t,
		luci_duid2ea("00010001" + "00004c1f" + "aabbccddeeff", alloc) == "aa:bb:cc:dd:ee:ff",
	)
	// DUID-EN/LL（00030001 前缀，20 位 hex）：MAC 在偏移 8
	testing.expect(t, luci_duid2ea("00030001" + "aabbccddeeff", alloc) == "aa:bb:cc:dd:ee:ff")
	// 非 hex / 其它前缀与长度 → 无 MAC
	testing.expect(t, luci_duid2ea("zzzz", alloc) == "")
	testing.expect(t, luci_duid2ea("00020001aabbccddeeff", alloc) == "")
	testing.expect(t, luci_duid2ea("", alloc) == "")
}

// luci.c:561-634 dnsmasq 行
@(test)
test_luci_parse_dnsmasq_line :: proc(t: ^testing.T) {
	alloc, ar := mk_arena()
	defer drop_arena(ar)

	now := 1_000_000

	// 常规 v4：ts > now → 剩余秒
	e, ok := luci_parse_dnsmasq_line("1000100 aa:bb:cc:dd:ee:ff 192.168.1.123 host1 01:22:33:44:55:66", now, alloc)
	testing.expect(t, ok)
	testing.expect(t, e.af == 4 && e.expire == 100)
	testing.expect(t, e.mac == "aa:bb:cc:dd:ee:ff")
	testing.expect(t, e.addr == "192.168.1.123")
	testing.expect(t, e.hostname == "host1")
	testing.expect(t, e.duid == "012233445566") // 去冒号

	// ts == 0 → 永久（-1）；v4 的 clientid 是 "01:<mac>" → MAC 改写、duid 清空
	e, ok = luci_parse_dnsmasq_line("0 11:22:33:44:55:66 192.168.1.50 printer 01:11:22:33:44:55:66", now, alloc)
	testing.expect(t, ok)
	testing.expect(t, e.expire == -1)
	testing.expect(t, e.mac == "11:22:33:44:55:66")
	testing.expect(t, e.duid == "")

	// "*" 的 hostname 与 clientid → 缺省
	e, ok = luci_parse_dnsmasq_line("1000101 aa:bb:cc:dd:ee:ff 192.168.1.124 * *", now, alloc)
	testing.expect(t, ok)
	testing.expect(t, e.hostname == "" && e.duid == "" && e.mac == "aa:bb:cc:dd:ee:ff")

	// v6 地址（无 MAC 合法）；ip 先按 v6 试
	e, ok = luci_parse_dnsmasq_line("1000102 aa:bb:cc:dd:ee:ff fd00::1234 host6 *", now, alloc)
	testing.expect(t, ok)
	testing.expect(t, e.af == 6 && e.addr == "fd00::1234")

	// v4 且 MAC 非法 → 跳行（luci.c:599-600）
	_, ok = luci_parse_dnsmasq_line("1000103 zz:yy 192.168.1.125 host *", now, alloc)
	testing.expect(t, !ok)

	// 非法 IP → 跳行
	_, ok = luci_parse_dnsmasq_line("1000104 aa:bb:cc:dd:ee:ff not-an-ip host *", now, alloc)
	testing.expect(t, !ok)
}

// luci.c:489-560 odhcpd 行
@(test)
test_luci_parse_odhcpd_line :: proc(t: ^testing.T) {
	alloc, ar := mk_arena()
	defer drop_arena(ar)

	now := 1_000_000

	// v6 形态：iaid 是 DUID 类型段
	e, ok := luci_parse_odhcpd_line("# br-lan 0001000100004c1faabbccddeeff 1 host6 1000100 0 128 fd00::1234/fd00::1235", now, alloc)
	testing.expect(t, ok)
	testing.expect(t, e.af == 6)
	testing.expect(t, e.iface == "br-lan")
	testing.expect(t, e.duid == "0001000100004c1faabbccddeeff")
	testing.expect(t, e.iaid == "1")
	testing.expect(t, e.expire == 100)
	testing.expect(t, e.addr == "fd00::1234") // 只取第一个
	testing.expect(t, e.mac == "aa:bb:cc:dd:ee:ff") // duid2ea 兜底

	// ipv4 形态：第二字段是 MAC
	e, ok = luci_parse_odhcpd_line("# br-lan aa:bb:cc:dd:ee:ff ipv4 host4 1000100 0 32 192.168.1.200", now, alloc)
	testing.expect(t, ok)
	testing.expect(t, e.af == 4)
	testing.expect(t, e.mac == "aa:bb:cc:dd:ee:ff")
	testing.expect(t, e.duid == "" && e.iaid == "")
	testing.expect(t, e.addr == "192.168.1.200")

	// ts < 0 → 永久；hostname "-" → 缺省
	e, ok = luci_parse_odhcpd_line("# br-lan 0001000100aabbccddee 1 - -1 0 128 fd00::9999", now, alloc)
	testing.expect(t, ok)
	testing.expect(t, e.expire == -1 && e.hostname == "")

	// 没有 "#" 前缀 → 跳行
	_, ok = luci_parse_odhcpd_line("br-lan x y z 1 0 128 fd00::1", now, alloc)
	testing.expect(t, !ok)
}

// expire 两条规则的差异（上游照抄的关键点）
@(test)
test_luci_expire_rules :: proc(t: ^testing.T) {
	// dnsmasq：ts == 0 → -1（永久）
	testing.expect(t, luci_expire_dnsmasq(0, 1_000_000) == -1)
	// odhcpd：ts == 0 → 0（已过期）
	testing.expect(t, luci_expire_odhcpd(0, 1_000_000) == 0)
	// 两者：未到期 → 剩余
	testing.expect(t, luci_expire_dnsmasq(1_000_100, 1_000_000) == 100)
	testing.expect(t, luci_expire_odhcpd(1_000_100, 1_000_000) == 100)
}

// darwin provider（FAKE_UCI 的 dhcp config + /tmp 租约文件）上的整链
@(test)
test_luci_call_dhcp_leases_darwin :: proc(t: ^testing.T) {
	alloc, ar := mk_arena()
	defer drop_arena(ar)

	// 写 darwin FAKE_UCI 里 leasefile 指向的两个文件
	v4 := "4000000000 aa:bb:cc:dd:ee:ff 192.168.1.123 phone 01:11:22:33:44:55:66\n"
	v6 := "# br-lan 0001000100004c1faabbccddeeff 1 host6 4000000000 0 128 fd00::1234\n"
	if err := os.write_entire_file("/tmp/molly-dhcp.leases", transmute([]byte)(v4)); err != nil {
		testing.expect(t, false, "写 v4 租约文件失败")
	}
	if err := os.write_entire_file("/tmp/molly-odhcpd.leases", transmute([]byte)(v6)); err != nil {
		testing.expect(t, false, "写 v6 租约文件失败")
	}

	// family=4：只有 dhcp_leases，且不含 v6 条目
	reply, st := luci_call("getDHCPLeases", `{"family":4}`, alloc)
	testing.expectf(t, st == 0, "getDHCPLeases family=4 → %d", st)
	doc: json.Value
	testing.expect(t, json.unmarshal(transmute([]byte)(reply), &doc, .JSON, alloc) == nil)
	obj := doc.(json.Object)
	testing.expect(t, !("dhcp6_leases" in obj))
	leases := obj["dhcp_leases"].(json.Array)
	testing.expectf(t, len(leases) == 1, "期望 1 条 v4，实际 %d", len(leases))
	l0 := leases[0].(json.Object)
	testing.expect(t, l0["ipaddr"].(json.String) == "192.168.1.123")
	testing.expect(t, l0["hostname"].(json.String) == "phone")
	testing.expect(t, int(l0["expires"].(json.Integer)) > 0)

	// family=6：只有 dhcp6_leases
	reply, st = luci_call("getDHCPLeases", `{"family":6}`, alloc)
	testing.expect(t, st == 0)
	testing.expect(t, json.unmarshal(transmute([]byte)(reply), &doc, .JSON, alloc) == nil)
	obj = doc.(json.Object)
	testing.expect(t, !("dhcp_leases" in obj))
	leases = obj["dhcp6_leases"].(json.Array)
	testing.expect(t, len(leases) == 1)
	l0 = leases[0].(json.Object)
	testing.expect(t, l0["ip6addr"].(json.String) == "fd00::1234")
	testing.expect(t, l0["interface"].(json.String) == "br-lan")

	// 非法 family → 2
	_, st = luci_call("getDHCPLeases", `{"family":5}`, alloc)
	testing.expect(t, st == 2)

	// getBoardJSON：走 fixture
	reply, st = luci_call("getBoardJSON", "", alloc)
	testing.expectf(t, st == 0, "getBoardJSON → %d", st)
	testing.expect(t, strings.contains(reply, "Molly Mock Board"))

	// getDUIDHints：只收 v6+duid，按 duid%iaid 去重
	reply, st = luci_call("getDUIDHints", "{}", alloc)
	testing.expectf(t, st == 0, "getDUIDHints → %d", st)
	testing.expect(t, json.unmarshal(transmute([]byte)(reply), &doc, .JSON, alloc) == nil)
	obj = doc.(json.Object)
	// v4 租约（无 duid）不该出现；v6 条目的 key 是 duid%iaid
	testing.expect(t, len(obj) == 1)
	e0, has := obj["0001000100004c1faabbccddeeff%1"]
	testing.expect(t, has)
	l0 = e0.(json.Object)
	testing.expect(t, l0["interface"].(json.String) == "br-lan")
	testing.expect(t, l0["duid"].(json.String) == "0001000100004c1faabbccddeeff")
	testing.expect(t, l0["iaid"].(json.String) == "1")
	testing.expect(t, l0["hostname"].(json.String) == "host6")
	testing.expect(t, l0["macaddr"].(json.String) == "aa:bb:cc:dd:ee:ff")

	// S2b/c/d 的三个方法 → 8；未知方法 → 3
	s2_methods := []string{"getNetworkDevices", "getWirelessDevices", "getHostHints"}
	for m in s2_methods {
		_, st = luci_call(m, "{}", alloc)
		testing.expectf(t, st == 8, "%s 期望 8，实际 %d", m, st)
	}
	_, st = luci_call("getLocaltime", "{}", alloc)
	testing.expect(t, st == 3)

	_ = time.now
}
