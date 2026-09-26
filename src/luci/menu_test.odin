package luci

import "core:encoding/json"
import "core:mem"
import "core:testing"

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

	r := resolve(root, "/a/b", alloc)
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

	r := resolve(root, "/p/x", alloc)
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

	base := resolve(root, "/wv", alloc)
	testing.expect(t, base.found)
	testing.expect_value(t, len(base.args), 0)
	testing.expect_value(t, effective_action(base.node, base.args).path, "wild-base") // :1006-1011 无剩余段

	with_args := resolve(root, "/wv/a/b", alloc)
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
	testing.expect(t, !resolve(root, "/p/h", alloc).found, "depends 不满足 → 未命中")

	// 上游 :416 无条件重算 check_depends(spec)：后一份没写 depends → 重新变回 true
	add(t, root, "p/h", `{"title":"H2"}`, alloc)
	testing.expect(t, resolve(root, "/p/h", alloc).found)
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

	sel := first_child(root.children["p"])
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

	sel := first_child(root.children["p"])
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
