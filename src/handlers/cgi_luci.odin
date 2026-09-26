package handlers

import "core:mem"

import "molly:http"
import "molly:luci"

// /cgi-bin/luci —— ucode dispatcher 的 HTTP 入口。
//
// PATH_INFO 是前缀**之后**的路径（上游 LuCI 的约定）：/cgi-bin/luci 本身与
// /cgi-bin/luci/ 都是空路径，走菜单树的 root firstchild；/cgi-bin/luci/admin/...
// 才逐段下降。path 已经过 http.normalize_path，尾部 '/' 已被压掉。
//
// P2 只做 dispatcher 骨架（计划决策 6）：不认证、不校验 ACL、不渲染模板。
// 认证与 ACL 是 P3 的范围，页面上会显式打出这条横幅。

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
		})
	}

	page := luci.dispatch(tree, path[len(LUCI_PREFIX):], alloc)
	switch page.kind {
	case .Page:
		return http.respond(conn, .OK, page.body, {
			content_type = "text/html; charset=utf-8",
			keep_alive   = req.keep_alive,
			head_only    = req.method == .Head,
		})
	case .NotFound:
		return http.respond(conn, .Not_Found, "not found\n", {
			keep_alive = req.keep_alive,
		})
	case .Not_Implemented:
		// 正文由 luci.dispatch 给（带 action.type / view / menu，便于在设备上定位）
		return http.respond(conn, .Not_Implemented, page.body, {
			keep_alive = req.keep_alive,
		})
	}
	return false
}