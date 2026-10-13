package backend

import "core:testing"
import "core:mem"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:encoding/json"

// uc_params —— 把 sid 注入参数串首位。字面量花括号转义 {{ }}，rest 里的花括号作为数据插入（安全）。
uc_params :: proc(sid, rest: string) -> string {
	return fmt.tprintf(`{{"ubus_rpc_session":"%s",%s}}`, sid, rest)
}

// uci_test_get —— 按路径取值并转成可比较文本；取不到给显眼哨兵。
uci_test_get :: proc(alloc: mem.Allocator, reply: string, segs: []string) -> string {
	cur, err := json.parse_string(reply, .JSON, true, alloc)
	if err != nil {
		return "<parse error>"
	}
	for seg in segs {
		obj, is_obj := cur.(json.Object)
		if !is_obj {
			return "<not object>"
		}
		v, found := obj[seg]
		if !found {
			return "<missing>"
		}
		cur = v
	}
	if s, ok := cur.(json.String); ok {
		return string(s)
	}
	if b, ok := cur.(json.Boolean); ok {
		return b ? "true" : "false"
	}
	if n, ok := cur.(json.Integer); ok {
		return fmt.tprintf("%d", i64(n))
	}
	if f, ok := cur.(json.Float); ok {
		return fmt.tprintf("%d", i64(f))
	}
	if arr, ok := cur.(json.Array); ok {
		sb := strings.builder_make_none(alloc)
		first := true
		for e in arr {
			if s, is_str := e.(json.String); is_str {
				if !first {
					strings.write_string(&sb, ",")
				}
				strings.write_string(&sb, string(s))
				first = false
			}
		}
		return strings.to_string(sb)
	}
	return "<other>"
}

check_get :: proc(t: ^testing.T, alloc: mem.Allocator, reply, want: string, segs: ..string) {
	got := uci_test_get(alloc, reply, segs)
	testing.expectf(t, got == want, "取 %v 期望 %q，实际 %q", segs, want, got)
}

check_status :: proc(t: ^testing.T, alloc: mem.Allocator, method, params: string, want: i32) {
	st, _ := Dispatch(alloc, "uci", method, params)
	testing.expectf(t, st == want, "callUCI(%q,%s)=%d，期望 %d", method, params, st, want)
}

// ---------------------------------------------------------------------------
// 名称校验
// ---------------------------------------------------------------------------

@(test)
test_uci_verify :: proc(t: ^testing.T) {
	cases := []struct { kind: u8, text: string, want: bool }{
		{'n', "lan", true}, {'n', "lan_2", true}, {'n', "_x", true}, {'n', "", false},
		{'n', "lan-x", false}, {'n', "a b", false}, {'n', "lan[0]", false},
		{'t', "interface", true}, {'t', "wifi-iface", true}, {'t', "wifi-iface[0]", false},
		{'s', "lan", true}, {'s', "@interface[0]", true}, {'s', "@interface[12]", true},
		{'s', "@interface[]", false}, {'s', "@interface[-1]", false}, {'s', "@interface[0]x", false},
		{'s', "@[0]", true},
	}
	for c in cases {
		got := false
		if c.kind == 'n' {
			got = uci_verify_name(c.text)
		} else if c.kind == 't' {
			got = uci_verify_type(c.text)
		} else {
			got = uci_verify_section(c.text)
		}
		testing.expectf(t, got == c.want, "verify_%c(%q)=%v，期望 %v", c.kind, c.text, got, c.want)
	}
}

// ---------------------------------------------------------------------------
// match / dump / find
// ---------------------------------------------------------------------------

mobj :: proc(alloc: mem.Allocator, text: string) -> json.Object {
	v, err := json.parse_string(text, .JSON, true, alloc)
	assert(err == nil, text)
	o, ok := v.(json.Object)
	assert(ok, text)
	return o
}

@(test)
test_uci_match :: proc(t: ^testing.T) {
	backing: [262144]u8
	ar: mem.Arena
	mem.arena_init(&ar, backing[:])
	old := context.allocator
	context.allocator = mem.arena_allocator(&ar)
	defer context.allocator = old
	alloc := context.allocator

	plain := Uci_Option{name = "proto", values = []string{"static"}}
	listed := Uci_Option{name = "dns", is_list = true, values = []string{"1.1.1.1", "8.8.8.8"}}
	multi := Uci_Option{name = "ifname", values = []string{"eth0  eth1\teth2"}}

	testing.expect(t, uci_match_option(plain, "static"), "标量 static 命中")
	testing.expect(t, !uci_match_option(plain, "dhcp"), "标量 dhcp 不命中")
	testing.expect(t, uci_match_option(listed, "8.8.8.8"), "list 元素命中")
	testing.expect(t, !uci_match_option(listed, "8.8"), "list 不做前缀匹配")
	testing.expect(t, uci_match_option(multi, "eth0") && uci_match_option(multi, "eth2"), "切词命中")
	testing.expect(t, !uci_match_option(multi, "eth0 eth1"), "整串不命中")

	sec := Uci_Section{
		name = "lan", type_name = "interface",
		options = []Uci_Option{
			{name = "proto", values = []string{"static"}},
			{name = "ifname", values = []string{"br-lan"}},
		},
	}
	testing.expect(t, uci_match_section(sec, "", nil), "nil match 匹配")
	testing.expect(t, uci_match_section(sec, "", mobj(alloc, `{}`)), "空 match 匹配")
	testing.expect(t, uci_match_section(sec, "interface", nil), "type 相等匹配")
	testing.expect(t, !uci_match_section(sec, "wifi-iface", nil), "type 不等不匹配")
	testing.expect(t, uci_match_section(sec, "", mobj(alloc, `{"proto":"static"}`)), "proto=static 匹配")
	testing.expect(t, !uci_match_section(sec, "", mobj(alloc, `{"proto":"dhcp"}`)), "proto=dhcp 不匹配")
	testing.expect(t, !uci_match_section(sec, "", mobj(alloc, `{"nope":"x"}`)), "缺席键不匹配")
	testing.expect(t, uci_match_section(sec, "", mobj(alloc, `{"proto":"static","nope":"x"}`)), "一命中一缺席匹配")
	testing.expect(t, uci_match_section(sec, "", mobj(alloc, `{"proto":"static","ifname":"br-lan"}`)), "两键都命中匹配")
	testing.expect(t, !uci_match_section(sec, "", mobj(alloc, `{"proto":"static","ifname":"eth0"}`)), "有一键不命中不匹配")
	testing.expect(t, !uci_match_section(sec, "", mobj(alloc, `{"proto":1}`)), "数字 1 与 static 不等")
	testing.expect(t, uci_match_section(sec, "", mobj(alloc, `{"proto":1.5}`)), "浮点跳过→empty→匹配")
}

@(test)
test_uci_dump_and_find :: proc(t: ^testing.T) {
	backing: [262144]u8
	ar: mem.Arena
	mem.arena_init(&ar, backing[:])
	old := context.allocator
	context.allocator = mem.arena_allocator(&ar)
	defer context.allocator = old
	alloc := context.allocator

	sec := Uci_Section{
		name = "lan", type_name = "interface",
		options = []Uci_Option{
			{name = "proto", values = []string{"static"}},
			{name = "dns", is_list = true, values = []string{"1.1.1.1", "8.8.8.8"}},
		},
	}
	one := json_unparse(uci_dump_section_json(sec, -1))
	check_get(t, alloc, one, "lan", ".name")
	check_get(t, alloc, one, "interface", ".type")
	check_get(t, alloc, one, "false", ".anonymous")
	check_get(t, alloc, one, "static", "proto")
	check_get(t, alloc, one, "1.1.1.1,8.8.8.8", "dns")
	check_get(t, alloc, one, "<missing>", ".index")

	pkg := json_unparse(uci_dump_package_json([]Uci_Section{sec}, "", nil))
	check_get(t, alloc, pkg, "0", "lan", ".index")
	check_get(t, alloc, pkg, "lan", "lan", ".name")
	check_get(t, alloc, pkg, "static", "lan", "proto")

	anon := Uci_Section{name = "cfg03f1", type_name = "switch", anonymous = true}
	apkg := json_unparse(uci_dump_package_json([]Uci_Section{sec, anon}, "", nil))
	check_get(t, alloc, apkg, "true", "cfg03f1", ".anonymous")
	check_get(t, alloc, apkg, "1", "cfg03f1", ".index")
	check_get(t, alloc, apkg, "switch", "cfg03f1", ".type")

	secs := []Uci_Section{
		{name = "lan", type_name = "interface"},
		{name = "wan", type_name = "interface"},
		{name = "", type_name = "switch", anonymous = true},
	}
	s, ok := uci_find_section(secs, "wan")
	testing.expect(t, ok && s.name == "wan", "具名 wan 命中")
	s1, ok1 := uci_find_section(secs, "@interface[1]")
	testing.expect(t, ok1 && s1.name == "wan", "@interface[1] 应 wan")
	s2, ok2 := uci_find_section(secs, "@switch[0]")
	testing.expect(t, ok2 && s2.anonymous, "@switch[0] 应匿名")
	_, ok3 := uci_find_section(secs, "@interface[2]")
	testing.expect(t, !ok3, "@interface[2] 越界不命中")
	_, ok4 := uci_find_section(secs, "nope")
	testing.expect(t, !ok4, "不存在名字不命中")
	_, ok5 := uci_find_section(secs, "@interface[")
	testing.expect(t, !ok5, "残缺扩展不命中")
}

// ---------------------------------------------------------------------------
// 只读方法
// ---------------------------------------------------------------------------

@(test)
test_uci_readonly :: proc(t: ^testing.T) {
	backing: [262144]u8
	ar: mem.Arena
	mem.arena_init(&ar, backing[:])
	old := context.allocator
	context.allocator = mem.arena_allocator(&ar)
	defer context.allocator = old
	alloc := context.allocator

	st, reply := Dispatch(alloc, "uci", "configs", `{}`)
	testing.expect_value(t, st, Status_OK)
	testing.expect(t, strings.contains(reply, "network") && strings.contains(reply, "system"), "configs 含 network/system")

	st, reply = Dispatch(alloc, "uci", "get", `{"config":"network"}`)
	testing.expect_value(t, st, Status_OK)
	check_get(t, alloc, reply, "static", "values", "lan", "proto")
	check_get(t, alloc, reply, "0", "values", "lan", ".index")
	check_get(t, alloc, reply, "1", "values", "wan", ".index")
	check_get(t, alloc, reply, "2", "values", "wg0", ".index")

	st, reply = Dispatch(alloc, "uci", "get", `{"config":"network","section":"lan"}`)
	testing.expect_value(t, st, Status_OK)
	check_get(t, alloc, reply, "lan", "values", ".name")
	check_get(t, alloc, reply, "<missing>", "values", ".index")

	st, reply = Dispatch(alloc, "uci", "get", `{"config":"network","section":"lan","option":"proto"}`)
	testing.expect_value(t, st, Status_OK)
	check_get(t, alloc, reply, "static", "value")

	st, reply = Dispatch(alloc, "uci", "get", `{"config":"network","section":"@interface[1]"}`)
	testing.expect_value(t, st, Status_OK)
	check_get(t, alloc, reply, "wan", "values", ".name")

	st, reply = Dispatch(alloc, "uci", "get", `{"config":"network","type":"interface"}`)
	testing.expect_value(t, st, Status_OK)
	check_get(t, alloc, reply, "wireguard", "values", "wg0", "proto")
	check_get(t, alloc, reply, "<missing>", "values", ".name")

	st, reply = Dispatch(alloc, "uci", "get", `{"config":"network","match":{"proto":"dhcp"}}`)
	testing.expect_value(t, st, Status_OK)
	check_get(t, alloc, reply, "dhcp", "values", "wan", "proto")
	check_get(t, alloc, reply, "<missing>", "values", "lan", "proto")

	check_status(t, alloc, "get", `{}`, Status_Invalid_Argument)
	check_status(t, alloc, "get", `{"config":"nope"}`, Status_Not_Found)
	check_status(t, alloc, "get", `{"config":"network","section":"nope"}`, Status_Not_Found)
	check_status(t, alloc, "get", `{"config":"network","section":"@interface[9]"}`, Status_Not_Found)
	check_status(t, alloc, "get", `{"config":42}`, Status_Invalid_Argument)

	ms := []string{"state", "revert", "commit"}
	for m in ms {
		check_status(t, alloc, m, `{"config":"network"}`, Status_Not_Supported)
	}
	check_status(t, alloc, "frob", `{}`, Status_Method_Not_Found)
}

// ---------------------------------------------------------------------------
// delta 成型 + changes fixture
// ---------------------------------------------------------------------------

@(test)
test_uci_changes :: proc(t: ^testing.T) {
	backing: [262144]u8
	ar: mem.Arena
	mem.arena_init(&ar, backing[:])
	old := context.allocator
	context.allocator = mem.arena_allocator(&ar)
	defer context.allocator = old
	alloc := context.allocator

	// 完整形态 ["set","lan","ipaddr","10.0.0.1"]
	full := Uci_Change{kind = .Change, section = "lan", name = "ipaddr", value = "10.0.0.1"}
	testing.expect_value(t, json_unparse(uci_dump_change_json(full)), `["set","lan","ipaddr","10.0.0.1"]`)
	testing.expect_value(t, json_unparse(uci_dump_change_json(Uci_Change{kind = .Add, section = "wg1"})), `["add","wg1"]`)
	rm := Uci_Change{kind = .Remove, section = "wan", name = "proto"}
	testing.expect_value(t, json_unparse(uci_dump_change_json(rm)), `["remove","wan","proto"]`)
	ord := Uci_Change{kind = .Reorder, section = "lan", value = "3"}
	testing.expect_value(t, json_unparse(uci_dump_change_json(ord)), `["order","lan",3]`)

	dropped := []Uci_Change{
		{kind = .Change, section = "lan", name = "ipaddr", value = "1"},
		{kind = .Change, name = "ignored"},
	}
	testing.expect_value(t, json_unparse(uci_dump_changes_json(dropped)), `[["set","lan","ipaddr","1"]]`)

	// changes {}（无 sid）→ 只有 network 有 delta
	st, reply := Dispatch(alloc, "uci", "changes", `{}`)
	testing.expect_value(t, st, Status_OK)
	ch, _ := uci_val(alloc, reply)
	obj, _ := ch.(json.Object)
	changes, _ := obj["changes"].(json.Object)
	testing.expect_value(t, len(changes), 1)
	net_arr, is_arr := changes["network"].(json.Array)
	testing.expect(t, is_arr, "network 的 delta 应为数组")
	testing.expect_value(t, len(net_arr), 5)
	first, _ := net_arr[0].(json.Array)
	testing.expect_value(t, len(first), 4)
	testing.expect_value(t, string(first[0].(json.String)), "set")
	testing.expect_value(t, string(first[3].(json.String)), "10.0.0.1")
	o4, _ := net_arr[3].(json.Array)
	testing.expect_value(t, len(o4), 3)
	testing.expect_value(t, string(o4[0].(json.String)), "order")
	_, is_num := o4[2].(json.Integer)
	testing.expect(t, is_num, "order 的 value 应为数字")

	// 给了 config → 数组形态
	st, reply = Dispatch(alloc, "uci", "changes", `{"config":"network"}`)
	testing.expect_value(t, st, Status_OK)
	v, _ := uci_val(alloc, reply)
	oc, _ := v.(json.Object)
	ca, _ := oc["changes"].(json.Array)
	testing.expect_value(t, len(ca), 5)

	// 没有 delta 的 config → 空数组
	st, reply = Dispatch(alloc, "uci", "changes", `{"config":"system"}`)
	testing.expect_value(t, st, Status_OK)
	v2, _ := uci_val(alloc, reply)
	o2, _ := v2.(json.Object)
	c2, is_c2 := o2["changes"].(json.Array)
	testing.expect(t, is_c2 && len(c2) == 0, "changes system 应空数组")

	// 不存在 config → 4
	check_status(t, alloc, "changes", `{"config":"nope"}`, Status_Not_Found)
}

uci_val :: proc(alloc: mem.Allocator, text: string) -> (json.Value, bool) {
	v, err := json.parse_string(text, .JSON, true, alloc)
	return v, err == nil
}

// ---------------------------------------------------------------------------
// 写路径：平台能力 + ACL + 参数校验
// ---------------------------------------------------------------------------

uci_new_session :: proc(t: ^testing.T, alloc: mem.Allocator) -> string {
	st, reply := Dispatch(alloc, "session", "create", `{"timeout":300}`)
	testing.expect_value(t, st, Status_OK)
	v, ok := uci_val(alloc, reply)
	assert(ok)
	o, _ := v.(json.Object)
	s, _ := o["ubus_rpc_session"].(json.String)
	return string(s)
}

@(test)
test_uci_write_paths :: proc(t: ^testing.T) {
	backing: [262144]u8
	ar: mem.Arena
	mem.arena_init(&ar, backing[:])
	old := context.allocator
	context.allocator = mem.arena_allocator(&ar)
	defer context.allocator = old
	alloc := context.allocator

	// 无 sid（内部调用）：state/commit/revert → 8
	ms := []string{"state", "commit", "revert"}
	for m in ms {
		check_status(t, alloc, m, `{"config":"network"}`, Status_Not_Supported)
	}

	// 有 sid 无写权限 → 6（ACL 先于平台能力）
	sid := uci_new_session(t, alloc)
	commit_params := uc_params(sid, `"config":"network"`)
	check_status(t, alloc, "commit", commit_params, Status_Permission_Denied)
	check_status(t, alloc, "revert", commit_params, Status_Permission_Denied)
	check_status(t, alloc, "state", commit_params, Status_Permission_Denied)
	// 缺 config → 2（ACL 之后、平台能力之前）
	check_status(t, alloc, "commit", `{}`, Status_Invalid_Argument)
	Dispatch(alloc, "session", "destroy", uc_params(sid, `"x":1`))
}

@(test)
test_uci_write_validation :: proc(t: ^testing.T) {
	backing: [262144]u8
	ar: mem.Arena
	mem.arena_init(&ar, backing[:])
	old := context.allocator
	context.allocator = mem.arena_allocator(&ar)
	defer context.allocator = old
	alloc := context.allocator

	// 参数校验在 ACL 之前（无 sid 也能测出 2）
	check_status(t, alloc, "set", `{}`, Status_Invalid_Argument)
	check_status(t, alloc, "set", `{"config":"network","values":{"proto":"static"}}`, Status_Invalid_Argument)
	check_status(t, alloc, "set", `{"config":"network","values":[],"section":"lan"}`, Status_Invalid_Argument)
	check_status(t, alloc, "set", `{"config":"network","values":{"a":"b"},"section":"lan[0]"}`, Status_Invalid_Argument)
	check_status(t, alloc, "add", `{"config":"network"}`, Status_Invalid_Argument)
	check_status(t, alloc, "add", `{"config":"network","type":"wifi-iface[0]"}`, Status_Invalid_Argument)
	check_status(t, alloc, "add", `{"config":"network","type":"interface","name":"lan-x"}`, Status_Invalid_Argument)

	// 有 sid 无写权限 → 6
	sid := uci_new_session(t, alloc)
	set_body := uc_params(sid, `"config":"network","values":{"proto":"static"},"section":"lan"`)
	add_body := uc_params(sid, `"config":"network","type":"interface","name":"molly0"`)
	check_status(t, alloc, "set", set_body, Status_Permission_Denied)
	check_status(t, alloc, "add", add_body, Status_Permission_Denied)

	// delete/rename/order 必需参数缺失
	check_status(t, alloc, "delete", `{}`, Status_Invalid_Argument)
	check_status(t, alloc, "delete", `{"config":"network"}`, Status_Invalid_Argument)
	check_status(t, alloc, "rename", `{}`, Status_Invalid_Argument)
	check_status(t, alloc, "rename", `{"config":"network","section":"lan"}`, Status_Invalid_Argument)
	check_status(t, alloc, "order", `{}`, Status_Invalid_Argument)
	check_status(t, alloc, "order", `{"config":"network","sections":"lan"}`, Status_Invalid_Argument)
	// 无 sid 的语法校验
	check_status(t, alloc, "delete", `{"config":"network","type":"wifi-iface[0]"}`, Status_Invalid_Argument)
	check_status(t, alloc, "delete", `{"config":"network","section":"lan[0]"}`, Status_Invalid_Argument)
	check_status(t, alloc, "rename", `{"config":"network","section":"lan","name":"lan-x"}`, Status_Invalid_Argument)

	// 有 sid 无权限 → 6（ACL 先于语法）
	del_body := uc_params(sid, `"config":"network","section":"lan","options":["dns"]`)
	check_status(t, alloc, "delete", del_body, Status_Permission_Denied)
	ren_body := uc_params(sid, `"config":"network","section":"lan","name":"lan2"`)
	check_status(t, alloc, "rename", ren_body, Status_Permission_Denied)
	ord_body := uc_params(sid, `"config":"network","sections":["wan","lan"]`)
	check_status(t, alloc, "order", ord_body, Status_Permission_Denied)

	// 授权写之后：宿主没有写事务 → 8
	st, _ := Dispatch(alloc, "session", "grant", uc_params(sid, `"scope":"uci","objects":[["*","write"]]`))
	testing.expect_value(t, st, Status_OK)
	check_status(t, alloc, "set", set_body, Status_Not_Supported)
	check_status(t, alloc, "add", add_body, Status_Not_Supported)
	check_status(t, alloc, "delete", del_body, Status_Not_Supported)
	check_status(t, alloc, "rename", ren_body, Status_Not_Supported)
	check_status(t, alloc, "order", ord_body, Status_Not_Supported)

	Dispatch(alloc, "session", "destroy", uc_params(sid, `"x":1`))
}

// ---------------------------------------------------------------------------
// apply 系的宿主可达路径
// ---------------------------------------------------------------------------

@(test)
test_uci_apply_neutral :: proc(t: ^testing.T) {
	backing: [262144]u8
	ar: mem.Arena
	mem.arena_init(&ar, backing[:])
	old := context.allocator
	context.allocator = mem.arena_allocator(&ar)
	defer context.allocator = old
	alloc := context.allocator

	check_status(t, alloc, "apply", `{}`, Status_Invalid_Argument)
	check_status(t, alloc, "confirm", `{"ubus_rpc_session":"x"}`, Status_No_Data)
	check_status(t, alloc, "rollback", `{}`, Status_No_Data)
	check_status(t, alloc, "rollback", `{"ubus_rpc_session":"x"}`, Status_No_Data)
	check_status(t, alloc, "apply", fmt.tprintf(`{{"ubus_rpc_session":"%s"}}`, Sess_Default_ID), Status_Not_Found)
	check_status(t, alloc, "reload_config", `{}`, Status_Not_Supported)
}
