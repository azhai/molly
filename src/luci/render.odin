package luci

// luci/render —— dispatcher 的「解析结果 → 该回什么」半边（对齐 internal/luci/render.go）。
//
// 不做模板、不读 view 文件：视图层尚未落地（生产走 --luci-cgi 的设备 ucode 对照，ADR 0003）。
// 它的价值是让解析结果可被脚本断言：命中的 action、request_args、以及**本会话是否只读**
// （depends.acl 真的参与裁树）。逐条对应 Go：KindPage/NotFound/NotImplemented/LoginRequired。

import "core:fmt"

// Kind 是 dispatch 的四种结果。
Kind :: enum {
	Page,           // 命中 action.type == "view"
	Not_Found,      // 没命中任何节点 → 404
	Not_Implemented, // 命中但 action.type 不是 view（cbi/form/template/…）→ 501
	Login_Required, // 无会话且路径上有 auth.login 的节点 → 403 + X-LuCI-Login-Required
}

// Page 是 dispatch 的结果。
Page :: struct {
	kind: Kind,
	body: string,
}

// Dispatch —— 「树 + PATH_INFO → 该回什么」。
// PATH_INFO 是专家版前缀**之后**的部分（""、"/"、"/admin/status/overview"）；空路径走 root firstchild。
Dispatch :: proc(tree: ^Node, path, sid: string, deps: Deps) -> Page {
	r := Resolve(tree, path, sid, deps)

	// 无会话且路径上出现过 auth.login → 上游进登录流程、最终 403 + 登录页，**不是 404**。
	// 必须在解析结果之前判：真实 menu.d 里 /admin/** 被 ACL 截断正是最常见形态。
	if login_required(r.auth, sid) {
		return Page{kind = .Login_Required, body = render_login_required(path)}
	}
	if ! r.found {
		return Page{kind = .Not_Found}
	}
	node := r.node

	// 沿途 depends.acl 组名并集（含 firstchild 当选支路与 alias 目标）——对应上游 ctx.acls。
	groups := [dynamic]string{}
	defer delete(groups)
	append_all(&groups, r.acl_groups)
	auth := r.auth

	// firstchild 下钻与 alias 回落。循环上限 4 防 menu.d 写出的环（A alias→B、B alias→A）。
	for i := 0; i < 4; i += 1 {
		if node == nil {
			return Page{kind = .Not_Found}
		}

		if node.action_type == "firstchild" {
			// 无会话时会在 login 模式下竞选——当选支路可能才带 auth.login（上游 :593）。
			node = First_Child(node, sid, &groups, &auth, false, deps)
			continue
		}

		if node.action_type == "alias" {
			target := node.action_path
			if len(target) == 0 {
				return Page{kind = .Not_Found}
			}
			if target[0] != '/' {
				target = build([]string{"/", target})
			}
			alias := Resolve(tree, target, sid, deps)
			if login_required(alias.auth, sid) {
				// alias 是**重新 dispatch** 目标路径：目标自己那份 ctx.auth 说了算（替换而非合并）。
				return Page{kind = .Login_Required, body = render_login_required(target)}
			}
			if ! alias.found {
				return Page{kind = .Not_Found}
			}
			clear(&groups)
			append_all(&groups, alias.acl_groups)
			auth = alias.auth
			node = alias.node
			continue
		}

		break
	}

	// 下钻结束再判一次（firstchild 当选支路自带 auth.login 的情况）。
	if login_required(auth, sid) {
		return Page{kind = .Login_Required, body = render_login_required(path)}
	}
	if node == nil {
		return Page{kind = .Not_Found}
	}

	// action 取自下钻结束后的节点；有剩余段（通配层收下 request_args）且有 wildcardaction 时用它。
	action := effective_action(node, r.args)
	if action.atype != "view" {
		// cbi/form/template/function/call 都要 ucode 或模板引擎，只回 501，正文带命中信息。
		body := fmt.tprintf("not implemented: action.type=%s view=%s menu=%s\n", action.atype, action.path, path)
		return Page{kind = .Not_Implemented, body = body}
	}

	// 只读 = 并集里没有任何一组拿到 write（上游 perm==false → node.readonly）。缺组在下降时裁掉了。
	readonly := acl_level_of(deps, sid, groups[:]) == .Read_Only

	return Page{kind = .Page, body = render_placeholder(node, action, r.args, readonly)}
}

// render_placeholder —— 纯 HTML 拼一个页面。所有插值都过 html_escape：title 来自 menu.d，
// 但 request_args 来自 URL，是彻头彻尾的客户端输入——信任边界在这里（AGENTS.md §2.2）。
render_placeholder :: proc(node: ^Node, action: Action, args: []string, readonly: bool) -> string {
	title := node.title
	if len(title) == 0 {
		title = node.action_path
	}

	buf: [dynamic]u8
	defer delete(buf)
	append(&buf, "<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n")
	append(&buf, "<meta charset=\"utf-8\">\n<title>")
	append_escaped(&buf, title)
	append(&buf, "</title>\n</head>\n<body>\n")
	append(&buf, "<h1>")
	append_escaped(&buf, title)
	append(&buf, "</h1>\n<dl>\n")

	if readonly {
		append(&buf, "<p class=\"banner read-only\">read-only：本会话对这条路径只有 read 权限（depends.acl）</p>\n")
	}

	// action 用 effective_action 的结果：通配层收下剩余段时是 wildcardaction。
	write_row(&buf, "action.type", action.atype)
	write_row(&buf, "view", action.path)

	if node.has_depends {
		write_row(&buf, "depends", node.depends_json)
	}
	if readonly {
		write_row(&buf, "readonly", "yes")
	} else {
		write_row(&buf, "readonly", "no")
	}

	if len(args) > 0 {
		append(&buf, "<dt>request_args</dt><dd>")
		for i := 0; i < len(args); i += 1 {
			if i > 0 {
				append(&buf, " / ")
			}
			append_escaped(&buf, args[i])
		}
		append(&buf, "</dd>\n")
	}

	append(&buf, "</dl>\n</body>\n</html>\n")
	return finalize_string(&buf)
}

// render_login_required —— 无会话命中 auth.login 节点时的占位页（状态码/头与上游对齐，正文换成可断言提示）。
render_login_required :: proc(path: string) -> string {
	buf: [dynamic]u8
	defer delete(buf)
	append(&buf, "<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n")
	append(&buf, "<meta charset=\"utf-8\">\n<title>Login required</title>\n</head>\n<body>\n")
	append(&buf, "<h1>Login required</h1>\n")
	append(&buf, "<p class=\"banner login-required\">需要登录：这条路径上的节点标了 <code>auth.login</code>，而本次请求没有会话（<code>sysauth_http</code> / <code>sysauth_https</code> 两个 cookie 都没有）。</p>\n")
	append(&buf, "<p>molly 的内置 dispatcher 只认<strong>既有</strong>会话，不渲染登录表单（登录页由 <code>--luci-cgi</code> 的 ucode 提供，ADR 0003）；状态码与响应头按上游对齐：403 + <code>X-LuCI-Login-Required: yes</code>。</p>\n")

	// 裸前缀（空路径）在提示页里显示成 "/"，否则这一行是空的。
	shown := path
	if len(shown) == 0 {
		shown = "/"
	}

	append(&buf, "<dl>\n")
	write_row(&buf, "login", "required (no session)")
	write_row(&buf, "path", shown)
	write_row(&buf, "hint", "POST /ubus 调 session.login 取 sid，再带 Cookie: sysauth_http=<sid>")
	append(&buf, "</dl>\n</body>\n</html>\n")
	return finalize_string(&buf)
}

write_row :: proc(buf: ^[dynamic]u8, key, value: string) {
	append(buf, "<dt>")
	append_escaped(buf, key)
	append(buf, "</dt><dd>")
	append_escaped(buf, value)
	append(buf, "</dd>\n")
}

// append_escaped —— 逐字节对齐 Go 的 htmlEscape：只转义 & < > " ' 五个字符，其余原样写。
// 非 ASCII 是 UTF-8 多字节，其字节值都 >= 0x80，绝不等于这五个 ASCII → 逐字节拷贝与逐 rune 转义等价。
append_escaped :: proc(buf: ^[dynamic]u8, s: string) {
	for i := 0; i < len(s); i += 1 {
		b := s[i]
		switch b {
		case u8('&'):
			append(buf, "&amp;")
		case u8('<'):
			append(buf, "&lt;")
		case u8('>'):
			append(buf, "&gt;")
		case u8('"'):
			append(buf, "&quot;")
		case u8('\''):
			append(buf, "&#39;")
		case:
			append(buf, b)
		}
	}
}

// build —— 把若干段字符串并成一块（context.allocator 分配，随调用方 arena 回收）。
build :: proc(parts: []string) -> string {
	buf: [dynamic]u8
	defer delete(buf)
	for p in parts {
		append(&buf, p)
	}
	return finalize_string(&buf)
}

// finalize_string —— 把 [dynamic]u8 拷成定长 string（脱离动态缓冲的生命周期）。
finalize_string :: proc(buf: ^[dynamic]u8) -> string {
	out := make([]u8, len(buf^), context.allocator)
	copy(out, buf^[0:len(buf^)])
	return string(out)
}
