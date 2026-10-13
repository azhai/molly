package handlers

// simple —— 简洁版（/lite）handler（对齐 internal/handlers/simple.go）。
//
// 一个前缀、一份页面：/lite 及其**任意子路径**都回同一份单页 HTML（路由在 #/片段里，深链/刷新/
// 后退都成立）；/ 只是入口，302 到 /lite/（302 而非 301：前缀以后还可能再挪）。页面本体与
// Mithril 由 molly:assets 编译期内嵌，服务端只做占位符替换 + 注入 sid/menu/expert。
//
// 与专家版共用同一条会话：同一个 cookie（sysauth_*，path=/ 覆盖 /lite 与 /admin）、同一个 ubus
// session 对象——在哪边登录，另一边刷新即可用。认证面在 /auth/*（见 auth.odin），这里只出页面。

import "core:strings"
import "molly:http"
import "molly:assets"

// Simple_Prefix —— 简洁版 URL 前缀；`/` 只是入口，302 到这里。
Simple_Prefix :: "/lite"

// Is_Simple_Path —— 该路径是否属于简洁版（前缀本身或前缀/ 下的任意子路径）。
Is_Simple_Path :: proc(path: string) -> bool {
	return path == Simple_Prefix || strings.has_prefix(path, Simple_Prefix+"/")
}

// Is_Simple_Entry —— 是否是简洁版入口 `/`（对入口只 302，不出页面）。
Is_Simple_Entry :: proc(path: string) -> bool {
	return path == "/"
}

// Serve_Simple —— 送简洁版页面，并把 `/` 做成 302 入口。expert 是专家版前缀（注入页面「前往专家版」
// 链接的 href），由 main 从部署配置传入（与路由/CGI 的 SCRIPT_NAME 同源）。
Serve_Simple :: proc(res: ^http.Response, req: ^http.Request, path, expert: string) {
	if Is_Simple_Entry(path) {
		simple_redirect(res, Simple_Prefix+"/")
		return
	}
	if req.method != "GET" && req.method != "HEAD" {
		http.Respond(res, 405, "method not allowed\n", "text/plain; charset=utf-8")
		return
	}
	http.Respond(res, 200, build_simple_page(expert, sid_from_cookie(req)), "text/html; charset=utf-8")
}

// build_simple_page —— 注入配置（sid、菜单、专家版前缀）与内嵌 Mithril。
// sid 先过 sanitize_sid（白名单收窄到 hex）：它来自客户端 Cookie，要拼进页面 JS 字符串——
// 白名单比在 HTML/JS 两种上下文各转义一遍可靠。两个占位符各替一次，先 __CFG__ 再 __MITHRIL__。
build_simple_page :: proc(expert, sid: string) -> string {
	cfg := assets.ConfigJSON(assets.Config{
		sid    = sanitize_sid(sid),
		menu   = assets.Menu,
		expert = expert,
	})
	html, _ := strings.replace_all(assets.HTML(), "__CFG__", cfg)
	page, _ := strings.replace_all(html, "__MITHRIL__", assets.MITHRIL())
	return page
}

// simple_redirect —— 302 + Location + 空正文（Emit 会重算 Content-Length:0），不发 Date。
simple_redirect :: proc(res: ^http.Response, location: string) {
	hdrs := []http.Header{http.Header{"Location", location}}
	http.Emit(res, 302, hdrs, "")
}
