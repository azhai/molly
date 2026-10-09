package handlers

import (
	"net/http"
	"strings"

	"github.com/azhai/molly/internal/backend"
	"github.com/azhai/molly/webassets/simple"
)

// 简洁版（simple）—— 一个站点、**一个前缀**：
//
//	/lite   全部页面。仪表盘（设备状态、实时负载、上网设置、无线中继、DHCP 分配）是第一屏，
//	        其余页面走 `#/片段`：内外网、无线、DHCP、系统、日志、服务、存储、诊断、备份。
//	/auth   登录 / 退出 / 改口令 —— 与专家版共用（见 auth.go），前缀保留不变。
//
// 整个前缀下的**任意路径**都回同一份 HTML：它是单页应用，路由在 `#/` 片段里，所以刷新、
// 深链、浏览器前进后退都成立。
//
// 与专家版（用 Go 重写的 LuCI，前缀见 LuciPrefix）的分工：
//   - 简洁版页面是**编译进二进制的单文件**，不碰 ucode、不依赖 docroot 上的任何文件；
//   - **两边是同一条会话**：同一个 cookie（sessionCookie，path=/ 同时覆盖 /lite 与 /admin），
//     用的也是同一个 ubus session 对象。在哪边登录，另一边刷新即可用。
const (
	// SimplePrefix 是简洁版的 URL 前缀。`/` 只是入口，302 到这里。
	//
	// 为什么 `/` 不就地服务页面而是跳转：站点有稳定的短前缀，`/` 只当「进来先落到简洁版」
	// 的入口（302 而不是 301——前缀以后还可能再挪，301 会被浏览器永久缓存住）。
	SimplePrefix = "/lite"
)

// IsSimplePath 报告该路径是否属于简洁版。
//
// 它吃整个前缀下的**任意子路径**（不只入口那几个）：单页应用的深链/刷新/后退都要成立，
// 浏览器只发路径部分（`#/net` 里的片段不会到服务端）。
func IsSimplePath(path string) bool {
	return path == SimplePrefix || strings.HasPrefix(path, SimplePrefix+"/")
}

// IsSimpleEntry 报告该路径是不是简洁版入口（`/`）。对入口只回 302，不出页面。
func IsSimpleEntry(path string) bool { return path == "/" }

// ServeSimple 送出简洁版页面，并把 `/` 做成跳转入口。
//
// 这里**只出页面**（GET/HEAD）：登录、退出、改口令都在 `/auth/*` 那三个共用端点上
// （见 auth.go）。认证面散在两套界面的 URL 上正是此前要收掉的东西。
func ServeSimple(w http.ResponseWriter, r *http.Request, path string, deps backend.Backend) {
	if IsSimpleEntry(path) {
		simpleRedirect(w, r, SimplePrefix+"/")
		return
	}
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		Respond(w, r, http.StatusMethodNotAllowed, "method not allowed\n", "text/plain; charset=utf-8")
		return
	}
	Respond(w, r, http.StatusOK, buildSimplePage(luciSIDFromCookie(r)), "text/html; charset=utf-8")
}

// buildSimplePage 注入配置（会话 id、菜单、专家版前缀）。
//
// sid 先经过 sanitizeSID（白名单收窄到 32 位 hex）：它来自客户端 Cookie，而要拼进页面的
// JS 字符串——白名单比在 HTML/JS 两种上下文里各转义一遍可靠。
//
// expert 就是 LuciPrefix 这一个值：路由判据、CGI 的 SCRIPT_NAME、页面里的「前往专家版」
// 链接三者同源，分头写就会不一致（见 response.go 的 LuciPrefix 注释）。
//
// 用 strings.ReplaceAll 而不是 fmt：页面里有大量 %（CSS 百分比、JS 取模），走格式化容易踩。
func buildSimplePage(sid string) string {
	cfg := simple.ConfigJSON(simple.Config{
		SID:    sanitizeSID(sid),
		Menu:   simple.Menu,
		Expert: LuciPrefix,
	})
	return strings.ReplaceAll(simple.HTML, "__CFG__", cfg)
}

// simpleRedirect 发一个 302。与 Respond 一样不发 Date（net/http 默认会补，用置 nil 抑制），
// 保持与其它响应一致的头部行为。
func simpleRedirect(w http.ResponseWriter, r *http.Request, location string) {
	h := w.Header()
	h["Date"] = nil
	h.Set("Location", location)
	h.Set("Content-Length", "0")
	w.WriteHeader(http.StatusFound)
}
