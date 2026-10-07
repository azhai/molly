package luci

import (
	"fmt"
	"strings"

	"github.com/azhai/molly/internal/backend"
)

// 「渲染」：不做模板、不读 view 文件，只把路由解析的结果显示出来（生产走 ADR 0003 的
// `--luci-cgi` → 设备 ucode；这份内置 dispatcher 是对照实现与回归基准）。
// 它的价值是让解析结果可被 curl 断言：命中的节点、action、request_args、以及
// **本会话是否只读**（depends.acl 真的参与裁树）。
//
// 逐条对应 Odin 版 src/luci/render.odin。

// Kind 是 dispatch 的四种结果。
type Kind int

const (
	// KindPage：命中 action.type == "view" 的节点
	KindPage Kind = iota
	// KindNotFound：没命中任何节点 → 404
	KindNotFound
	// KindNotImplemented：命中了，但 action.type 不是 view（cbi/form/template/…）→ 501
	KindNotImplemented
	// KindLoginRequired：无会话且路径上有 auth.login 的节点 → 403 + X-LuCI-Login-Required
	KindLoginRequired
)

// Page 是 dispatch 的结果。
type Page struct {
	Kind Kind
	Body string
}

// renderPlaceholder 用纯 HTML 拼一个页面。所有插值都过 htmlEscape：title 来自
// 设备上的 menu.d（可信度较高），但 requestArgs 来自 URL，是彻头彻尾的客户端输入
// ——信任边界在这里，不能省（AGENTS.md §2.2）。
//
// readonly：本会话对这条路径上节点的 depends.acl 只有 read（上游
// `resolved.node.readonly = !perm`，dispatcher.uc:1002-1003）——页面照渲染，但明确标出来。
func renderPlaceholder(node *Node, action Action, args []string, readonly bool) string {
	title := node.Title
	if len(title) == 0 {
		title = node.ActionPath
	}

	var b strings.Builder
	b.WriteString("<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n")
	b.WriteString("<meta charset=\"utf-8\">\n<title>")
	htmlEscape(&b, title)
	b.WriteString("</title>\n</head>\n<body>\n")
	b.WriteString("<h1>")
	htmlEscape(&b, title)
	b.WriteString("</h1>\n<dl>\n")

	if readonly {
		b.WriteString("<p class=\"banner read-only\">read-only：本会话对这条路径只有 read 权限（depends.acl）</p>\n")
	}

	// action 用 effectiveAction 的结果：通配层收下剩余段时是 wildcardaction
	writeRow(&b, "action.type", action.Type)
	writeRow(&b, "view", action.Path)

	if node.HasDepends {
		writeRow(&b, "depends", node.DependsJSON)
	}
	if readonly {
		writeRow(&b, "readonly", "yes")
	} else {
		writeRow(&b, "readonly", "no")
	}

	if len(args) > 0 {
		b.WriteString("<dt>request_args</dt><dd>")
		for i, a := range args {
			if i > 0 {
				b.WriteString(" / ")
			}
			htmlEscape(&b, a)
		}
		b.WriteString("</dd>\n")
	}

	b.WriteString("</dl>\n</body>\n</html>\n")
	return b.String()
}

// renderLoginRequired 是无会话命中 auth.login 节点时的占位页。
//
// 上游在这一步是：先拿表单里的 luci_username / luci_password 试登录，拿不到会话就
// **403 Forbidden + `X-LuCI-Login-Required: yes` + 主题的 sysauth 登录表单**。
// molly 的内置 dispatcher 不渲染模板（ADR 0003：登录页由 `--luci-cgi` 的 ucode 提供），
// 所以状态码与响应头照上游对齐、正文换成这段可 curl 断言的提示——至少让人看出
// 「不是 404，是要登录，而且落在哪条路径上」。
func renderLoginRequired(path string) string {
	var b strings.Builder
	b.WriteString("<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n")
	b.WriteString("<meta charset=\"utf-8\">\n<title>Login required</title>\n</head>\n<body>\n")
	b.WriteString("<h1>Login required</h1>\n")
	b.WriteString("<p class=\"banner login-required\">需要登录：这条路径上的节点标了 <code>auth.login</code>，" +
		"而本次请求没有会话（<code>sysauth_http</code> / <code>sysauth_https</code> 两个 cookie 都没有）。</p>\n")
	b.WriteString("<p>molly 的内置 dispatcher 只认<strong>既有</strong>会话，不渲染登录表单（登录页由 " +
		"<code>--luci-cgi</code> 的 ucode 提供，ADR 0003）；状态码与响应头按上游对齐：403 + " +
		"<code>X-LuCI-Login-Required: yes</code>。</p>\n")

	// 裸前缀（空路径）在提示页里显示成 "/"，否则这一行是空的
	shown := path
	if len(shown) == 0 {
		shown = "/"
	}

	b.WriteString("<dl>\n")
	writeRow(&b, "login", "required (no session)")
	writeRow(&b, "path", shown)
	writeRow(&b, "hint", "POST /ubus 调 session.login 取 sid，再带 Cookie: sysauth_http=<sid>")
	b.WriteString("</dl>\n</body>\n</html>\n")
	return b.String()
}

func writeRow(b *strings.Builder, key, value string) {
	b.WriteString("<dt>")
	htmlEscape(b, key)
	b.WriteString("</dt><dd>")
	htmlEscape(b, value)
	b.WriteString("</dd>\n")
}

// htmlEscape 逐字对齐 Odin 版：只转义这五个字符，其余按 rune 原样写。
func htmlEscape(b *strings.Builder, s string) {
	for _, r := range s {
		switch r {
		case '&':
			b.WriteString("&amp;")
		case '<':
			b.WriteString("&lt;")
		case '>':
			b.WriteString("&gt;")
		case '"':
			b.WriteString("&quot;")
		case '\'':
			b.WriteString("&#39;")
		default:
			b.WriteRune(r)
		}
	}
}

// Dispatch 是「树 + PATH_INFO → 该回什么」。
//
// PATH_INFO 是 `/cgi-bin/luci` **之后**的部分（上游 LuCI 的约定）：`""`、
// `"/"`、`"/admin/status/overview"`。空路径走 root 的 firstchild。
func Dispatch(tree *Node, path, sid string, deps Deps) Page {
	r := Resolve(tree, path, sid, deps)

	// 无会话且路径上出现过 auth.login 的节点 → 上游进登录流程、最终 403 + 登录页
	// （dispatcher.uc:927-961），**不是 404**。必须在解析结果之前判：真实 menu.d 里
	// `/admin/**` 被 ACL 截断正是最常见的形态，而上游也是先聚完 ctx.auth 才走到 error404。
	if loginRequired(r.Auth, sid) {
		return Page{Kind: KindLoginRequired, Body: renderLoginRequired(path)}
	}
	if !r.Found {
		return Page{Kind: KindNotFound}
	}
	node := r.Node

	// 沿途的 depends.acl 组名并集（含 firstchild 当选支路与 alias 目标），
	// 对应上游的 ctx.acls——最终用它判只读（dispatcher.uc:993-1004）。
	groups := append([]string{}, r.ACLGroups...)
	// 下钻还会继续并 auth（firstchild 的当选支路 / alias 目标），所以这里的初值只是起点
	auth := r.Auth

	// firstchild 下钻与 alias 回落。循环上限 4 是防 menu.d 写出来的环
	// （A alias 到 B、B alias 回 A），不是性能考虑。
	for i := 0; i < 4; i++ {
		if node == nil {
			return Page{Kind: KindNotFound}
		}

		if node.ActionType == "firstchild" {
			// 无会话时会在「login 模式」下竞选——当选支路可能才带上 auth.login（上游 :593）
			node = FirstChild(node, sid, &groups, &auth, false, deps)
			continue
		}

		if node.ActionType == "alias" {
			target := node.ActionPath
			if len(target) == 0 {
				return Page{Kind: KindNotFound}
			}
			if target[0] != '/' {
				target = "/" + target
			}
			alias := Resolve(tree, target, sid, deps)
			if loginRequired(alias.Auth, sid) {
				// 上游 alias 是**重新 dispatch** 一遍目标路径：目标自己那份 ctx.auth
				// 说了算，所以这里不是合并而是替换。
				return Page{Kind: KindLoginRequired, Body: renderLoginRequired(target)}
			}
			if !alias.Found {
				return Page{Kind: KindNotFound}
			}
			groups = append(groups, alias.ACLGroups...)
			auth = alias.Auth
			node = alias.Node
			continue
		}

		break
	}

	// 下钻结束再判一次（firstchild 当选支路自带 auth.login 的情况）
	if loginRequired(auth, sid) {
		return Page{Kind: KindLoginRequired, Body: renderLoginRequired(path)}
	}

	if node == nil {
		return Page{Kind: KindNotFound}
	}

	// 上游 :1006-1011：action 取自**下钻结束后的**节点，并在有剩余段时用通配 action
	action := effectiveAction(node, r.Args)
	if action.Type != "view" {
		// cbi / form / template / function / call 都要 ucode 或模板引擎，只回 501。
		//
		// 501 的正文带上命中信息：设备上真实 menu.d 的 action.type 分布是
		// view 311 / firstchild 43 / function 31 / alias 21 / template 6 / call 1，
		// 只看到一句「not implemented」根本不知道落到了哪个节点（实测踩过）。
		body := fmt.Sprintf("not implemented: action.type=%s view=%s menu=%s\n",
			action.Type, action.Path, path)
		return Page{Kind: KindNotImplemented, Body: body}
	}

	// 只读 = 并集里**没有任何一组**拿到 write（上游 `perm == false` → node.readonly）。
	// 缺组的情况在下降时就裁掉了（404），所以这里只可能是 Writable / ReadOnly。
	readonly := false
	if deps != nil {
		readonly = deps.SessionACLLevel(sid, groups) == backend.ACLReadOnly
	}

	return Page{Kind: KindPage, Body: renderPlaceholder(node, action, r.Args, readonly)}
}
