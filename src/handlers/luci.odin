package handlers

// luci —— 专家版前缀（默认 /cgi-bin/luci，本站 /admin）的 HTTP 入口（对齐 internal/handlers/luci.go）。
//
// PATH_INFO 是前缀**之后**的路径：前缀本身与「前缀/」都是空路径，走菜单树 root firstchild；
// `<prefix>/admin/...` 才逐段下降。path 已过 http.Normalize_Path（尾 '/' 压掉）。
//
// 两种模式（ADR 0003）：
//   - 默认（luci_cgi 空）→ **内置 dispatcher**（src/luci：建树、depends、firstchild、通配、
//     ACL 裁树逐条复刻上游 dispatcher.uc）；只接 GET/HEAD；视图未落地 → cbi/view/template 那类
//     节点回 501 并带 action.type / view / menu。
//   - luci_cgi 非空 → 整个前缀交给设备上的 ucode dispatcher 子进程（对照/排查用，非部署形态）。
//     这条子进程桥在 cgi_run.odin 的 run_cgi；GET/POST/HEAD 等方法一律交给子进程自行裁处。
//
// 会话 id 复用 sid_from_cookie（auth.odin，= Go 的 luciSIDFromCookie）：从 sysauth_* cookie 取，
// 没有 cookie 就是「无会话」——带 depends.acl 的节点不可见（解析不到 → 404），路径上有 auth.login
// 的节点回 403 + X-LuCI-Login-Required。

import "core:strings"
import "molly:http"
import "molly:luci"

// Luci_Config 是专家版入口需要的部署参数（对齐 Go 的 LuciConfig）。
//   menu_dir：menu.d 目录（每棵树的 JSON 片段）；
//   deps：uci/ACL 接缝（生产用 luci.Backend_Deps()）；
//   luci_prefix / strip_segment：URL 前缀与被省掉的树段（见 luci_tree_path）；
//   luci_cgi / docroot / ubus_socket：s4e 的 CGI 对照路径所需。
Luci_Config :: struct {
	menu_dir:      string,
	deps:          luci.Deps,
	luci_prefix:   string,
	strip_segment: string,
	luci_cgi:      string,
	docroot:       string,
	ubus_socket:   string,
}

// luci_tree_path —— 「URL 路径」→「菜单树路径」（对齐 Go 的 LuciTreePath，纯函数、host 可测）：
//  1. 去掉专家版前缀（那一段是 CGI 的 SCRIPT_NAME，不参与树解析）；
//  2. 把 strip_segment 补回去（URL 省了它，树里没省）。
//
// 已经是长写法（`/<段>/…`）照旧接受，旧链接不会因换前缀而失效。
// 例（prefix=/admin、strip=/admin）：/admin/status/overview 自消 → /admin/status/overview；
// <prefix> 本身 → "/"（root，走 firstchild）。
luci_tree_path :: proc(url_path, prefix, strip: string) -> string {
	rest := url_path
	if strings.has_prefix(rest, prefix) {
		rest = rest[len(prefix):]
	}
	if strip == "" {
		return rest
	}
	if rest == "" || rest == "/" {
		return "/"
	}
	// strip 归一化过：必带前导斜杠。已是长写法就不重复补。
	if rest == strip || strings.has_prefix(rest, build([]string{strip, "/"})) {
		return rest
	}
	return build([]string{strip, rest})
}

// Serve_Luci —— 专家版前缀入口。path 是路由 normalize 后的 URL 路径（含前缀）。
Serve_Luci :: proc(res: ^http.Response, req: ^http.Request, path: string, cfg: Luci_Config) {
	tree_path := luci_tree_path(path, cfg.luci_prefix, cfg.strip_segment)

	// --luci-cgi 那条对照路（整段前缀交给 ucode 子进程）：方法门由子进程自裁（CGI 也接 POST），
	// 故必须在下面「内置 dispatcher 只接 GET/HEAD」的 405 门**之前**分叉出去。
	if cfg.luci_cgi != "" {
		run_cgi(res, req, tree_path, cfg.docroot, cfg.luci_cgi, cfg.ubus_socket, cfg.luci_prefix, cfg.strip_segment)
		return
	}

	// 内置 dispatcher 只接 GET（HEAD 由 HTTP 层处理成「有头无体」）。
	if req.method != "GET" && req.method != "HEAD" {
		http.Respond(res, 405, "method not allowed\n", "text/plain; charset=utf-8")
		return
	}

	tree, ok := luci.Load_Tree(cfg.menu_dir, cfg.deps)
	if ! ok {
		// 菜单目录读不到：没有页面可服务，全部 404（Load_Tree 已打过一行日志）。
		http.Respond(res, 404, "not found\n", "text/plain; charset=utf-8")
		return
	}

	page := luci.Dispatch(tree, tree_path, sid_from_cookie(req), cfg.deps)
	switch page.kind {
	case .Page:
		http.Respond(res, 200, page.body, "text/html; charset=utf-8")
	case .Not_Found:
		http.Respond(res, 404, "not found\n", "text/plain; charset=utf-8")
	case .Not_Implemented:
		// 正文由 Dispatch 给（带 action.type / view / menu，便于在设备上定位缺哪个页面）。
		http.Respond(res, 501, page.body, "text/plain; charset=utf-8")
	case .Login_Required:
		// 上游 dispatcher.uc:942-960：403 Forbidden + `X-LuCI-Login-Required: yes` + 登录页。
		// 头名原样透传（Emit 不做 MIME 规范化），Content-Length 由 Emit 重算。
		hdrs := []http.Header{
			http.Header{"Content-Type", "text/html; charset=utf-8"},
			http.Header{"X-LuCI-Login-Required", "yes"},
		}
		http.Emit(res, 403, hdrs, page.body)
	}
}
