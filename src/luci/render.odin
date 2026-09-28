package luci

import "core:fmt"
import "core:mem"
import "core:strings"

import "molly:backend"

// 「渲染」：不做模板、不读 view 文件，只把路由解析的结果显示出来（生产走 ADR 0003 的
// `--luci-cgi` → 设备 ucode；这份内置 dispatcher 是对照实现与回归基准）。
// 它的价值是让解析结果可被 curl 断言：命中的节点、action、request_args、以及
// **本会话是否只读**（P3-6 起 depends.acl 真的参与裁树）。

Kind :: enum {
	Page,            // 命中 action.type == "view" 的节点
	NotFound,        // 没命中任何节点 → 404
	Not_Implemented, // 命中了，但 action.type 不是 view（cbi/form/template/…）→ 501
	Login_Required,  // 无会话且路径上有 auth.login 的节点 → 403 + X-LuCI-Login-Required
}

Page :: struct {
	kind: Kind,
	body: string,
}

// 用 Druid 之外的纯 HTML 拼一个页面。所有插值都过 html_escape：title 来自
// 设备上的 menu.d（可信度较高），但 request_args 来自 URL，是彻头彻尾的
// 客户端输入——信任边界在这里，不能省（AGENTS.md §2.2）。
//
// readonly：本会话对这条路径上节点的 depends.acl 只有 read（上游 `resolved.node.readonly =
// !perm`，dispatcher.uc:1002-1003）——页面照渲染，但明确标出来。P3-6 起这里**不再**打
// 「ACL 未实施」横幅（那个横幅是 P2 的过渡声明，现在 ACL 真的生效了）。
render_placeholder :: proc(node: ^Node, action: Action, args: []string, readonly: bool, alloc: mem.Allocator) -> string {
	title := node.title
	if len(title) == 0 {
		title = node.action_path
	}

	b := strings.builder_make(alloc)
	strings.write_string(&b, "<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n")
	strings.write_string(&b, "<meta charset=\"utf-8\">\n<title>")
	html_escape(title, &b)
	strings.write_string(&b, "</title>\n</head>\n<body>\n")
	strings.write_string(&b, "<h1>")
	html_escape(title, &b)
	strings.write_string(&b, "</h1>\n<dl>\n")

	if readonly {
		strings.write_string(&b, "<p class=\"banner read-only\">read-only：本会话对这条路径只有 read 权限（depends.acl）</p>\n")
	}

	// action 用 effective_action 的结果：通配层收下剩余段时是 wildcardaction
	write_row(&b, "action.type", action.type)
	write_row(&b, "view", action.path)

	if node.has_depends {
		// fs / uci / acl 都参与判定（acl 的那半按会话现算，见 menu.odin 的 node_visible）
		write_row(&b, "depends", node.depends_json)
	}
	write_row(&b, "readonly", readonly ? "yes" : "no")

	if len(args) > 0 {
		strings.write_string(&b, "<dt>request_args</dt><dd>")
		for a, i in args {
			if i > 0 {
				strings.write_string(&b, " / ")
			}
			html_escape(a, &b)
		}
		strings.write_string(&b, "</dd>\n")
	}

	strings.write_string(&b, "</dl>\n</body>\n</html>\n")
	return strings.to_string(b)
}

// 无会话命中 auth.login 节点时的占位页（P3-6 收尾）。
//
// 上游在这一步是：先拿表单里的 luci_username / luci_password 试登录（`:939-940`），拿不到
// 会话就 **403 Forbidden + `X-LuCI-Login-Required: yes` + 主题的 sysauth 登录表单**（`:942-960`）。
// molly 的内置 dispatcher 不渲染模板（ADR 0003：登录页由 `--luci-cgi` 的 ucode 提供），所以
// 状态码与响应头照上游对齐、正文换成这段可 curl 断言的提示——至少让人看出「不是 404，是要登录，
// 而且落在哪条路径上」。没有这一页时，设备上的表现是整站一片裸 404（实测踩过）。
render_login_required :: proc(path: string, alloc: mem.Allocator) -> string {
	b := strings.builder_make(alloc)
	strings.write_string(&b, "<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n")
	strings.write_string(&b, "<meta charset=\"utf-8\">\n<title>Login required</title>\n</head>\n<body>\n")
	strings.write_string(&b, "<h1>Login required</h1>\n")
	strings.write_string(
		&b,
		"<p class=\"banner login-required\">需要登录：这条路径上的节点标了 <code>auth.login</code>，" +
		"而本次请求没有会话（<code>sysauth_http</code> / <code>sysauth_https</code> 两个 cookie 都没有）。</p>\n",
	)
	strings.write_string(
		&b,
		"<p>molly 的内置 dispatcher 只认<strong>既有</strong>会话，不渲染登录表单（登录页由 " +
		"<code>--luci-cgi</code> 的 ucode 提供，ADR 0003）；状态码与响应头按上游对齐：403 + " +
		"<code>X-LuCI-Login-Required: yes</code>。</p>\n",
	)
	// 裸前缀（空路径）在提示页里显示成 "/"，否则这一行是空的
	shown := path
	if len(shown) == 0 {
		shown = "/"
	}

	strings.write_string(&b, "<dl>\n")
	write_row(&b, "login", "required (no session)")
	write_row(&b, "path", shown)
	write_row(&b, "hint", "POST /ubus 调 session.login 取 sid，再带 Cookie: sysauth_http=<sid>")
	strings.write_string(&b, "</dl>\n</body>\n</html>\n")
	return strings.to_string(b)
}

@(private)
write_row :: proc(b: ^strings.Builder, key, value: string) {
	strings.write_string(b, "<dt>")
	html_escape(key, b)
	strings.write_string(b, "</dt><dd>")
	html_escape(value, b)
	strings.write_string(b, "</dd>\n")
}

@(private)
html_escape :: proc(s: string, b: ^strings.Builder) {
	for r in s {
		switch r {
		case '&':
			strings.write_string(b, "&amp;")
		case '<':
			strings.write_string(b, "&lt;")
		case '>':
			strings.write_string(b, "&gt;")
		case '"':
			strings.write_string(b, "&quot;")
		case '\'':
			strings.write_string(b, "&#39;")
		case:
			strings.write_rune(b, r)
		}
	}
}

// 树 + PATH_INFO → 该回什么。
//
// PATH_INFO 是 `/cgi-bin/luci` **之后**的部分（上游 LuCI 的约定）：`""`、
// `"/"`、`"/admin/status/overview"`。空路径走 root 的 firstchild。
dispatch :: proc(tree: ^Node, path: string, sid: string, alloc: mem.Allocator) -> Page {
	r := resolve(tree, path, sid, alloc)

	// 无会话且路径上出现过 auth.login 的节点 → 上游进登录流程、最终 403 + 登录页
	// （dispatcher.uc:927-961），**不是 404**。必须在解析结果之前判：真实 menu.d 里
	// `/admin/**` 被 ACL 截断正是最常见的形态，而上游也是先聚完 ctx.auth 才走到 error404。
	if login_required(r.auth, sid) {
		return {kind = .Login_Required, body = render_login_required(path, alloc)}
	}
	if !r.found {
		return {kind = .NotFound}
	}
	node := r.node

	// 沿途的 depends.acl 组名并集（含 firstchild 当选支路与 alias 目标），
	// 对应上游的 ctx.acls——最终用它判只读（dispatcher.uc:993-1004）。
	groups := make([dynamic]string, 0, 4, alloc)
	for g in r.acl_groups {
		append(&groups, g)
	}
	// 下钻还会继续并 auth（firstchild 的当选支路 / alias 目标），所以这里的初值只是起点
	auth := r.auth

	// firstchild 下钻与 alias 回落。循环上限 4 是防 menu.d 写出来的环
	// （A alias 到 B、B alias 回 A），不是性能考虑。
	outer: for _ in 0 ..< 4 {
		if node == nil {
			return {kind = .NotFound}
		}

		if node.action_type == "firstchild" {
			// 无会话时会在「login 模式」下竞选——当选支路可能才带上 auth.login（上游 :593）
			node = first_child(node, sid, &groups, &auth, false, alloc)
			continue
		}

		if node.action_type == "alias" {
			target := node.action_path
			if len(target) == 0 {
				return {kind = .NotFound}
			}
			if target[0] != '/' {
				target = strings.concatenate({"/", target}, alloc)
			}
			alias := resolve(tree, target, sid, alloc)
			if login_required(alias.auth, sid) {
				// 上游 alias 是**重新 dispatch** 一遍目标路径（:849-851）：目标自己那份
				// ctx.auth 说了算，所以这里不是合并而是替换。
				return {kind = .Login_Required, body = render_login_required(target, alloc)}
			}
			if !alias.found {
				return {kind = .NotFound}
			}
			for g in alias.acl_groups {
				append(&groups, g)
			}
			auth = alias.auth
			node = alias.node
			continue
		}

		break outer
	}

	// 下钻结束再判一次（firstchild 当选支路自带 auth.login 的情况）
	if login_required(auth, sid) {
		return {kind = .Login_Required, body = render_login_required(path, alloc)}
	}

	if node == nil {
		return {kind = .NotFound}
	}

	// 上游 :1006-1011：action 取自**下钻结束后的**节点，并在有剩余段时用通配 action
	action := effective_action(node, r.args)
	if action.type != "view" {
		// cbi / form / template / function / call 都要 ucode 或模板引擎，P2 只回 501。
		//
		// 501 的正文带上命中信息：设备上真实 menu.d 的 action.type 分布是
		// view 311 / firstchild 43 / function 31 / alias 21 / template 6 / call 1，
		// 只看到一句「not implemented」根本不知道落到了哪个节点（实测踩过）。
		body := fmt.aprintf(
			"not implemented: action.type=%s view=%s menu=%s\n",
			action.type,
			action.path,
			path,
			allocator = alloc,
		)
		return {kind = .Not_Implemented, body = body}
	}

	// 只读 = 并集里**没有任何一组**拿到 write（上游 `perm == false` → node.readonly）。
	// 缺组的情况在下降时就裁掉了（404），所以这里只可能是 Writable / Read_Only。
	readonly := backend.session_acl_level(sid, groups[:]) == .Read_Only

	return {kind = .Page, body = render_placeholder(node, action, r.args, readonly, alloc)}
}