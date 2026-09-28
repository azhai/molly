package handlers

import "core:mem"
import "core:strings"

import "molly:http"
import "molly:luci"

// /cgi-bin/luci —— ucode dispatcher 的 HTTP 入口。
//
// PATH_INFO 是前缀**之后**的路径（上游 LuCI 的约定）：/cgi-bin/luci 本身与
// /cgi-bin/luci/ 都是空路径，走菜单树的 root firstchild；/cgi-bin/luci/admin/...
// 才逐段下降。path 已经过 http.normalize_path，尾部 '/' 已被压掉。
//
// P2 只做 dispatcher 骨架（计划决策 6）：不认证、不渲染模板。
// P3-6 起菜单裁树会带上会话 ACL：会话 id 从 LuCI 写的 cookie 里取
// （`sysauth_http` / `sysauth_https`，上游 dispatcher.uc:963-966），没有 cookie 就是
// 「无会话」——带 `depends.acl` 的节点一律不可见（路径解析不到 → 404）。
// **登录取会话本身**仍不在这里：上游由 dispatcher 渲染登录页，molly 按 ADR 0003
// 把整个前缀交给设备 ucode（`--luci-cgi`），这里只认既有会话。

LUCI_PREFIX :: "/cgi-bin/luci"

serve_luci :: proc(s: ^http.Server, conn: ^http.Connection, req: ^http.Request, path: string) -> bool {
	alloc := mem.dynamic_arena_allocator(&conn.arena)

	// 两种模式（ADR 0003）：
	//   --luci-cgi 非空 → 整个 /cgi-bin/luci 前缀交给子进程（设备上的 ucode dispatcher，
	//                    复刻 uhttpd 的 ucode_prefix 接线）。方法不限，由脚本自己判定。
	//   否则            → 内置的 Odin dispatcher（P2 形态，src/luci），只接 GET/HEAD。
	if len(s.luci_cgi) > 0 {
		return run_cgi(conn, req, path, s.docroot, s.luci_cgi, alloc)
	}

	// 上游 CGI 只接 GET（HEAD 由 HTTP 层处理成「有头无体」）
	if req.method != .Get && req.method != .Head {
		return http.respond(conn, .Method_Not_Allowed, "method not allowed\n", {
			keep_alive = req.keep_alive,
		})
	}

	tree, menu_ok := luci.load_tree(s.menu_dir, alloc)
	if !menu_ok {
		// 菜单目录读不到：没有页面可服务，全部 404。load_tree 已经打过一行日志。
		return http.respond(conn, .Not_Found, "not found\n", {
			keep_alive = req.keep_alive,
			head_only  = req.method == .Head,
		})
	}

	page := luci.dispatch(tree, path[len(LUCI_PREFIX):], luci_sid_from_cookie(req), alloc)
	switch page.kind {
	case .Page:
		return http.respond(conn, .OK, page.body, {
			content_type = "text/html; charset=utf-8",
			keep_alive   = req.keep_alive,
			head_only    = req.method == .Head,
		})
	case .NotFound:
		// HEAD 也要「有头无体」：P3-6 起 404 是常态（ACL 裁掉的节点），不再只出现在
		// 直接请求上——不设 head_only 会带一个 body 回去。
		return http.respond(conn, .Not_Found, "not found\n", {
			keep_alive = req.keep_alive,
			head_only  = req.method == .Head,
		})
	case .Not_Implemented:
		// 正文由 luci.dispatch 给（带 action.type / view / menu，便于在设备上定位）
		return http.respond(conn, .Not_Implemented, page.body, {
			keep_alive = req.keep_alive,
			head_only  = req.method == .Head,
		})
	case .Login_Required:
		// 上游 dispatcher.uc:942-960：403 Forbidden + `X-LuCI-Login-Required: yes` + 登录页
		// （正文由主题的 sysauth 模板渲染）。molly 把状态码与响应头对齐，正文换成占位提示
		// （render_login_required）——所以要用 respond_full 才能带自定义头。
		return http.respond_full(
			conn,
			403,
			"Forbidden",
			[]http.Extra_Header {
				{name = "Content-Type", value = "text/html; charset=utf-8"},
				{name = "X-LuCI-Login-Required", value = "yes"},
			},
			page.body,
			req.keep_alive,
			req.method == .Head,
			alloc,
		)
	}
	return false
}

// 从 `Cookie` 头里取 LuCI 的会话 id。上游按 `HTTPS` 二选一（`sysauth_https` /
// `sysauth_http`，dispatcher.uc:963-966）——这里两个都收，谁在就用谁，省掉对
// 代理链的猜测。cookie 之间用 ';' 分隔，取不到就回空串（调用方按「无会话」处理）。
@(private)
luci_sid_from_cookie :: proc(req: ^http.Request) -> string {
	header, has_header := http.header_value(req, "Cookie")
	if !has_header || len(header) == 0 {
		return ""
	}

	for name in ([]string{"sysauth_https", "sysauth_http"}) {
		rest := header
		for len(rest) > 0 {
			part: string
			if idx := strings.index_byte(rest, ';'); idx >= 0 {
				part, rest = rest[:idx], rest[idx + 1:]
			} else {
				part, rest = rest, ""
			}
			part = strings.trim_space(part)

			eq := strings.index_byte(part, '=')
			if eq <= 0 {
				continue
			}
			if strings.equal_fold(part[:eq], name) {
				return strings.trim_space(part[eq + 1:])
			}
		}
	}
	return ""
}