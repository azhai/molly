package backend

// P3-3（S1）的单元测试：名称校验、match 语义、dump 形状，以及 `configs`/`get` 的整链。
//
// 这些用例跑在 darwin 的假 config 上（macOS 上 uci_config_sections / uci_list_configs
// 就是 FAKE_UCI），所以断言里的 network/system/lan/wan/wg0 都来自那份假数据。
// 真实 libuci 的行为只有设备上能验（见 docs/testing.md 的覆盖边界）。
//
// 分配：一律用 mk_arena()（backend_test.odin 里的 @(private) 助手，同包可见）——
// odin test 会报告泄漏，不能直接借 context.allocator。

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:time"
import "core:testing"

// 从回复 JSON 里按路径取值并转成可比较的文本：
//   字符串原样；整数十进制；bool "true"/"false"；数组用逗号连接元素
// 取不到时给一个显眼的哨兵，避免把「缺字段」误判成「空字符串」。
@(private)
u_get :: proc(reply: string, path: []string, alloc: mem.Allocator) -> string {
	doc: json.Value
	if json.unmarshal(transmute([]byte)(reply), &doc, .JSON, alloc) != nil {
		return "<parse error>"
	}

	cur := doc
	for key in path {
		obj, is_obj := cur.(json.Object)
		if !is_obj {
			return "<not object>"
		}
		v, found := obj[key]
		if !found {
			return "<missing>"
		}
		cur = v
	}

	#partial switch x in cur {
	case json.String:
		return string(x)
	case json.Integer:
		return fmt.aprintf("%d", i64(x), allocator = alloc)
	case json.Boolean:
		return bool(x) ? "true" : "false"
	case json.Array:
		parts := make([dynamic]string, 0, len(x), alloc)
		for e in x {
			if s, is_str := e.(json.String); is_str {
				append(&parts, string(s))
			}
		}
		return strings.join(parts[:], ",")
	}
	return "<other>"
}

@(private)
u_expect :: proc(t: ^testing.T, reply, path_str, want: string, alloc: mem.Allocator) {
	// 分隔符用 '/'：`.name` 这类特殊键**以 '.' 开头**，用 '.' 分会切出空段。
	// 匿名 section 的键是空串，写法就是路径里的前导 '/'（例：`/.anonymous`）。
	path := strings.split(path_str, "/", alloc)
	got := u_get(reply, path, alloc)
	testing.expectf(t, got == want, "取 %q 期望 %q，实际 %q", path_str, want, got)
}

// 把 match 表文本（JSON）解析成 json.Object；解析不出就 nil。
@(private)
u_match_obj :: proc(text: string, alloc: mem.Allocator) -> json.Object {
	v := parse_json_value(text, alloc)
	o, is_obj := v.(json.Object)
	if !is_obj {
		return nil
	}
	return o
}

@(test)
test_uci_verify :: proc(t: ^testing.T) {
	cases := []struct {
		kind: string, // name | type | section
		text: string,
		want: bool,
	}{
		{"name", "lan", true},
		{"name", "lan_2", true},
		{"name", "_x", true},
		{"name", "", false},
		{"name", "lan-x", false}, // section 名不允许 '-'
		{"name", "a b", false},
		{"name", "lan[0]", false}, // 不以 '@' 开头 → 不按扩展形式解析
		{"type", "interface", true},
		{"type", "wifi-iface", true}, // 类型名允许 '-'
		{"type", "wifi-iface[0]", false},
		{"section", "lan", true},
		{"section", "@interface[0]", true},
		{"section", "@interface[12]", true},
		{"section", "@interface[]", false},
		{"section", "@interface[-1]", false},
		{"section", "@interface[0]x", false},
		{"section", "@[0]", true}, // C 只要求「至少一位数字 + ']' 收尾」，类型名可以为空
	}

	for c in cases {
		got := c.kind == "name" ? uci_verify_name(c.text) : c.kind == "type" ? uci_verify_type(c.text) : uci_verify_section(c.text)
		testing.expectf(t, got == c.want, "verify_%s(%q) = %v，期望 %v", c.kind, c.text, got, c.want)
	}
}

@(test)
test_uci_match_option :: proc(t: ^testing.T) {
	plain := Uci_Option{name = "proto", values = []string{"static"}}
	listed := Uci_Option{name = "dns", is_list = true, values = []string{"1.1.1.1", "8.8.8.8"}}
	multi := Uci_Option{name = "ifname", values = []string{"eth0  eth1\teth2"}}

	testing.expect(t, uci_match_option(plain, "static"))
	testing.expect(t, !uci_match_option(plain, "dhcp"))

	testing.expect(t, uci_match_option(listed, "8.8.8.8"))
	testing.expect(t, !uci_match_option(listed, "8.8"))

	// 字符串型按空格/制表符切词（C 用 strtok(s, " \t")），整串不参与比较
	testing.expect(t, uci_match_option(multi, "eth0"))
	testing.expect(t, uci_match_option(multi, "eth2"))
	testing.expect(t, !uci_match_option(multi, "eth0 eth1"))
}

@(test)
test_uci_match_section :: proc(t: ^testing.T) {
	alloc, ar := mk_arena()
	defer drop_arena(ar)

	sec := Uci_Section {
		name      = "lan",
		type_name = "interface",
		options   = []Uci_Option{
			{name = "proto", values = []string{"static"}},
			{name = "ifname", values = []string{"br-lan"}},
		},
	}

	// 空 match / 缺 match → 匹配
	testing.expect(t, uci_match_section(sec, "", nil, alloc))
	testing.expect(t, uci_match_section(sec, "", u_match_obj(`{}`, alloc), alloc))

	// type 给了就必须相等
	testing.expect(t, uci_match_section(sec, "interface", nil, alloc))
	testing.expect(t, !uci_match_section(sec, "wifi-iface", nil, alloc))

	testing.expect(t, uci_match_section(sec, "", u_match_obj(`{"proto":"static"}`, alloc), alloc))
	testing.expect(t, !uci_match_section(sec, "", u_match_obj(`{"proto":"dhcp"}`, alloc), alloc))

	// 键在 section 里不存在 → 不贡献命中，最终 false（C 的 empty||match）
	testing.expect(t, !uci_match_section(sec, "", u_match_obj(`{"nope":"x"}`, alloc), alloc))
	// 一个键命中就够：缺席的键不否决（C 的 empty||match：proto 命中 → true）
	testing.expect(
		t,
		uci_match_section(sec, "", u_match_obj(`{"proto":"static","nope":"x"}`, alloc), alloc),
	)

	// 多个键都要命中
	testing.expect(
		t,
		uci_match_section(sec, "", u_match_obj(`{"proto":"static","ifname":"br-lan"}`, alloc), alloc),
	)
	testing.expect(
		t,
		!uci_match_section(sec, "", u_match_obj(`{"proto":"static","ifname":"eth0"}`, alloc), alloc),
	)

	// 数字按十进制文本比较；浮点在 C 的 switch 里没有分支 → 整个键被跳过 → empty → true
	testing.expect(t, !uci_match_section(sec, "", u_match_obj(`{"proto":1}`, alloc), alloc))
	testing.expect(t, uci_match_section(sec, "", u_match_obj(`{"proto":1.5}`, alloc), alloc))
}

@(test)
test_uci_dump_shapes :: proc(t: ^testing.T) {
	alloc, ar := mk_arena()
	defer drop_arena(ar)

	sec := Uci_Section {
		name      = "lan",
		type_name = "interface",
		options   = []Uci_Option{
			{name = "proto", values = []string{"static"}},
			{name = "dns", is_list = true, values = []string{"1.1.1.1", "8.8.8.8"}},
		},
	}

	// section 级：三个特殊键 + 选项；**没有** .index
	one := session_marshal(uci_dump_section_json(sec, -1, alloc), alloc)
	u_expect(t, one, ".name", "lan", alloc)
	u_expect(t, one, ".type", "interface", alloc)
	u_expect(t, one, ".anonymous", "false", alloc)
	u_expect(t, one, "proto", "static", alloc)
	u_expect(t, one, "dns", "1.1.1.1,8.8.8.8", alloc)
	u_expect(t, one, ".index", "<missing>", alloc)

	// package 级：带 .index（序号是整份配置里的位置，筛掉的 section 也占号）
	pkg := session_marshal(uci_dump_package_json([]Uci_Section{sec}, "", nil, alloc), alloc)
	u_expect(t, pkg, "lan/.index", "0", alloc)
	u_expect(t, pkg, "lan/.name", "lan", alloc)
	u_expect(t, pkg, "lan/proto", "static", alloc)

	// 匿名 section 的键是它的 section 名。真机上是 libuci 生成的 `cfgXXXXXX`
	// （darwin 的 FAKE_UCI 用空串，那是 fixtures 的既有约定，别在真机 golden 前依赖它）。
	anon := Uci_Section{name = "cfg03f1", type_name = "switch", anonymous = true}
	apkg := session_marshal(uci_dump_package_json([]Uci_Section{sec, anon}, "", nil, alloc), alloc)
	u_expect(t, apkg, "cfg03f1/.anonymous", "true", alloc)
	u_expect(t, apkg, "cfg03f1/.index", "1", alloc)
	u_expect(t, apkg, "cfg03f1/.type", "switch", alloc)
}

@(test)
test_uci_find_section :: proc(t: ^testing.T) {
	secs := []Uci_Section {
		{name = "lan", type_name = "interface"},
		{name = "wan", type_name = "interface"},
		{name = "", type_name = "switch", anonymous = true},
	}

	s, ok := uci_find_section(secs, "wan")
	testing.expect(t, ok && s.name == "wan")

	s1, ok1 := uci_find_section(secs, "@interface[1]")
	testing.expect(t, ok1 && s1.name == "wan")

	s2, ok2 := uci_find_section(secs, "@switch[0]")
	testing.expect(t, ok2 && s2.anonymous)

	_, ok3 := uci_find_section(secs, "@interface[2]")
	testing.expect(t, !ok3)
	_, ok4 := uci_find_section(secs, "nope")
	testing.expect(t, !ok4)
	_, ok5 := uci_find_section(secs, "@interface[")
	testing.expect(t, !ok5)
}

@(test)
test_uci_call_readonly :: proc(t: ^testing.T) {
	alloc, ar := mk_arena()
	defer drop_arena(ar)

	// configs：uci.c:1382-1408，不做 ACL 检查
	reply, status := uci_call("configs", "{}", alloc)
	testing.expect_value(t, status, UCI_STATUS_OK)
	testing.expect(t, strings.contains(reply, `"network"`))
	testing.expect(t, strings.contains(reply, `"system"`))

	// get：package 级 → {"values": {…, ".index": N}}
	reply, status = uci_call("get", `{"config":"network"}`, alloc)
	testing.expect_value(t, status, UCI_STATUS_OK)
	u_expect(t, reply, "values/lan/proto", "static", alloc)
	u_expect(t, reply, "values/lan/.index", "0", alloc)
	u_expect(t, reply, "values/wan/.index", "1", alloc)
	u_expect(t, reply, "values/wg0/.index", "2", alloc)

	// get：section 级 → 不带 .index
	reply, status = uci_call("get", `{"config":"network","section":"lan"}`, alloc)
	testing.expect_value(t, status, UCI_STATUS_OK)
	u_expect(t, reply, "values/.name", "lan", alloc)
	u_expect(t, reply, "values/.index", "<missing>", alloc)

	// get：option 级 → 键是 "value"
	reply, status = uci_call("get", `{"config":"network","section":"lan","option":"proto"}`, alloc)
	testing.expect_value(t, status, UCI_STATUS_OK)
	u_expect(t, reply, "value", "static", alloc)

	// get：扩展形式 @type[idx]
	reply, status = uci_call("get", `{"config":"network","section":"@interface[1]"}`, alloc)
	testing.expect_value(t, status, UCI_STATUS_OK)
	u_expect(t, reply, "values/.name", "wan", alloc)

	// get：type 筛选（匿名 switch section 被筛掉）
	reply, status = uci_call("get", `{"config":"network","type":"interface"}`, alloc)
	testing.expect_value(t, status, UCI_STATUS_OK)
	u_expect(t, reply, "values/wg0/proto", "wireguard", alloc)
	u_expect(t, reply, "values/.name", "<missing>", alloc)

	// get：match 筛选
	reply, status = uci_call("get", `{"config":"network","match":{"proto":"dhcp"}}`, alloc)
	testing.expect_value(t, status, UCI_STATUS_OK)
	u_expect(t, reply, "values/wan/proto", "dhcp", alloc)
	u_expect(t, reply, "values/lan/proto", "<missing>", alloc)

	// 错误分支
	_, status = uci_call("get", `{}`, alloc)
	testing.expect_value(t, status, UCI_STATUS_INVALID_ARGUMENT)
	_, status = uci_call("get", `{"config":"nope"}`, alloc)
	testing.expect_value(t, status, UCI_STATUS_NOT_FOUND)
	_, status = uci_call("get", `{"config":"network","section":"nope"}`, alloc)
	testing.expect_value(t, status, UCI_STATUS_NOT_FOUND)
	_, status = uci_call("get", `{"config":"network","section":"@interface[9]"}`, alloc)
	testing.expect_value(t, status, UCI_STATUS_NOT_FOUND)
	_, status = uci_call("get", `{"config":42}`, alloc)
	testing.expect_value(t, status, UCI_STATUS_INVALID_ARGUMENT)

	// S1 未实现的方法：一律 NOT_SUPPORTED——接管到设备上也不会动 /etc/config
	// 注意：`changes`（S2）、五个写操作（S3）与 apply 系（S4）已是真实现，不在这个集合里
	// ——它们的参数校验/文件检查先于平台能力。见 test_uci_changes_darwin_fixture、
	// test_uci_write_method_validation、test_uci_delete_rename_order_validation 与
	// test_uci_apply_family_neutral_paths。
	for m in ([]string {
		"state",
		"revert",
		"commit",
	}) {
		_, st := uci_call(m, `{"config":"network"}`, alloc)
		testing.expectf(t, st == UCI_STATUS_NOT_SUPPORTED, "%s 应回 NOT_SUPPORTED，实际 %d", m, st)
	}

	// 未知方法 → 3（真机上 libubus 在 handler 之前就回 3）
	_, status = uci_call("frob", `{}`, alloc)
	testing.expect_value(t, status, UCI_STATUS_METHOD_NOT_FOUND)
}

// ---------------------------------------------------------------------------
// P3-3（S2）：changes 的形状、state/commit/revert 的平台能力，以及 savedir 清理
// ---------------------------------------------------------------------------

@(test)
test_uci_dump_change :: proc(t: ^testing.T) {
	alloc, ar := mk_arena()
	defer drop_arena(ar)

	// 完整形态：["set","lan","ipaddr","10.0.0.1"]（uci.c:1205-1219）
	full := Uci_Change{kind = .Change, section = "lan", name = "ipaddr", value = "10.0.0.1"}
	testing.expect_value(
		t,
		session_marshal(uci_dump_change_json(full, alloc), alloc),
		`["set","lan","ipaddr","10.0.0.1"]`,
	)

	// 只有 section
	testing.expect_value(
		t,
		session_marshal(uci_dump_change_json(Uci_Change{kind = .Add, section = "wg1"}, alloc), alloc),
		`["add","wg1"]`,
	)

	// 有 name 没有 value（remove 的形态）
	testing.expect_value(
		t,
		session_marshal(
			uci_dump_change_json(Uci_Change{kind = .Remove, section = "wan", name = "proto"}, alloc),
			alloc,
		),
		`["remove","wan","proto"]`,
	)

	// order 的 value 是**数字**（uci.c:1215-1216 用 blobmsg_add_u32）
	testing.expect_value(
		t,
		session_marshal(uci_dump_change_json(Uci_Change{kind = .Reorder, section = "lan", value = "3"}, alloc), alloc),
		`["order","lan",3]`,
	)

	// 七种 kind → type 字符串
	kinds := []Uci_Change {
		{kind = .Add, section = "s"},
		{kind = .Remove, section = "s"},
		{kind = .Change, section = "s"},
		{kind = .Rename, section = "s"},
		{kind = .Reorder, section = "s"},
		{kind = .List_Add, section = "s"},
		{kind = .List_Del, section = "s"},
	}
	want := []string{"add", "remove", "set", "rename", "order", "list-add", "list-del"}
	for c, i in kinds {
		text := session_marshal(uci_dump_change_json(c, alloc), alloc)
		needle := fmt.aprintf(`"%s"`, want[i], allocator = alloc)
		testing.expectf(t, strings.contains(text, needle), "%v → %s，期望含 %s", c.kind, text, want[i])
	}

	// section 为空的条目整条丢掉（uci.c:1202-1203）
	dropped := []Uci_Change {
		{kind = .Change, section = "lan", name = "ipaddr", value = "1"},
		{kind = .Change, name = "ignored"},
	}
	testing.expect_value(
		t,
		session_marshal(uci_dump_changes_json(dropped, alloc), alloc),
		`[["set","lan","ipaddr","1"]]`,
	)
}

@(test)
test_uci_changes_darwin_fixture :: proc(t: ^testing.T) {
	alloc, ar := mk_arena()
	defer drop_arena(ar)

	// 不带 config：{"changes": {<有 delta 的 config>: [ … ]}}
	reply, status := uci_call("changes", `{}`, alloc)
	testing.expect_value(t, status, UCI_STATUS_OK)

	doc: json.Value
	testing.expect(t, json.unmarshal(transmute([]byte)(reply), &doc, .JSON, alloc) == nil)
	top, is_obj := doc.(json.Object)
	testing.expect(t, is_obj)
	if !is_obj {
		return
	}
	inner, is_inner := top["changes"].(json.Object)
	testing.expect(t, is_inner)
	if !is_inner {
		return
	}
	// 只有 network 有假 delta（darwin 的 FAKE_DELTA）
	testing.expect_value(t, len(inner), 1)
	list, is_list := inner["network"].(json.Array)
	testing.expect(t, is_list)
	if !is_list {
		return
	}
	// 6 条假 delta 里第 6 条 section 为空 → 只剩 5 条
	testing.expect_value(t, len(list), 5)

	first, _ := list[0].(json.Array)
	testing.expect_value(t, len(first), 4)
	testing.expect_value(t, string(first[0].(json.String)), "set")
	testing.expect_value(t, string(first[1].(json.String)), "lan")
	testing.expect_value(t, string(first[2].(json.String)), "ipaddr")
	testing.expect_value(t, string(first[3].(json.String)), "10.0.0.1")

	// 第 4 条是 ["order","lan",3]：value 是数字
	ord, _ := list[3].(json.Array)
	testing.expect_value(t, len(ord), 3)
	testing.expect_value(t, string(ord[0].(json.String)), "order")
	_, is_int := ord[2].(json.Integer)
	testing.expect(t, is_int)

	// 给了 config：直接是数组
	one, st_one := uci_call("changes", `{"config":"network"}`, alloc)
	testing.expect_value(t, st_one, UCI_STATUS_OK)
	testing.expect_value(t, u_get(one, []string{"changes"}, alloc), "")

	doc2: json.Value
	testing.expect(t, json.unmarshal(transmute([]byte)(one), &doc2, .JSON, alloc) == nil)
	o2, _ := doc2.(json.Object)
	arr2, _ := o2["changes"].(json.Array)
	testing.expect_value(t, len(arr2), 5)

	// 没有 delta 的 config → 空数组（不是错误）
	none, st_none := uci_call("changes", `{"config":"system"}`, alloc)
	testing.expect_value(t, st_none, UCI_STATUS_OK)
	doc3: json.Value
	testing.expect(t, json.unmarshal(transmute([]byte)(none), &doc3, .JSON, alloc) == nil)
	o3, _ := doc3.(json.Object)
	arr3, _ := o3["changes"].(json.Array)
	testing.expect_value(t, len(arr3), 0)

	// 不存在的 config → 4
	_, st_bad := uci_call("changes", `{"config":"nope"}`, alloc)
	testing.expect_value(t, st_bad, UCI_STATUS_NOT_FOUND)
}

@(test)
test_uci_write_paths_platform_and_acl :: proc(t: ^testing.T) {
	alloc, ar := mk_arena()
	defer drop_arena(ar)

	// 无 sid（内部调用，不做 ACL）：平台能力决定 —— darwin 上 state/commit/revert 都是 8
	for m in ([]string{"state", "commit", "revert"}) {
		_, st := uci_call(m, `{"config":"network"}`, alloc)
		testing.expectf(t, st == UCI_STATUS_NOT_SUPPORTED, "%s 在 darwin 应回 8，实际 %d", m, st)
	}

	// 有 sid 但没有写权限 → 6：ACL 检查在平台能力**之前**（上游顺序，uci.c:1336-1341）
	creply, cst := session_call("create", `{}`, alloc)
	testing.expect_value(t, cst, SESSION_STATUS_OK)
	cdoc: json.Value
	testing.expect(t, json.unmarshal(transmute([]byte)(creply), &cdoc, .JSON, alloc) == nil)
	cobj, _ := cdoc.(json.Object)
	sid := string(cobj["ubus_rpc_session"].(json.String))

	commit_params := fmt.aprintf(`{{"ubus_rpc_session":"%s","config":"network"}}`, sid, allocator = alloc)
	_, st_commit := uci_call("commit", commit_params, alloc)
	testing.expect_value(t, st_commit, UCI_STATUS_PERMISSION_DENIED)
	_, st_revert := uci_call("revert", commit_params, alloc)
	testing.expect_value(t, st_revert, UCI_STATUS_PERMISSION_DENIED)
	// state 要的是**读**权限，同样没有 → 6
	_, st_state := uci_call("state", commit_params, alloc)
	testing.expect_value(t, st_state, UCI_STATUS_PERMISSION_DENIED)

	// 缺 config → 2（ACL 之后、平台能力之前）
	_, st_noconfig := uci_call("commit", `{}`, alloc)
	testing.expect_value(t, st_noconfig, UCI_STATUS_INVALID_ARGUMENT)

	// 清掉这个会话，免得留着影响别的用例
	destroy_params := fmt.aprintf(`{{"ubus_rpc_session":"%s"}}`, sid, allocator = alloc)
	_, dst := session_call("destroy", destroy_params, alloc)
	testing.expect_value(t, dst, SESSION_STATUS_OK)
}

@(test)
test_uci_purge_dir :: proc(t: ^testing.T) {
	alloc, ar := mk_arena()
	defer drop_arena(ar)

	base := fmt.aprintf("/tmp/molly-uci-purge-%d", time.now()._nsec, allocator = alloc)
	sub := fmt.aprintf("%s/sub", base, allocator = alloc)
	f1 := fmt.aprintf("%s/a.conf", base, allocator = alloc)
	f2 := fmt.aprintf("%s/b.conf", base, allocator = alloc)

	testing.expect(t, os.make_directory(base) == nil)
	testing.expect(t, os.make_directory(sub) == nil)
	h1, e1 := os.create(f1)
	testing.expect(t, e1 == nil)
	os.close(h1)
	h2, e2 := os.create(f2)
	testing.expect(t, e2 == nil)
	os.close(h2)

	uci_purge_dir(base, alloc)

	// 普通文件被删
	_, s1 := os.stat(f1, alloc)
	_, s2 := os.stat(f2, alloc)
	testing.expect(t, s1 != nil && s2 != nil)
	// 子目录被跳过（上游也是 continue），所以 rmdir 因为「目录非空」失败 —— 目录还在
	_, s3 := os.stat(base, alloc)
	testing.expect(t, s3 == nil)
	_, s4 := os.stat(sub, alloc)
	testing.expect(t, s4 == nil)

	// 清场（别在 /tmp 留垃圾）
	_ = os.remove(sub)
	_ = os.remove(base)
}
