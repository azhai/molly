//go:build darwin

package backend

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// luci.c:296-330 duid2ea
func TestLuciRPCDUID2EA(t *testing.T) {
	// DUID-LLT（00010001 前缀，28 位 hex）：MAC 在偏移 16
	if got := luciRPCDUID2EA("00010001" + "00004c1f" + "aabbccddeeff"); got != "aa:bb:cc:dd:ee:ff" {
		t.Errorf("DUID-LLT = %q", got)
	}
	// DUID-EN/LL（00030001 前缀，20 位 hex）：MAC 在偏移 8
	if got := luciRPCDUID2EA("00030001" + "aabbccddeeff"); got != "aa:bb:cc:dd:ee:ff" {
		t.Errorf("DUID-EN/LL = %q", got)
	}
	// 非 hex / 其它前缀与长度 → 无 MAC
	if got := luciRPCDUID2EA("zzzz"); got != "" {
		t.Errorf("非 hex 应回空，实际 %q", got)
	}
	if got := luciRPCDUID2EA("00020001aabbccddeeff"); got != "" {
		t.Errorf("前缀 00020001 应回空，实际 %q", got)
	}
	if got := luciRPCDUID2EA(""); got != "" {
		t.Errorf("空串应回空，实际 %q", got)
	}
}

// luci.c:561-634 dnsmasq 行
func TestLuciRPCParseDnsmasqLine(t *testing.T) {
	const now = 1_000_000

	// 常规 v4：ts > now → 剩余秒
	e, ok := luciRPCParseDnsmasqLine("1000100 aa:bb:cc:dd:ee:ff 192.168.1.123 host1 01:22:33:44:55:66", now)
	if !ok {
		t.Fatal("常规 v4 行应解析成功")
	}
	if e.af != 4 || e.expire != 100 {
		t.Errorf("af/expire = %d/%d", e.af, e.expire)
	}
	if e.mac != "aa:bb:cc:dd:ee:ff" {
		t.Errorf("mac = %q", e.mac)
	}
	if e.addr != "192.168.1.123" {
		t.Errorf("addr = %q", e.addr)
	}
	if e.hostname != "host1" {
		t.Errorf("hostname = %q", e.hostname)
	}
	if e.duid != "012233445566" { // 去冒号
		t.Errorf("duid = %q", e.duid)
	}

	// ts == 0 → 永久（-1）；v4 的 clientid 是 "01:<mac>"（20 位）→ MAC 改写、duid 清空
	e, ok = luciRPCParseDnsmasqLine("0 11:22:33:44:55:66 192.168.1.50 printer 01:11:22:33:44:55:66", now)
	if !ok {
		t.Fatal("永久行应解析成功")
	}
	if e.expire != -1 {
		t.Errorf("expire = %d，期望 -1", e.expire)
	}
	if e.mac != "11:22:33:44:55:66" {
		t.Errorf("mac = %q", e.mac)
	}
	if e.duid != "" {
		t.Errorf("duid = %q，期望空", e.duid)
	}

	// "*" 的 hostname 与 clientid → 缺省
	e, ok = luciRPCParseDnsmasqLine("1000101 aa:bb:cc:dd:ee:ff 192.168.1.124 * *", now)
	if !ok {
		t.Fatal("通配行应解析成功")
	}
	if e.hostname != "" || e.duid != "" || e.mac != "aa:bb:cc:dd:ee:ff" {
		t.Errorf("hostname/duid/mac = %q/%q/%q", e.hostname, e.duid, e.mac)
	}

	// v6 地址（无 MAC 合法）；ip 先按 v6 试
	e, ok = luciRPCParseDnsmasqLine("1000102 aa:bb:cc:dd:ee:ff fd00::1234 host6 *", now)
	if !ok {
		t.Fatal("v6 行应解析成功")
	}
	if e.af != 6 || e.addr != "fd00::1234" {
		t.Errorf("af/addr = %d/%q", e.af, e.addr)
	}

	// v4 且 MAC 非法 → 跳行（luci.c:599-600）
	if _, ok = luciRPCParseDnsmasqLine("1000103 zz:yy 192.168.1.125 host *", now); ok {
		t.Error("v4 且 MAC 非法应跳行")
	}

	// 非法 IP → 跳行
	if _, ok = luciRPCParseDnsmasqLine("1000104 aa:bb:cc:dd:ee:ff not-an-ip host *", now); ok {
		t.Error("非法 IP 应跳行")
	}
}

// luci.c:489-560 odhcpd 行
func TestLuciRPCParseOdhcpdLine(t *testing.T) {
	const now = 1_000_000

	// v6 形态：iaid 是 DUID 类型段
	e, ok := luciRPCParseOdhcpdLine("# br-lan 0001000100004c1faabbccddeeff 1 host6 1000100 0 128 fd00::1234/fd00::1235", now)
	if !ok {
		t.Fatal("v6 odhcpd 行应解析成功")
	}
	if e.af != 6 {
		t.Errorf("af = %d，期望 6", e.af)
	}
	if e.iface != "br-lan" {
		t.Errorf("iface = %q", e.iface)
	}
	if e.duid != "0001000100004c1faabbccddeeff" {
		t.Errorf("duid = %q", e.duid)
	}
	if e.iaid != "1" {
		t.Errorf("iaid = %q", e.iaid)
	}
	if e.expire != 100 {
		t.Errorf("expire = %d，期望 100", e.expire)
	}
	if e.addr != "fd00::1234" { // 只取第一个
		t.Errorf("addr = %q", e.addr)
	}
	if e.mac != "aa:bb:cc:dd:ee:ff" { // duid2ea 兜底
		t.Errorf("mac = %q", e.mac)
	}

	// ipv4 形态：第二字段是 MAC
	e, ok = luciRPCParseOdhcpdLine("# br-lan aa:bb:cc:dd:ee:ff ipv4 host4 1000100 0 32 192.168.1.200", now)
	if !ok {
		t.Fatal("v4 odhcpd 行应解析成功")
	}
	if e.af != 4 {
		t.Errorf("af = %d，期望 4", e.af)
	}
	if e.mac != "aa:bb:cc:dd:ee:ff" {
		t.Errorf("mac = %q", e.mac)
	}
	if e.duid != "" || e.iaid != "" {
		t.Errorf("duid/iaid = %q/%q，期望都为空", e.duid, e.iaid)
	}
	if e.addr != "192.168.1.200" {
		t.Errorf("addr = %q", e.addr)
	}

	// ts < 0 → 永久；hostname "-" → 缺省
	e, ok = luciRPCParseOdhcpdLine("# br-lan 0001000100aabbccddee 1 - -1 0 128 fd00::9999", now)
	if !ok {
		t.Fatal("永久 odhcpd 行应解析成功")
	}
	if e.expire != -1 || e.hostname != "" {
		t.Errorf("expire/hostname = %d/%q", e.expire, e.hostname)
	}

	// 没有 "#" 前缀 → 跳行
	if _, ok = luciRPCParseOdhcpdLine("br-lan x y z 1 0 128 fd00::1", now); ok {
		t.Error("无 # 前缀应跳行")
	}
}

// expire 两条规则的差异（上游照抄的关键点）
func TestLuciRPCExpireRules(t *testing.T) {
	// dnsmasq：ts == 0 → -1（永久）
	if got := luciRPCExpireDnsmasq(0, 1_000_000); got != -1 {
		t.Errorf("dnsmasq(0) = %d，期望 -1", got)
	}
	// odhcpd：ts == 0 → 0（已过期）
	if got := luciRPCExpireOdhcpd(0, 1_000_000); got != 0 {
		t.Errorf("odhcpd(0) = %d，期望 0", got)
	}
	// 两者：未到期 → 剩余
	if got := luciRPCExpireDnsmasq(1_000_100, 1_000_000); got != 100 {
		t.Errorf("dnsmasq(1_000_100) = %d，期望 100", got)
	}
	if got := luciRPCExpireOdhcpd(1_000_100, 1_000_000); got != 100 {
		t.Errorf("odhcpd(1_000_100) = %d，期望 100", got)
	}
}

// luciReply 是测试助手：断言 status 并把 reply 解析成对象。
func luciReply(t *testing.T, reply string, status, wantStatus int) map[string]any {
	t.Helper()
	if status != wantStatus {
		t.Fatalf("status = %d，期望 %d（reply=%q）", status, wantStatus, reply)
	}
	var doc map[string]any
	if err := json.Unmarshal([]byte(reply), &doc); err != nil {
		t.Fatalf("解析 reply 失败: %v（reply=%q）", err, reply)
	}
	return doc
}

// darwin provider（fakeUCI 的 dhcp config + /tmp 租约文件）上的整链。
func TestLuciRPCCallDHCPLeasesDarwin(t *testing.T) {
	// 板级 fixture 在 molly/ 之外，测试进程 cwd 是包目录，用相对路径指回仓库根。
	t.Setenv("GOMOLLY_BOARD_JSON", filepath.Join("..", "..", "tests", "fixtures", "board.json"))

	// 写 darwin fakeUCI 里 leasefile 指向的两个文件
	v4 := "4000000000 aa:bb:cc:dd:ee:ff 192.168.1.123 phone 01:11:22:33:44:55:66\n"
	v6 := "# br-lan 0001000100004c1faabbccddeeff 1 host6 4000000000 0 128 fd00::1234\n"
	if err := os.WriteFile("/tmp/molly-dhcp.leases", []byte(v4), 0o644); err != nil {
		t.Fatalf("写 v4 租约文件失败: %v", err)
	}
	if err := os.WriteFile("/tmp/molly-odhcpd.leases", []byte(v6), 0o644); err != nil {
		t.Fatalf("写 v6 租约文件失败: %v", err)
	}

	// family=4：只有 dhcp_leases，且不含 v6 条目
	reply, st := callLuciRPC("getDHCPLeases", `{"family":4}`)
	obj := luciReply(t, reply, st, StatusOK)
	if _, has := obj["dhcp6_leases"]; has {
		t.Error("family=4 不应有 dhcp6_leases")
	}
	leases, ok := obj["dhcp_leases"].([]any)
	if !ok || len(leases) != 1 {
		t.Fatalf("期望 1 条 v4，实际 %v", obj["dhcp_leases"])
	}
	l0, _ := leases[0].(map[string]any)
	if l0["ipaddr"] != "192.168.1.123" {
		t.Errorf("ipaddr = %v", l0["ipaddr"])
	}
	if l0["hostname"] != "phone" {
		t.Errorf("hostname = %v", l0["hostname"])
	}
	if exp, _ := l0["expires"].(float64); exp <= 0 {
		t.Errorf("expires = %v，期望 > 0", l0["expires"])
	}

	// family=6：只有 dhcp6_leases
	reply, st = callLuciRPC("getDHCPLeases", `{"family":6}`)
	obj = luciReply(t, reply, st, StatusOK)
	if _, has := obj["dhcp_leases"]; has {
		t.Error("family=6 不应有 dhcp_leases")
	}
	leases, ok = obj["dhcp6_leases"].([]any)
	if !ok || len(leases) != 1 {
		t.Fatalf("期望 1 条 v6，实际 %v", obj["dhcp6_leases"])
	}
	l0, _ = leases[0].(map[string]any)
	if l0["ip6addr"] != "fd00::1234" {
		t.Errorf("ip6addr = %v", l0["ip6addr"])
	}
	if l0["interface"] != "br-lan" {
		t.Errorf("interface = %v", l0["interface"])
	}

	// 非法 family → 2
	if _, st = callLuciRPC("getDHCPLeases", `{"family":5}`); st != StatusInvalidArgument {
		t.Errorf("family=5 → %d，期望 2", st)
	}

	// getBoardJSON：走 fixture
	reply, st = callLuciRPC("getBoardJSON", "")
	if st != StatusOK {
		t.Fatalf("getBoardJSON → %d", st)
	}
	if !strings.Contains(reply, "Molly Mock Board") {
		t.Errorf("board reply 不含板名: %q", reply)
	}

	// getDUIDHints：只收 v6+duid，按 duid%iaid 去重
	reply, st = callLuciRPC("getDUIDHints", "{}")
	obj = luciReply(t, reply, st, StatusOK)
	if len(obj) != 1 {
		t.Fatalf("期望 1 条 duid hint，实际 %v", obj)
	}
	hint, has := obj["0001000100004c1faabbccddeeff%1"]
	if !has {
		t.Fatalf("缺 key duid%%iaid，实际 %v", obj)
	}
	h0, _ := hint.(map[string]any)
	if h0["interface"] != "br-lan" {
		t.Errorf("interface = %v", h0["interface"])
	}
	if h0["duid"] != "0001000100004c1faabbccddeeff" {
		t.Errorf("duid = %v", h0["duid"])
	}
	if h0["iaid"] != "1" {
		t.Errorf("iaid = %v", h0["iaid"])
	}
	if h0["hostname"] != "host6" {
		t.Errorf("hostname = %v", h0["hostname"])
	}
	if h0["macaddr"] != "aa:bb:cc:dd:ee:ff" {
		t.Errorf("macaddr = %v", h0["macaddr"])
	}

	// 设备绑定的三个方法 → 8；未知方法 → 3
	for _, m := range []string{"getNetworkDevices", "getWirelessDevices", "getHostHints"} {
		if _, st = callLuciRPC(m, "{}"); st != StatusNotSupported {
			t.Errorf("%s 期望 8，实际 %d", m, st)
		}
	}
	if _, st = callLuciRPC("getLocaltime", "{}"); st != StatusMethodNotFound {
		t.Errorf("getLocaltime 期望 3，实际 %d", st)
	}
}
