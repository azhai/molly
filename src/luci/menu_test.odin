package luci

// menu_test —— dispatcher「建树 + 解析 + 渲染」的 host 单测（对齐 internal/luci/menu_test.go）。
// 只测纯逻辑：deps 用假 proc（uci 段 + ACL 档位），不碰套接字/backend 会话表。fs depends
// 用 darwin 上真实存在的路径（/etc/hosts、/bin/sh、/etc）。dispatch 用仓库 fixture menu.d。

import "core:testing"
import "core:mem"
import "core:strings"
import "base:runtime"
import "molly:backend"

// ---- 假 deps：uci 段与 ACL 档位由用例直接给（对齐 Go 的 fakeDeps）----

_fake_sections: map[string][]backend.Uci_Section
_fake_level: backend.ACL_Level

fake_uci :: proc(config: string, alloc: mem.Allocator) -> ([]backend.Uci_Section, bool) {
	_ = alloc
	s, ok := _fake_sections[config]
	return s, ok
}

// fake_acl：空组恒 Writable；无会话（sid=="")恒 Missing；否则回用例设的档位。
fake_acl :: proc(sid: string, groups: []string) -> backend.ACL_Level {
	if len(groups) == 0 {
		return .Writable
	}
	if len(sid) == 0 {
		return .Missing
	}
	return _fake_level
}

fake_deps :: proc() -> Deps {
	return Deps{uci_sections = fake_uci, acl_level = fake_acl}
}

// setup_net —— 装 fixture 的 depends.uci 需要的假配置（network 有 lan/switch，empty-config 空）。
// 数据落在**进程默认分配器**而非用例 arena：_fake_sections 是包级 map，须跨建树存活；
// 用例 arena 在后续建树/JSON 解析中被继续占用，把 fake 数据当成可回收内存冲掉会读到脏字节。
setup_net :: proc(level: backend.ACL_Level) {
	_fake_level = level
	alloc := runtime.default_allocator()
	_fake_sections = make(map[string][]backend.Uci_Section, 0, alloc)

	lan_opts := make([]backend.Uci_Option, 1, alloc)
	lan_opts[0] = backend.Uci_Option{name = "proto", values = one_string("static", alloc)}
	switch_opts := make([]backend.Uci_Option, 1, alloc)
	switch_opts[0] = backend.Uci_Option{name = "name", values = one_string("switch0", alloc)}

	net := make([]backend.Uci_Section, 2, alloc)
	net[0] = backend.Uci_Section{name = "lan", type_name = "interface", options = lan_opts}
	net[1] = backend.Uci_Section{name = "", type_name = "switch", anonymous = true, options = switch_opts}

	_fake_sections["network"] = net
	_fake_sections["empty-config"] = make([]backend.Uci_Section, 0, alloc)
}

one_string :: proc(s: string, alloc: mem.Allocator) -> []string {
	out := make([]string, 1, alloc)
	out[0] = s
	return out
}

to_bytes :: proc(s: string) -> []u8 { return transmute([]u8)s }

tree_from_json :: proc(doc: string) -> ^Node {
	root := empty_tree()
	merge_menu_file(root, to_bytes(doc), fake_deps())
	return root
}

fixture_tree :: proc() -> ^Node {
	names := []string{"luci-base.json", "luci-probe.json"}
	return Build_Tree("tests/fixtures/menu.d", names, fake_deps())
}

node_at :: proc(n: ^Node, segs: []string) -> ^Node {
	cur := n
	for s in segs {
		if cur == nil || cur.children == nil {
			return nil
		}
		next, ok := cur.children[s]
		if ! ok {
			return nil
		}
		cur = next
	}
	return cur
}

satisfied_of :: proc(tree: ^Node, name: string) -> bool {
	n := node_at(tree, []string{name})
	return n != nil && n.satisfied
}

// ---------------------------------------------------------------------------
// 建树：schema 白名单 / 逐键合并 / 通配 action
// ---------------------------------------------------------------------------

@(test)
test_apply_spec_keeps_valid_keys :: proc(t: ^testing.T) {
	backing: [262144]u8
	ar: mem.Arena
	mem.arena_init(&ar, backing[:])
	context.allocator = mem.arena_allocator(&ar)

	setup_net(.Writable)
	tree := tree_from_json(`{"badfield": {"title": "Bad field kept", "order": "250", "nonsense": true,
		"action": {"type": "view", "path": "bad"}}}`)
	n := node_at(tree, []string{"badfield"})
	testing.expect(t, n != nil, "badfield 节点没建出来")
	if n != nil {
		testing.expect_value(t, n.title, "Bad field kept")
		testing.expect_value(t, n.order, 9999) // "250" 是字符串 → 忽略，回默认 9999
		testing.expect_value(t, n.action_path, "bad")
	}
}

@(test)
test_same_path_merges_key_by_key :: proc(t: ^testing.T) {
	backing: [262144]u8
	ar: mem.Arena
	mem.arena_init(&ar, backing[:])
	context.allocator = mem.arena_allocator(&ar)

	setup_net(.Writable)
	root := empty_tree()
	deps := fake_deps()
	merge_menu_file(root, to_bytes(`{"admin/system/reboot": {"title": "Reboot", "order": 10,
		"action": {"type": "cbi", "path": "system/reboot"}}}`), deps)
	merge_menu_file(root, to_bytes(`{"admin/system/reboot": {"action": {"type": "view", "path": "system/reboot"}}}`), deps)
	n := node_at(root, []string{"admin", "system", "reboot"})
	testing.expect(t, n != nil, "节点没建出来")
	if n != nil {
		// 只覆盖 spec 里出现的键：title/order 保留前一份，action 用后一份。
		testing.expect_value(t, n.title, "Reboot")
		testing.expect_value(t, n.order, 10)
		testing.expect_value(t, n.action_type, "view")
	}
}

@(test)
test_wildcard_action_stored_separately :: proc(t: ^testing.T) {
	backing: [262144]u8
	ar: mem.Arena
	mem.arena_init(&ar, backing[:])
	context.allocator = mem.arena_allocator(&ar)

	setup_net(.Writable)
	root := empty_tree()
	deps := fake_deps()
	merge_menu_file(root, to_bytes(`{"admin/status/logs": {"title": "Logs", "order": 50,
		"action": {"type": "view", "path": "status/logs-base"}}}`), deps)
	merge_menu_file(root, to_bytes(`{"admin/status/logs/*": {"title": "Logs (wildcard)", "order": 50,
		"action": {"type": "view", "path": "status/logs-arg"}}}`), deps)
	n := node_at(root, []string{"admin", "status", "logs"})
	testing.expect(t, n != nil, "节点没建出来")
	if n != nil {
		testing.expect_value(t, n.wildcard, true)
		testing.expect_value(t, n.action_path, "status/logs-base") // base action 未被覆盖
		testing.expect_value(t, n.has_wildcard_action, true)
		testing.expect_value(t, n.wildcard_action_path, "status/logs-arg")
		testing.expect_value(t, n.title, "Logs (wildcard)") // title 落在同一节点上
	}
}

// ---------------------------------------------------------------------------
// depends：fs / uci 各形态
// ---------------------------------------------------------------------------

@(test)
test_depends_fs_forms :: proc(t: ^testing.T) {
	backing: [262144]u8
	ar: mem.Arena
	mem.arena_init(&ar, backing[:])
	context.allocator = mem.arena_allocator(&ar)

	setup_net(.Writable)
	tree := tree_from_json(`{
		"present":   {"title":"p","action":{"type":"view","path":"p"},"depends":{"fs":{"/etc/hosts":"file"}}},
		"hidden":    {"title":"h","action":{"type":"view","path":"h"},"depends":{"fs":{"/nonexistent-molly-menu-probe":"file"}}},
		"fsabsent":  {"title":"a","action":{"type":"view","path":"a"},"depends":{"fs":{"/nonexistent-molly-menu-probe":"absent"}}},
		"fsand":     {"title":"and","action":{"type":"view","path":"and"},"depends":{"fs":{"/etc/hosts":"file","/nonexistent-molly-menu-probe":"file"}}},
		"fsarray":   {"title":"arr","action":{"type":"view","path":"arr"},"depends":{"fs":[{"/nonexistent-molly-menu-probe":"file"},{"/etc/hosts":"file"}]}},
		"fsdir":     {"title":"dir","action":{"type":"view","path":"dir"},"depends":{"fs":{"/etc":"directory"}}},
		"fskind":    {"title":"kind","action":{"type":"view","path":"kind"},"depends":{"fs":{"/etc/hosts":"directory"}}},
		"fsexec":    {"title":"exe","action":{"type":"view","path":"exe"},"depends":{"fs":{"/bin/sh":"executable"}}},
		"fsexecmiss":{"title":"nomiss","action":{"type":"view","path":"nomiss"},"depends":{"fs":{"/etc/hosts":"executable"}}},
		"fsstrform": {"title":"str","action":{"type":"view","path":"str"},"depends":{"fs":["/etc/hosts"]}}
	}`)
	testing.expect_value(t, satisfied_of(tree, "present"), true)
	testing.expect_value(t, satisfied_of(tree, "hidden"), false)
	testing.expect_value(t, satisfied_of(tree, "fsabsent"), true)
	testing.expect_value(t, satisfied_of(tree, "fsand"), false)
	testing.expect_value(t, satisfied_of(tree, "fsarray"), true)
	testing.expect_value(t, satisfied_of(tree, "fsdir"), true)
	testing.expect_value(t, satisfied_of(tree, "fskind"), false)
	testing.expect_value(t, satisfied_of(tree, "fsexec"), true)
	testing.expect_value(t, satisfied_of(tree, "fsexecmiss"), false)
	testing.expect_value(t, satisfied_of(tree, "fsstrform"), true)
}

@(test)
test_depends_uci_forms :: proc(t: ^testing.T) {
	backing: [262144]u8
	ar: mem.Arena
	mem.arena_init(&ar, backing[:])
	context.allocator = mem.arena_allocator(&ar)

	setup_net(.Writable)
	tree := tree_from_json(`{
		"ucipage":     {"title":"a","action":{"type":"view","path":"a"},"depends":{"uci":{"network":{"lan":true}}}},
		"ucimissing":  {"title":"b","action":{"type":"view","path":"b"},"depends":{"uci":{"network":{"nope":true}}}},
		"ucitrue":     {"title":"c","action":{"type":"view","path":"c"},"depends":{"uci":{"network":true}}},
		"uciemptycfg": {"title":"d","action":{"type":"view","path":"d"},"depends":{"uci":{"empty-config":true}}},
		"ucicfgmiss":  {"title":"e","action":{"type":"view","path":"e"},"depends":{"uci":{"no-such-config":true}}},
		"uciaftype":   {"title":"f","action":{"type":"view","path":"f"},"depends":{"uci":{"network":{"@switch":true}}}},
		"uciopt":      {"title":"g","action":{"type":"view","path":"g"},"depends":{"uci":{"network":{"lan":{"proto":"static"}}}}},
		"ucioptmiss":  {"title":"h","action":{"type":"view","path":"h"},"depends":{"uci":{"network":{"lan":{"proto":"dhcp"}}}}},
		"uciand":      {"title":"i","action":{"type":"view","path":"i"},"depends":{"uci":{"network":true,"no-such-config":true}}},
		"ucistrform":  {"title":"j","action":{"type":"view","path":"j"},"depends":{"uci":["network.lan"]}}
	}`)
	testing.expect_value(t, satisfied_of(tree, "ucipage"), true)
	testing.expect_value(t, satisfied_of(tree, "ucimissing"), false)
	testing.expect_value(t, satisfied_of(tree, "ucitrue"), true)
	testing.expect_value(t, satisfied_of(tree, "uciemptycfg"), false)
	testing.expect_value(t, satisfied_of(tree, "ucicfgmiss"), false)
	testing.expect_value(t, satisfied_of(tree, "uciaftype"), true)
	testing.expect_value(t, satisfied_of(tree, "uciopt"), true)
	testing.expect_value(t, satisfied_of(tree, "ucioptmiss"), false)
	testing.expect_value(t, satisfied_of(tree, "uciand"), false)
	testing.expect_value(t, satisfied_of(tree, "ucistrform"), true)
}

// ---------------------------------------------------------------------------
// dispatch（用真实 fixture）
// ---------------------------------------------------------------------------

dispatch_case :: proc(t: ^testing.T, tree: ^Node, path, sid: string, want: Kind, want_in: string) -> Page {
	page := Dispatch(tree, path, sid, fake_deps())
	testing.expect_value(t, page.kind, want)
	if want_in != "" {
		testing.expect_value(t, strings.contains(page.body, want_in), true)
	}
	return page
}

@(test)
test_dispatch_fixture :: proc(t: ^testing.T) {
	backing: [262144]u8
	ar: mem.Arena
	mem.arena_init(&ar, backing[:])
	context.allocator = mem.arena_allocator(&ar)

	setup_net(.Writable)
	tree := fixture_tree()
	sid := "sess-ok" // 有会话、有 write

	dispatch_case(t, tree, "", sid, .Page, "<h1>Overview</h1>")                       // 裸前缀走 root firstchild
	dispatch_case(t, tree, "/admin/status/overview", sid, .Page, "<h1>Overview</h1>")   // 指定路径命中
	dispatch_case(t, tree, "/admin/status", sid, .Page, "<h1>Overview</h1>")            // firstchild
	dispatch_case(t, tree, "/admin/system", sid, .Page, "<h1>Reboot</h1>")              // firstchild（probe 把 reboot 改成 view）
	dispatch_case(t, tree, "/admin/status/routes", sid, .Not_Implemented,
		"not implemented: action.type=cbi view=status/routes menu=/admin/status/routes")
	dispatch_case(t, tree, "/admin/status/logs/syslog", sid, .Page, "status/logs-arg")  // 通配收下剩余段
	dispatch_case(t, tree, "/admin/status/logs", sid, .Page, "status/logs-base")        // 通配无剩余段用 base
	dispatch_case(t, tree, "/present", "", .Page, "<h1>Present via depends.fs</h1>")
	dispatch_case(t, tree, "/hidden", "", .Not_Found, "")
	dispatch_case(t, tree, "/ucipage", "", .Page, "")
	dispatch_case(t, tree, "/ucimissing", "", .Not_Found, "")
	dispatch_case(t, tree, "/nope", sid, .Not_Found, "")
	dispatch_case(t, tree, "/admin/status/overview", "", .Login_Required, "<h1>Login required</h1>")
	dispatch_case(t, tree, "/admin/nope", "", .Login_Required, "")
}

@(test)
test_dispatch_acl_three_states :: proc(t: ^testing.T) {
	backing: [262144]u8
	ar: mem.Arena
	mem.arena_init(&ar, backing[:])
	context.allocator = mem.arena_allocator(&ar)

	// 建树时 uci/fs 与 ACL 档位无关；档位只在 dispatch 期用（改 _fake_level 即可）。
	setup_net(.Read_Only)
	tree := fixture_tree()

	// 无会话：路径上有 auth.login → 登录提示（403），不是 404。
	_fake_level = .Read_Only
	page := dispatch_case(t, tree, "/admin/status/overview", "", .Login_Required, "")
	testing.expect_value(t, strings.contains(page.body, "<dt>path</dt><dd>/admin/status/overview</dd>"), true)

	// 有会话但缺组（哨兵会话）→ 404；firstchild 跳过被裁的 overview 落到 logs。
	_fake_level = .Missing
	sentinel := "00000000000000000000000000000000"
	dispatch_case(t, tree, "/admin/status/overview", sentinel, .Not_Found, "")
	page = dispatch_case(t, tree, "/admin/status", sentinel, .Page, "<h1>Logs (wildcard)</h1>")

	// 只读会话：可见但标 readonly。
	_fake_level = .Read_Only
	page = dispatch_case(t, tree, "/admin/status/overview", "sess-ro", .Page, "")
	testing.expect_value(t, strings.contains(page.body, "<dt>readonly</dt><dd>yes</dd>"), true)

	// 有 write 就不是只读。
	_fake_level = .Writable
	page = dispatch_case(t, tree, "/admin/status/overview", "sess-ok", .Page, "")
	testing.expect_value(t, strings.contains(page.body, "<dt>readonly</dt><dd>no</dd>"), true)
}

@(test)
test_request_args_escaped :: proc(t: ^testing.T) {
	backing: [262144]u8
	ar: mem.Arena
	mem.arena_init(&ar, backing[:])
	context.allocator = mem.arena_allocator(&ar)

	setup_net(.Writable)
	tree := tree_from_json(`{"logs/*": {"title":"L","action":{"type":"view","path":"logs-arg"}}}`)
	page := Dispatch(tree, "/logs/a<b>&c", "sid", fake_deps())
	testing.expect_value(t, page.kind, .Page)
	testing.expect_value(t, strings.contains(page.body, "a&lt;b&gt;&amp;c"), true) // 信任边界：客户端输入被转义
}
