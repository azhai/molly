package luci

import "core:fmt"
import "core:mem"
import "core:strings"

// P2 的「渲染」：不做模板、不读 view 文件，只把路由解析的结果显示出来。
// 模板渲染属于 P3。这里存在的意义是让 dispatcher 的解析结果可被 curl 断言，
// 同时把「认证 / ACL 未实施」这件事明明白白摆在页面上（计划决策 6、决胜点 7）。

Kind :: enum {
	Page,            // 命中 action.type == "view" 的节点
	NotFound,        // 没命中任何节点 → 404
	Not_Implemented, // 命中了，但 action.type 不是 view（cbi/form/template/…）→ 501
}

Page :: struct {
	kind: Kind,
	body: string,
}

// 用 Druid 之外的纯 HTML 拼一个页面。所有插值都过 html_escape：title 来自
// 设备上的 menu.d（可信度较高），但 request_args 来自 URL，是彻头彻尾的
// 客户端输入——信任边界在这里，不能省（AGENTS.md §2.2）。
render_placeholder :: proc(node: ^Node, action: Action, args: []string, alloc: mem.Allocator) -> string {
	title := node.title
	if len(title) == 0 {
		title = node.action_path
	}

	b := strings.builder_make(alloc)
	strings.write_string(&b, "<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n")
	strings.write_string(&b, "<meta charset=\"utf-8\">\n<title>")
	html_escape(title, &b)
	strings.write_string(&b, "</title>\n</head>\n<body>\n")
	strings.write_string(&b, "<p class=\"banner\">ACL 未实施：P2 占位页，没有认证与权限校验，P3 由 molly 自持 acl.d 接管</p>\n")
	strings.write_string(&b, "<h1>")
	html_escape(title, &b)
	strings.write_string(&b, "</h1>\n<dl>\n")

	// action 用 effective_action 的结果：通配层收下剩余段时是 wildcardaction
	write_row(&b, "action.type", action.type)
	write_row(&b, "view", action.path)

	if node.has_depends {
		// 明确标注「展示但不执行」：depends.acl 在 P2 不参与判定
		write_row(&b, "depends (shown, not enforced)", node.depends_json)
	}

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
dispatch :: proc(tree: ^Node, path: string, alloc: mem.Allocator) -> Page {
	r := resolve(tree, path, alloc)
	if !r.found {
		return {kind = .NotFound}
	}
	node := r.node

	// firstchild 下钻与 alias 回落。循环上限 4 是防 menu.d 写出来的环
	// （A alias 到 B、B alias 回 A），不是性能考虑。
	outer: for _ in 0 ..< 4 {
		if node == nil {
			return {kind = .NotFound}
		}

		if node.action_type == "firstchild" {
			node = first_child(node)
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
			alias := resolve(tree, target, alloc)
			if !alias.found {
				return {kind = .NotFound}
			}
			node = alias.node
			continue
		}

		break outer
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

	return {kind = .Page, body = render_placeholder(node, action, r.args, alloc)}
}