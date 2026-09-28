package luci

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:testing"

import "molly:backend"

// 单元测试：dispatcher 的建树与 depends 语义。
//
// 运行：odin test -collection:molly=src src/luci
//
// 每条用例都对应上游 `modules/luci-base/ucode/dispatcher.uc`（luci 提交 d6167ea）里的
// 一条规则，行号写在断言旁——这是第 6b 步「按上游语义对齐」的回归网。
//
// 边界：depends.uci 读的是 backend 的**假配置**（darwin 侧 FAKE_UCI：network 的
// lan/wan/wg0 + 匿名 @switch、system.ntp、以及一个没有 section 的 empty-config），
// depends.fs 读的是本机真实文件系统（/etc/hosts、/etc、/bin/sh），真机数据属第 7 步。

// odin test 默认多线程跑用例，所以每个用例要**自己**一份 arena（共享全局会互相踩）。
// 用法：alloc, ar := mk_arena(); defer drop_arena(ar)
@(private)
mk_arena :: proc() -> (mem.Allocator, ^mem.Dynamic_Arena) {
	a := new(mem.Dynamic_Arena) // 零初始化
	mem.dynamic_arena_init(a)
	return mem.dynamic_arena_allocator(a), a
}

@(private)
drop_arena :: proc(a: ^mem.Dynamic_Arena) {
	mem.dynamic_arena_destroy(a)
	free(a)
}

@(private)
parse :: proc(t: ^testing.T, text: string, alloc: mem.Allocator) -> json.Value {
	doc: json.Value
	err := json.unmarshal(transmute([]byte)(text), &doc, .JSON, alloc)
	testing.expectf(t, err == nil, "测试 JSON 解析失败（%v）：%s", err, text)
	return doc
}

@(private)
add :: proc(t: ^testing.T, root: ^Node, path, spec_text: string, alloc: mem.Allocator) {
	doc := parse(t, spec_text, alloc)
	obj, is_obj := doc.(json.Object)
	if !testing.expectf(t, is_obj, "spec 必须是 object：%s", spec_text) {
		return
	}
	apply_spec(root, path, obj, alloc)
}

// ---------------------------------------------------------------------------
// apply_spec：逐键处理（:406-408）与逐键合并
// ---------------------------------------------------------------------------

@(test)
test_apply_spec_skips_only_the_bad_key :: proc(t: ^testing.T) {
	alloc, ar := mk_arena()
	defer drop_arena(ar)
	root := empty_tree(alloc)
	// order 写成 string（真实样本 7 例）、外加一个 schema 之外的键（13 例里的另外几例）
	add(t, root, "a/b", `{"title":"B","order":"5","nonsense":true,"action":{"type":"view","path":"b"}}`, alloc)

	r := resolve(root, "/a/b", "", alloc)
	testing.expect(t, r.found, "整条规格不该被丢弃（上游只忽略该键）")
	testing.expect_value(t, r.node.title, "B")
	testing.expect_value(t, r.node.order, 9999) // 类型不符 → 忽略该键，保留默认权重
	testing.expect_value(t, r.node.action_type, "view")
	testing.expect(t, r.node.satisfied)
}

@(test)
test_apply_spec_merges_per_key :: proc(t: ^testing.T) {
	alloc, ar := mk_arena()
	defer drop_arena(ar)
	root := empty_tree(alloc)
	add(t, root, "p/x", `{"title":"X","order":10,"action":{"type":"cbi","path":"x"}}`, alloc)
	// 后一份只写 action：title / order 必须保留（上游只拷 spec 里出现的键）
	add(t, root, "p/x", `{"action":{"type":"view","path":"x-2"}}`, alloc)

	r := resolve(root, "/p/x", "", alloc)
	testing.expect(t, r.found)
	testing.expect_value(t, r.node.title, "X")
	testing.expect_value(t, r.node.order, 10)
	testing.expect_value(t, r.node.action_type, "view")
	testing.expect_value(t, r.node.action_path, "x-2")
}

@(test)
test_apply_spec_keeps_wildcard_action_separate :: proc(t: ^testing.T) {
	alloc, ar := mk_arena()
	defer drop_arena(ar)
	root := empty_tree(alloc)
	// `wv` 与 `wv/*` 落在同一个节点上（上游 :410-414 把通配 action 单独存）
	add(t, root, "wv", `{"title":"Wbase","action":{"type":"view","path":"wild-base"}}`, alloc)
	add(t, root, "wv/*", `{"title":"Wcard","action":{"type":"view","path":"wild-card"}}`, alloc)

	base := resolve(root, "/wv", "", alloc)
	testing.expect(t, base.found)
	testing.expect_value(t, len(base.args), 0)
	testing.expect_value(t, effective_action(base.node, base.args).path, "wild-base") // :1006-1011 无剩余段

	with_args := resolve(root, "/wv/a/b", "", alloc)
	testing.expect(t, with_args.found)
	testing.expect_value(t, len(with_args.args), 2)
	testing.expect_value(t, effective_action(with_args.node, with_args.args).path, "wild-card")
}

@(test)
test_apply_spec_on_root_is_ignored :: proc(t: ^testing.T) {
	alloc, ar := mk_arena()
	defer drop_arena(ar)
	root := empty_tree(alloc)
	// 上游 :405 `if (node !== tree)`：落到根上的规格整条不生效
	add(t, root, "", `{"title":"nope"}`, alloc)
	add(t, root, "/", `{"title":"nope2"}`, alloc)

	testing.expect_value(t, root.title, "")
	testing.expect_value(t, root.action_type, "firstchild")
}

@(test)
test_apply_spec_without_depends_resets_satisfied :: proc(t: ^testing.T) {
	alloc, ar := mk_arena()
	defer drop_arena(ar)
	root := empty_tree(alloc)
	add(t, root, "p/h", `{"title":"H","action":{"type":"view","path":"h"},"depends":{"fs":{"/nonexistent-molly-test":"file"}}}`, alloc)
	testing.expect(t, !resolve(root, "/p/h", "", alloc).found, "depends 不满足 → 未命中")

	// 上游 :416 无条件重算 check_depends(spec)：后一份没写 depends → 重新变回 true
	add(t, root, "p/h", `{"title":"H2"}`, alloc)
	testing.expect(t, resolve(root, "/p/h", "", alloc).found)
}

// ---------------------------------------------------------------------------
// check_depends：fs（:171-196 + :279-292）
// ---------------------------------------------------------------------------

@(test)
test_check_depends_fs_file_and_absent :: proc(t: ^testing.T) {
	alloc, ar := mk_arena()
	defer drop_arena(ar)
	ok :: proc(t: ^testing.T, text: string, alloc: mem.Allocator, want: bool) {
		got := check_depends(parse(t, text, alloc), alloc)
		testing.expectf(t, got == want, "%s 应为 %v，实际 %v", text, want, got)
	}
	ok(t, `{"fs":{"/etc/hosts":"file"}}`, alloc, true)
	ok(t, `{"fs":{"/nonexistent-molly-test":"file"}}`, alloc, false)
	// absent 的方向不能反
	ok(t, `{"fs":{"/nonexistent-molly-test":"absent"}}`, alloc, true)
	ok(t, `{"fs":{"/etc/hosts":"absent"}}`, alloc, false)
}

@(test)
test_check_depends_fs_kinds :: proc(t: ^testing.T) {
	alloc, ar := mk_arena()
	defer drop_arena(ar)
	Ok :: proc(t: ^testing.T, text: string, alloc: mem.Allocator, want: bool) {
		got := check_depends(parse(t, text, alloc), alloc)
		testing.expectf(t, got == want, "%s 应为 %v，实际 %v", text, want, got)
	}
	// directory：要存在且非空；普通文件不算目录
	Ok(t, `{"fs":{"/etc":"directory"}}`, alloc, true)
	Ok(t, `{"fs":{"/etc/hosts":"directory"}}`, alloc, false)
	// executable：要普通文件 + 属主可执行位
	Ok(t, `{"fs":{"/bin/sh":"executable"}}`, alloc, true)
	Ok(t, `{"fs":{"/etc/hosts":"executable"}}`, alloc, false)
	// 认不出的要求类型 → 上游没有分支 → 忽略该条目
	Ok(t, `{"fs":{"/nonexistent-molly-test":"whatever"}}`, alloc, true)
	// 要求类型不是字符串 → 同样忽略
	Ok(t, `{"fs":{"/nonexistent-molly-test":true}}`, alloc, true)
}

@(test)
test_check_depends_fs_and_or_shapes :: proc(t: ^testing.T) {
	alloc, ar := mk_arena()
	defer drop_arena(ar)
	Ok :: proc(t: ^testing.T, text: string, alloc: mem.Allocator, want: bool) {
		got := check_depends(parse(t, text, alloc), alloc)
		testing.expectf(t, got == want, "%s 应为 %v，实际 %v", text, want, got)
	}
	// object = 全部条目成立
	Ok(t, `{"fs":{"/etc/hosts":"file","/nonexistent-molly-test":"file"}}`, alloc, false)
	// array = 任一备选成立
	Ok(t, `{"fs":[{"nonexistent-molly-test":"file"},{"/etc/hosts":"file"}]}`, alloc, true)
	// 空 array：上游 satisfied 保持 false
	Ok(t, `{"fs":[]}`, alloc, false)
	// 非 object 备选（裸字符串）：上游 for..in 拿不到条目 → 忽略 ⇒ 成立
	Ok(t, `{"fs":["/etc/hosts"]}`, alloc, true)
	Ok(t, `{"fs":"whatever"}`, alloc, true)
	Ok(t, `{"fs":null}`, alloc, true)
}

// ---------------------------------------------------------------------------
// check_depends：uci（:198-276）
// ---------------------------------------------------------------------------

@(test)
test_check_depends_uci_sections :: proc(t: ^testing.T) {
	alloc, ar := mk_arena()
	defer drop_arena(ar)
	Ok :: proc(t: ^testing.T, text: string, alloc: mem.Allocator, want: bool) {
		got := check_depends(parse(t, text, alloc), alloc)
		testing.expectf(t, got == want, "%s 应为 %v，实际 %v", text, want, got)
	}
	// `true`：config 至少有 1 个 section
	Ok(t, `{"uci":{"network":true}}`, alloc, true)
	Ok(t, `{"uci":{"empty-config":true}}`, alloc, false)
	Ok(t, `{"uci":{"no-such-config":true}}`, alloc, false)
	// 具名 section
	Ok(t, `{"uci":{"network":{"lan":true}}}`, alloc, true)
	Ok(t, `{"uci":{"network":{"nope":true}}}`, alloc, false)
	// `@<type>`：任一该类型 section 满足（假配置里的 @switch 是匿名 section）
	Ok(t, `{"uci":{"network":{"@switch":true}}}`, alloc, true)
	Ok(t, `{"uci":{"network":{"@nonexistent-type":true}}}`, alloc, false)
	// object = 全部 config 条目成立
	Ok(t, `{"uci":{"network":true,"no-such-config":true}}`, alloc, false)
	// 空 object：0 个条目 → 成立
	Ok(t, `{"uci":{}}`, alloc, true)
	// 非 object 备选（裸字符串，真实样本 olsr 1 例）→ 忽略 ⇒ 成立
	Ok(t, `{"uci":["network.lan"]}`, alloc, true)
	Ok(t, `{"uci":"network.lan"}`, alloc, true)
}

@(test)
test_check_depends_uci_options :: proc(t: ^testing.T) {
	alloc, ar := mk_arena()
	defer drop_arena(ar)
	Ok :: proc(t: ^testing.T, text: string, alloc: mem.Allocator, want: bool) {
		got := check_depends(parse(t, text, alloc), alloc)
		testing.expectf(t, got == want, "%s 应为 %v，实际 %v", text, want, got)
	}
	// option 值精确匹配（:207-223）
	Ok(t, `{"uci":{"network":{"lan":{"proto":"static"}}}}`, alloc, true)
	Ok(t, `{"uci":{"network":{"lan":{"proto":"dhcp"}}}}`, alloc, false)
	// option 不存在
	Ok(t, `{"uci":{"network":{"lan":{"nope":"x"}}}}`, alloc, false)
	// option 取值 true → 存在即可
	Ok(t, `{"uci":{"network":{"lan":{"proto":true}}}}`, alloc, true)
	Ok(t, `{"uci":{"network":{"lan":{"nope":true}}}}`, alloc, false)
	// list 型 option：按成员判定（假配置里 system.ntp.server 是 list）
	Ok(t, `{"uci":{"system":{"ntp":{"server":"1.openwrt.pool.ntp.org"}}}}`, alloc, true)
	Ok(t, `{"uci":{"system":{"ntp":{"server":"nope.example"}}}}`, alloc, false)
}

// ---------------------------------------------------------------------------
// 路径解析与 firstchild 竞选
// ---------------------------------------------------------------------------

@(test)
test_first_child_order_tiebreak_and_skips :: proc(t: ^testing.T) {
	alloc, ar := mk_arena()
	defer drop_arena(ar)
	root := empty_tree(alloc)
	add(t, root, "p", `{"title":"P","action":{"type":"firstchild"}}`, alloc)
	add(t, root, "p/a", `{"title":"A","order":20,"action":{"type":"view","path":"a"}}`, alloc)
	add(t, root, "p/b", `{"title":"B","order":20,"action":{"type":"view","path":"b"}}`, alloc)
	// 权重最小但 firstchild_ineligible
	add(t, root, "p/z", `{"title":"Z","order":5,"firstchild_ineligible":true,"action":{"type":"view","path":"z"}}`, alloc)
	// 权重第二小但 depends 不满足
	add(t, root, "p/n", `{"title":"N","order":8,"action":{"type":"view","path":"n"},"depends":{"fs":{"/nonexistent-molly-test":"file"}}}`, alloc)
	// 没有 title 的不参选
	add(t, root, "p/notitle", `{"action":{"type":"view","path":"nt"}}`, alloc)

	sel := first_child(root.children["p"], "", nil, nil, false, alloc)
	testing.expect(t, sel != nil)
	testing.expect_value(t, sel.title, "A") // 权重相同 → 按段名字典序，结果必须确定
}

@(test)
test_first_child_recurses_and_requires_eligible_descendant :: proc(t: ^testing.T) {
	alloc, ar := mk_arena()
	defer drop_arena(ar)
	root := empty_tree(alloc)
	add(t, root, "p", `{"title":"P","action":{"type":"firstchild"}}`, alloc)
	add(t, root, "p/mid", `{"title":"Mid","order":1,"action":{"type":"firstchild"}}`, alloc)
	add(t, root, "p/mid/leaf", `{"title":"Leaf","order":10,"action":{"type":"view","path":"leaf"}}`, alloc)
	add(t, root, "p/other", `{"title":"Other","order":5,"action":{"type":"view","path":"other"}}`, alloc)
	// 自己是 firstchild 却没有可当选的后代 → 不能当选
	add(t, root, "p/dead", `{"title":"Dead","order":0,"action":{"type":"firstchild"}}`, alloc)
	add(t, root, "p/dead/x", `{"order":1,"action":{"type":"view","path":"x"}}`, alloc) // 无 title

	sel := first_child(root.children["p"], "", nil, nil, false, alloc)
	testing.expect(t, sel != nil)
	testing.expect_value(t, sel.title, "Leaf")
}

@(test)
test_at_section_type :: proc(t: ^testing.T) {
	ty, ok := at_section_type("@wifi-iface")
	testing.expect(t, ok)
	testing.expect_value(t, ty, "wifi-iface")

	_, ok_empty := at_section_type("@")
	testing.expect(t, !ok_empty)

	_, ok_dotted := at_section_type("@a.b")
	testing.expect(t, !ok_dotted)

	_, ok_named := at_section_type("named")
	testing.expect(t, !ok_named)

	_, ok_underscore := at_section_type("@switch_0")
	testing.expect(t, ok_underscore, "下划线与数字是合法字符")
}

// ---------------------------------------------------------------------------
// depends.acl（P3-6）：按会话裁树与只读
//
// 上游 check_acl_depends（dispatcher.uc:312-331）是三态：要求的组里有**任何一个没拿到**
// → null，apply_tree_acls（:435-445）据此把节点 satisfied=false（从菜单里裁掉、路径解析
// 不到）；全组只有 read → false（节点保留，但 `resolved.node.readonly = true`，:1002-1003）；
// 任一组有 write → true（正常）。
// molly 的树跨请求缓存，所以不学上游把结果写回节点，而是每请求现算（menu.odin 的
// node_visible）——这里的用例正是钉住「同一个缓存树、不同会话给出不同结果」。
// ---------------------------------------------------------------------------

// 造一个会话并按需授 access-group 权限（只走 session 对象的公开方法，不碰内部结构）。
// read 与 write 是**两条独立条目**（上游分别看 `'read' in groups[group]` 与 `'write' in ...`），
// 所以 write_groups 不会顺带授 read。
@(private)
acl_session :: proc(t: ^testing.T, read_groups, write_groups: []string, alloc: mem.Allocator) -> string {
	reply, status := backend.session_call("create", "{}", alloc)
	if !testing.expectf(t, status == 0, "session.create 失败：status=%d", status) {
		return ""
	}

	doc := parse(t, reply, alloc)
	obj, is_obj := doc.(json.Object)
	if !testing.expectf(t, is_obj, "create 的回复不是对象：%s", reply) {
		return ""
	}
	sid_v, has_sid := obj["ubus_rpc_session"]
	sid_str, is_str := sid_v.(json.String)
	if !testing.expectf(t, has_sid && is_str, "create 的回复里没有 ubus_rpc_session：%s", reply) {
		return ""
	}
	sid := string(sid_str)

	for g in read_groups {
		acl_grant(t, sid, g, "read", alloc)
	}
	for g in write_groups {
		acl_grant(t, sid, g, "write", alloc)
	}
	return sid
}

@(private)
acl_grant :: proc(t: ^testing.T, sid, group, perm: string, alloc: mem.Allocator) {
	// 注意 `{{` / `}}`：本仓库的 Odin fmt 用它转义字面大括号（全库惯例），
	// 写成 `{` 会被当成格式指令，拼出来的 JSON 直接解析失败（表现为 status=2）。
	params := fmt.aprintf(
		`{{"ubus_rpc_session":"%s","scope":"access-group","objects":[["%s","%s"]]}}`,
		sid,
		group,
		perm,
		allocator = alloc,
	)
	_, status := backend.session_call("grant", params, alloc)
	testing.expectf(t, status == 0, "grant %s/%s 失败：status=%d params=%s", group, perm, status, params)
}

// 小树：/a 下 gated（要求 g1，数组形态）、ro（要求 g2，**对象形态**——真机 menu.d 里就是
// `{ "luci-base": ["status"] }` 这种写法）、open（没有 acl 要求）。三个都给 title，
// 好参与 firstchild 竞选。
@(private)
acl_tree :: proc(t: ^testing.T, alloc: mem.Allocator) -> ^Node {
	root := new(Node, alloc)
	root.children = make(map[string]^Node, 0, alloc)

	add(t, root, "a", `{"title":"A","order":10,"action":{"type":"firstchild"}}`, alloc)
	add(
		t,
		root,
		"a/gated",
		`{"title":"Gated","order":10,"action":{"type":"view","path":"gated"},"depends":{"acl":["g1"]}}`,
		alloc,
	)
	add(
		t,
		root,
		"a/ro",
		`{"title":"Ro","order":20,"action":{"type":"view","path":"ro"},"depends":{"acl":{"g2":["status"]}}}`,
		alloc,
	)
	add(t, root, "a/open", `{"title":"Open","order":30,"action":{"type":"view","path":"open"}}`, alloc)
	return root
}

@(test)
test_acl_prunes_and_readonly :: proc(t: ^testing.T) {
	alloc, ar := mk_arena()
	defer drop_arena(ar)

	root := acl_tree(t, alloc)

	// 无会话（sid=""）：缺组的节点裁掉 → 路径解析不到（等价上游 satisfied=false）
	testing.expect(t, !resolve(root, "/a/gated", "", alloc).found, "无会话 → 要 g1 的节点不可见")
	testing.expect(t, resolve(root, "/a/open", "", alloc).found, "没有 depends.acl 的节点不受影响")

	// 授 g1 的 write：可见、不是只读
	sid1 := acl_session(t, nil, []string{"g1"}, alloc)
	testing.expect(t, resolve(root, "/a/gated", sid1, alloc).found)
	page := dispatch(root, "/a/gated", sid1, alloc)
	testing.expect_value(t, page.kind, Kind.Page)
	testing.expect(t, strings.contains(page.body, "readonly</dt><dd>no"), page.body)

	// 只授别的组：一样不可见（上游按键精确命中），连「只读」都谈不上 → 404
	sid2 := acl_session(t, []string{"g2"}, nil, alloc)
	testing.expect(t, !resolve(root, "/a/gated", sid2, alloc).found)
	testing.expect_value(t, dispatch(root, "/a/gated", sid2, alloc).kind, Kind.NotFound)

	// 只授 g2 的 read（对象形态的 depends.acl）：可见但只读（上游 perm=false）
	testing.expect(t, resolve(root, "/a/ro", sid2, alloc).found)
	page2 := dispatch(root, "/a/ro", sid2, alloc)
	testing.expect_value(t, page2.kind, Kind.Page)
	testing.expect(t, strings.contains(page2.body, "readonly</dt><dd>yes"), page2.body)

	// 后一份规格没有 depends → acl 要求被清掉（与 satisfied 同一规则，上游 :416 无条件重算）
	add(t, root, "a/gated", `{"action":{"type":"view","path":"gated2"}}`, alloc)
	testing.expect(t, resolve(root, "/a/gated", "", alloc).found, "后一份规格清掉了 acl 要求")
}

@(test)
test_acl_first_child_skips_and_marks_readonly :: proc(t: ^testing.T) {
	alloc, ar := mk_arena()
	defer drop_arena(ar)

	root := acl_tree(t, alloc)

	// 无会话：firstchild 跳过 gated(10) 与 ro(20)，选 open(30)
	// （这棵树没有 auth 节点，所以走不到 login 放行模式，见 test_login_required_*）
	sel := first_child(root.children["a"], "", nil, nil, false, alloc)
	testing.expect(t, sel != nil)
	testing.expect_value(t, sel.action_path, "open")

	// 只授 g1 的 read：gated 恢复竞选（order 最小）→ 当选，且当选支路的组进 groups
	sid := acl_session(t, []string{"g1"}, nil, alloc)
	groups := make([dynamic]string, 0, 4, alloc)
	sel2 := first_child(root.children["a"], sid, &groups, nil, false, alloc)
	testing.expect(t, sel2 != nil)
	testing.expect_value(t, sel2.action_path, "gated")
	testing.expect_value(t, len(groups), 1)
	testing.expect_value(t, groups[0], "g1")

	// /a 是 firstchild：落到 gated，页面标只读（dispatch 把当选支路的组并进判权）
	page := dispatch(root, "/a", sid, alloc)
	testing.expect_value(t, page.kind, Kind.Page)
	testing.expect(t, strings.contains(page.body, "view</dt><dd>gated"), page.body)
	testing.expect(t, strings.contains(page.body, "readonly</dt><dd>yes"), page.body)

	// 无会话走同一条路径 → 落到 open，不是只读
	page_open := dispatch(root, "/a", "", alloc)
	testing.expect_value(t, page_open.kind, Kind.Page)
	testing.expect(t, strings.contains(page_open.body, "view</dt><dd>open"), page_open.body)
	testing.expect(t, strings.contains(page_open.body, "readonly</dt><dd>no"), page_open.body)
}

// ---------------------------------------------------------------------------
// P3-6 收尾：无会话 + auth.login → 403 + 登录提示（上游 dispatcher.uc:927-961）
//
// 真实 menu.d 的形态就是：`admin` 带 `auth.login`，它下面的叶子全带 depends.acl。
// 少了这条语义，无会话的人在设备上看到的是**整站裸 404**（实测踩过）。
// ---------------------------------------------------------------------------

// 与设备上的 luci-base.json 同形。
@(private)
login_tree :: proc(t: ^testing.T, alloc: mem.Allocator) -> ^Node {
	root := empty_tree(alloc)
	add(
		t,
		root,
		"admin",
		`{"title":"Administration","order":10,"action":{"type":"firstchild"},"auth":{"methods":["cookie:sysauth_http"],"login":true}}`,
		alloc,
	)
	add(t, root, "admin/status", `{"title":"Status","order":10,"action":{"type":"firstchild"}}`, alloc)
	add(
		t,
		root,
		"admin/status/overview",
		`{"title":"Overview","order":10,"action":{"type":"view","path":"status/overview"},"depends":{"acl":{"g1":["read"]}}}`,
		alloc,
	)
	// admin 下一个没有 acl 的节点：有会话时照常当选
	add(t, root, "admin/logout", `{"title":"Logout","order":99,"action":{"type":"function","path":"auth/logout"}}`, alloc)
	// login 子树之外的公开节点
	add(t, root, "open", `{"title":"Open","order":20,"action":{"type":"view","path":"open"}}`, alloc)
	return root
}

@(test)
test_login_required_without_session :: proc(t: ^testing.T) {
	alloc, ar := mk_arena()
	defer drop_arena(ar)
	root := login_tree(t, alloc)

	// ① 裸前缀：无会话时 root 的 firstchild 在 login 模式下落到 admin/status/overview
	//    （ACL 本来会把它裁掉）。上游到这一步就 403 + 登录页——**不是 404**
	page := dispatch(root, "", "", alloc)
	testing.expect_value(t, page.kind, Kind.Login_Required)
	testing.expect(t, strings.contains(page.body, "Login required"), page.body)

	// ② 直接请求被门控的路径：下降在 overview 处被截断，但沿途已经收下 admin 的 auth.login
	//    （上游同样是先聚完 ctx.auth 才走到 error404）
	page2 := dispatch(root, "/admin/status/overview", "", alloc)
	testing.expect_value(t, page2.kind, Kind.Login_Required)
	// 提示页里要能看到是哪条 URL 落到这里，否则设备上还是得猜
	testing.expect(t, strings.contains(page2.body, "/admin/status/overview"), page2.body)

	// ③ 中间节点（自己既没有 acl 也没有 auth，但沿途穿过 admin）：一样要登录
	page3 := dispatch(root, "/admin/status", "", alloc)
	testing.expect_value(t, page3.kind, Kind.Login_Required)

	// ④ login 子树之外的公开节点完全不受影响
	page4 := dispatch(root, "/open", "", alloc)
	testing.expect_value(t, page4.kind, Kind.Page)
	testing.expect(t, strings.contains(page4.body, "view</dt><dd>open"), page4.body)
}

@(test)
test_login_not_required_with_session :: proc(t: ^testing.T) {
	alloc, ar := mk_arena()
	defer drop_arena(ar)
	root := login_tree(t, alloc)

	// 有会话（哪怕只有 read）→ 不走登录流程：正常解析，页面标只读
	sid := acl_session(t, []string{"g1"}, nil, alloc)
	page := dispatch(root, "/admin/status/overview", sid, alloc)
	testing.expect_value(t, page.kind, Kind.Page)
	testing.expect(t, strings.contains(page.body, "readonly</dt><dd>yes"), page.body)

	// 裸前缀：有会话时 firstchild 照 ACL 竞选 → 落到 overview（order 最小且可见）
	page_root := dispatch(root, "", sid, alloc)
	testing.expect_value(t, page_root.kind, Kind.Page)
	testing.expect(t, strings.contains(page_root.body, "view</dt><dd>status/overview"), page_root.body)

	// 有会话但**缺组**：上游这时候不是登录页，而是节点不可见（404）——molly 保持一致
	sid2 := acl_session(t, nil, nil, alloc)
	page_missing := dispatch(root, "/admin/status/overview", sid2, alloc)
	testing.expect_value(t, page_missing.kind, Kind.NotFound)
}

// 上游 ctx.auth 是「最后者胜」（ctx_append 的 `ctx.auth = node.auth || ctx.auth`，:463）：
// 更深的节点只要带 auth（哪怕没有 login），就把前面 admin 的 login 顶掉 → 不走登录流程。
@(test)
test_auth_login_last_node_wins :: proc(t: ^testing.T) {
	alloc, ar := mk_arena()
	defer drop_arena(ar)
	root := empty_tree(alloc)
	add(t, root, "admin", `{"title":"Admin","order":10,"action":{"type":"firstchild"},"auth":{"login":true}}`, alloc)
	add(
		t,
		root,
		"admin/uci",
		`{"title":"UCI","order":10,"action":{"type":"function","path":"admin/uci"},"auth":{"methods":["cookie:sysauth_http"]}}`,
		alloc,
	)

	// admin 自己：走登录流程
	testing.expect_value(t, dispatch(root, "/admin", "", alloc).kind, Kind.Login_Required)
	// admin/uci：它自己的 auth 覆盖了 admin 的 → 501（上游会去执行那个 function）
	testing.expect_value(t, dispatch(root, "/admin/uci", "", alloc).kind, Kind.Not_Implemented)

	// auth 不是对象（类型不符）→ 上游 schema 整键忽略（:407）
	root2 := empty_tree(alloc)
	add(t, root2, "x", `{"title":"X","order":10,"action":{"type":"view","path":"x"},"auth":"nonsense"}`, alloc)
	testing.expect_value(t, dispatch(root2, "/x", "", alloc).kind, Kind.Page)
}
