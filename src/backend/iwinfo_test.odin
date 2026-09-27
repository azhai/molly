package backend

import "core:c"
import "core:encoding/json"
import "core:mem"
import "core:testing"

// iw_add_bit_array 的等价渲染（luci.c:930-959）：bits==0 用 zero 兜底、按位查名字表、
// 可选转小写。iwinfo 本体只能在设备上跑，但这段纯逻辑可以在这里钉住。
@(test)
test_iwinfo_add_bit_array :: proc(t: ^testing.T) {
	alloc, ar := mk_arena()
	defer drop_arena(ar)

	names := [5]cstring{"NONE", "Open", "PSK", "SAE", "OWE"}

	// 位 1|2 → 取名字并转小写
	obj := make(json.Object, 1, alloc)
	iwinfo_add_bit_array(&obj, "m", u32(0b110), &names[0], 5, true, 0, alloc)
	arr := obj["m"].(json.Array)
	testing.expectf(t, len(arr) == 2, "期望 2 项，实际 %d", len(arr))
	testing.expect(t, string(arr[0].(json.String)) == "open")
	testing.expect(t, string(arr[1].(json.String)) == "psk")

	// bits==0 → 用 zero 兜底（KMGMT/CIPHER 的 NONE 就是这个用法）
	obj = make(json.Object, 1, alloc)
	iwinfo_add_bit_array(&obj, "m", 0, &names[0], 5, true, u32(1) << 0, alloc)
	arr = obj["m"].(json.Array)
	testing.expectf(t, len(arr) == 1, "zero 兜底后应 1 项，实际 %d", len(arr))
	testing.expect(t, string(arr[0].(json.String)) == "none")

	// bits==0 且 zero==0 → 空数组（hwmodes/htmodes 的用法）
	obj = make(json.Object, 1, alloc)
	iwinfo_add_bit_array(&obj, "m", 0, &names[0], 5, false, 0, alloc)
	testing.expect(t, len(obj["m"].(json.Array)) == 0)

	// 不转小写时保留原名
	obj = make(json.Object, 1, alloc)
	iwinfo_add_bit_array(&obj, "m", u32(1) << 3, &names[0], 5, false, 0, alloc)
	arr = obj["m"].(json.Array)
	testing.expect(t, string(arr[0].(json.String)) == "SAE")
}

// 失效保护：布局错位时不能把任意指针当字符串读（只认已知后端名）
@(test)
test_iwinfo_ops_name_guard :: proc(t: ^testing.T) {
	ops: Iwinfo_Ops

	testing.expect(t, !iwinfo_ops_name_ok(nil))
	testing.expect(t, !iwinfo_ops_name_ok(&ops)) // name == nil

	name_buf: [16]u8
	copy(name_buf[:], "nl80211")
	ops.name = rawptr(&name_buf[0])
	testing.expect(t, iwinfo_ops_name_ok(&ops))

	copy(name_buf[:], "wext\x00")
	testing.expect(t, iwinfo_ops_name_ok(&ops))

	copy(name_buf[:], "garbage\x00")
	testing.expect(t, !iwinfo_ops_name_ok(&ops))

	_ = mem.Allocator
}
