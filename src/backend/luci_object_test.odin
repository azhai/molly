package backend

// luci-rpc 对象的单元测试（移植 internal/backend/luci_object_test.go 在 darwin 上可断言的部分）。
//
// 与 Go 版差异：Odin 无 t.Setenv，改用 os.set_env；写 /tmp/molly-*.leases 需要可写 /tmp
// （真机与 CI 的 linux 有；本机跑测试时若 /tmp 只读需给测试进程可写权限）。
// 板级 fixture 走默认路径 tests/fixtures/board.json（`odin test` 的 cwd 是仓库根）。

import "core:testing"
import "core:mem"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:encoding/json"

// 每个 @(test) 过程内联 arena（context.allocator 在被调过程里赋值不回传调用方）。

@(test)
test_luci_duid2ea :: proc(t: ^testing.T) {
	backing: [262144]u8
	ar: mem.Arena
	mem.arena_init(&ar, backing[:])
	context.allocator = mem.arena_allocator(&ar)

	// DUID-LLT（00010001 前缀，28 位 hex）：MAC 在偏移 16
	testing.expect_value(t, luci_duid2ea("00010001" + "00004c1f" + "aabbccddeeff"), "aa:bb:cc:dd:ee:ff")
	// DUID-EN/LL（00030001 前缀，20 位 hex）：MAC 在偏移 8
	testing.expect_value(t, luci_duid2ea("00030001" + "aabbccddeeff"), "aa:bb:cc:dd:ee:ff")
	// 非 hex / 其它前缀与长度 / 空串 → 无 MAC
	testing.expect_value(t, luci_duid2ea("zzzz"), "")
	testing.expect_value(t, luci_duid2ea("00020001aabbccddeeff"), "")
	testing.expect_value(t, luci_duid2ea(""), "")
}

@(test)
test_luci_parse_dnsmasq_line :: proc(t: ^testing.T) {
	backing: [262144]u8
	ar: mem.Arena
	mem.arena_init(&ar, backing[:])
	context.allocator = mem.arena_allocator(&ar)

	now: i64 = 1_000_000

	// 常规 v4：ts > now → 剩余秒
	e, ok := luci_parse_dnsmasq_line("1000100 aa:bb:cc:dd:ee:ff 192.168.1.123 host1 01:22:33:44:55:66", now)
	testing.expectf(t, ok, "常规 v4 行应解析成功")
	testing.expect_value(t, e.af, 4)
	testing.expect_value(t, e.expire, i64(100))
	testing.expect_value(t, e.mac, "aa:bb:cc:dd:ee:ff")
	testing.expect_value(t, e.addr, "192.168.1.123")
	testing.expect_value(t, e.hostname, "host1")
	testing.expect_value(t, e.duid, "012233445566") // 去冒号

	// ts == 0 → 永久（-1）；v4 的 clientid 是 "01:<mac>"（20 位）→ MAC 不改写、duid 清空
	e, ok = luci_parse_dnsmasq_line("0 11:22:33:44:55:66 192.168.1.50 printer 01:11:22:33:44:55:66", now)
	testing.expectf(t, ok, "永久行应解析成功")
	testing.expect_value(t, e.expire, i64(-1))
	testing.expect_value(t, e.mac, "11:22:33:44:55:66")
	testing.expect_value(t, e.duid, "")

	// "*" 的 hostname 与 clientid → 缺省
	e, ok = luci_parse_dnsmasq_line("1000101 aa:bb:cc:dd:ee:ff 192.168.1.124 * *", now)
	testing.expectf(t, ok, "通配行应解析成功")
	testing.expect_value(t, e.hostname, "")
	testing.expect_value(t, e.duid, "")
	testing.expect_value(t, e.mac, "aa:bb:cc:dd:ee:ff")

	// v6 地址（无 MAC 合法）；ip 先按 v6 试
	e, ok = luci_parse_dnsmasq_line("1000102 aa:bb:cc:dd:ee:ff fd00::1234 host6 *", now)
	testing.expectf(t, ok, "v6 行应解析成功")
	testing.expect_value(t, e.af, 6)
	testing.expect_value(t, e.addr, "fd00::1234")

	// v4 且 MAC 非法 → 跳行
	_, ok = luci_parse_dnsmasq_line("1000103 zz:yy 192.168.1.125 host *", now)
	testing.expectf(t, !ok, "v4 且 MAC 非法应跳行")

	// 非法 IP → 跳行
	_, ok = luci_parse_dnsmasq_line("1000104 aa:bb:cc:dd:ee:ff not-an-ip host *", now)
	testing.expectf(t, !ok, "非法 IP 应跳行")
}

@(test)
test_luci_parse_odhcpd_line :: proc(t: ^testing.T) {
	backing: [262144]u8
	ar: mem.Arena
	mem.arena_init(&ar, backing[:])
	context.allocator = mem.arena_allocator(&ar)

	now: i64 = 1_000_000

	// v6 形态：iaid 是 DUID 类型段
	e, ok := luci_parse_odhcpd_line("# br-lan 0001000100004c1faabbccddeeff 1 host6 1000100 0 128 fd00::1234/fd00::1235", now)
	testing.expectf(t, ok, "v6 odhcpd 行应解析成功")
	testing.expect_value(t, e.af, 6)
	testing.expect_value(t, e.iface, "br-lan")
	testing.expect_value(t, e.duid, "0001000100004c1faabbccddeeff")
	testing.expect_value(t, e.iaid, "1")
	testing.expect_value(t, e.expire, i64(100))
	testing.expect_value(t, e.addr, "fd00::1234") // 只取第一个
	testing.expect_value(t, e.mac, "aa:bb:cc:dd:ee:ff") // duid2ea 兜底

	// ipv4 形态：第二字段是 MAC
	e, ok = luci_parse_odhcpd_line("# br-lan aa:bb:cc:dd:ee:ff ipv4 host4 1000100 0 32 192.168.1.200", now)
	testing.expectf(t, ok, "v4 odhcpd 行应解析成功")
	testing.expect_value(t, e.af, 4)
	testing.expect_value(t, e.mac, "aa:bb:cc:dd:ee:ff")
	testing.expect_value(t, e.duid, "")
	testing.expect_value(t, e.iaid, "")
	testing.expect_value(t, e.addr, "192.168.1.200")

	// ts < 0 → 永久；hostname "-" → 缺省
	e, ok = luci_parse_odhcpd_line("# br-lan 0001000100aabbccddee 1 - -1 0 128 fd00::9999", now)
	testing.expectf(t, ok, "永久 odhcpd 行应解析成功")
	testing.expect_value(t, e.expire, i64(-1))
	testing.expect_value(t, e.hostname, "")

	// 没有 "#" 前缀 → 跳行
	_, ok = luci_parse_odhcpd_line("br-lan x y z 1 0 128 fd00::1", now)
	testing.expectf(t, !ok, "无 # 前缀应跳行")
}

@(test)
test_luci_expire_rules :: proc(t: ^testing.T) {
	backing: [262144]u8
	ar: mem.Arena
	mem.arena_init(&ar, backing[:])
	context.allocator = mem.arena_allocator(&ar)

	// dnsmasq：ts == 0 → -1（永久）
	testing.expect_value(t, luci_expire_dnsmasq(0, 1_000_000), i64(-1))
	// odhcpd：ts == 0 → 0（已过期）
	testing.expect_value(t, luci_expire_odhcpd(0, 1_000_000), i64(0))
	// 两者：未到期 → 剩余
	testing.expect_value(t, luci_expire_dnsmasq(1_000_100, 1_000_000), i64(100))
	testing.expect_value(t, luci_expire_odhcpd(1_000_100, 1_000_000), i64(100))
}

// luci_reply_obj —— 断言 reply 是 JSON 对象并返回（status 由调用方先断言）。
luci_reply_obj :: proc(t: ^testing.T, reply: string) -> json.Object {
	v, err := json.parse_string(reply, .JSON, true, context.allocator)
	testing.expectf(t, err == nil, "reply 解析失败: %v (%s)", err, reply)
	o, ok := v.(json.Object)
	testing.expectf(t, ok, "reply 不是对象: %s", reply)
	return o
}

// luci_lease0 :: proc(t, obj: json.Object, key: string) -> json.Object —— 取 xxx_leases 数组的第 0 条对象。
luci_lease0 :: proc(t: ^testing.T, obj: json.Object, key: string) -> json.Object {
	lv, has := obj[key]
	testing.expectf(t, has, "缺 %s", key)
	arr, is_arr := lv.(json.Array)
	testing.expectf(t, is_arr && len(arr) == 1, "%s 期望 1 条，实际 %v", key, lv)
	el, is_obj := arr[0].(json.Object)
	testing.expectf(t, is_obj, "%s[0] 不是对象", key)
	return el
}

// luci_str_field :: proc —— 断言对象里的字符串字段。
luci_str_field :: proc(t: ^testing.T, obj: json.Object, key, want: string) {
	v, has := obj[key]
	testing.expectf(t, has, "缺字段 %s", key)
	s, is_str := v.(json.String)
	testing.expectf(t, is_str && string(s) == want, "字段 %s = %v，期望 %q", key, v, want)
}

@(test)
test_luci_call_dhcp_leases :: proc(t: ^testing.T) {
	backing: [262144]u8
	ar: mem.Arena
	mem.arena_init(&ar, backing[:])
	context.allocator = mem.arena_allocator(&ar)
	alloc := context.allocator

	// 板级 fixture（默认 tests/fixtures/board.json，cwd 是仓库根；显式设 env 双保险）。
	os.set_env("GOMOLLY_BOARD_JSON", "tests/fixtures/board.json")

	// 写 fakeUCI(dhcp) 里 leasefile 指向的两个文件（与 platform_hooks.odin 的 _ucis_dhcp 对齐）。
	v4 := "4000000000 aa:bb:cc:dd:ee:ff 192.168.1.123 phone 01:11:22:33:44:55:66\n"
	v6 := "# br-lan 0001000100004c1faabbccddeeff 1 host6 4000000000 0 128 fd00::1234\n"
	werr := os.write_entire_file("/tmp/molly-dhcp.leases", v4)
	testing.expectf(t, werr == nil, "写 v4 租约文件失败: %v", werr)
	werr = os.write_entire_file("/tmp/molly-odhcpd.leases", v6)
	testing.expectf(t, werr == nil, "写 v6 租约文件失败: %v", werr)

	// family=4：只有 dhcp_leases，且不含 v6 条目
	st, reply := Dispatch(alloc, "luci-rpc", "getDHCPLeases", `{"family":4}`)
	testing.expect_value(t, st, Status_OK)
	obj := luci_reply_obj(t, reply)
	_, has6 := obj["dhcp6_leases"]
	testing.expectf(t, !has6, "family=4 不应有 dhcp6_leases")
	l0 := luci_lease0(t, obj, "dhcp_leases")
	luci_str_field(t, l0, "ipaddr", "192.168.1.123")
	luci_str_field(t, l0, "hostname", "phone")
	ev, eok := l0["expires"].(json.Integer)
	testing.expectf(t, eok && ev > 0, "expires = %v，期望 > 0", l0["expires"])

	// family=6：只有 dhcp6_leases
	st, reply = Dispatch(alloc, "luci-rpc", "getDHCPLeases", `{"family":6}`)
	testing.expect_value(t, st, Status_OK)
	obj = luci_reply_obj(t, reply)
	_, has4 := obj["dhcp_leases"]
	testing.expectf(t, !has4, "family=6 不应有 dhcp_leases")
	l0 = luci_lease0(t, obj, "dhcp6_leases")
	luci_str_field(t, l0, "ip6addr", "fd00::1234")
	luci_str_field(t, l0, "interface", "br-lan")

	// 非法 family → 2
	st, _ = Dispatch(alloc, "luci-rpc", "getDHCPLeases", `{"family":5}`)
	testing.expect_value(t, st, Status_Invalid_Argument)

	// getBoardJSON：走 fixture
	st, reply = Dispatch(alloc, "luci-rpc", "getBoardJSON", "")
	testing.expect_value(t, st, Status_OK)
	testing.expectf(t, strings.contains(reply, "Molly Mock Board"), "board reply 不含板名: %q", reply)

	// getDUIDHints：只收 v6+duid，按 duid%iaid 去重
	st, reply = Dispatch(alloc, "luci-rpc", "getDUIDHints", "{}")
	testing.expect_value(t, st, Status_OK)
	obj = luci_reply_obj(t, reply)
	testing.expect_value(t, len(obj), 1)
	hv, hok := obj["0001000100004c1faabbccddeeff%1"]
	testing.expectf(t, hok, "缺 key duid%%iaid，实际 %v", obj)
	h0, is_obj := hv.(json.Object)
	testing.expectf(t, is_obj, "hint 不是对象")
	luci_str_field(t, h0, "interface", "br-lan")
	luci_str_field(t, h0, "duid", "0001000100004c1faabbccddeeff")
	luci_str_field(t, h0, "iaid", "1")
	luci_str_field(t, h0, "hostname", "host6")
	luci_str_field(t, h0, "macaddr", "aa:bb:cc:dd:ee:ff")

	// 设备绑定的三个方法 → 8；未知方法 → 3
	extras := [3]string{"getNetworkDevices", "getWirelessDevices", "getHostHints"}
	for m in extras {
		st, _ = Dispatch(alloc, "luci-rpc", m, "{}")
		testing.expectf(t, st == Status_Not_Supported, "%s 期望 8，实际 %d", m, st)
	}
	st, _ = Dispatch(alloc, "luci-rpc", "getLocaltime", "{}")
	testing.expect_value(t, st, Status_Method_Not_Found)
}
