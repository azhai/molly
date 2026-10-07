package handlers

import (
	"net/http"
	"strings"

	"github.com/azhai/molly/webassets/expert"
)

// ServeExpert 送出专家版页面 —— 我们自己实现的 Go + HTML 站点。
//
// 与此前那套（ucode dispatcher / LuCI 主题 / 内置占位 dispatcher）的根本区别：
// **页面不是渲染出来的，是一份静态文件**。服务端只做两件事——发文件、把两个占位符换掉：
//
//	__SID__   会话 id（空串 = 未登录，页面自己弹登录卡）
//	__MENU__  菜单 JSON（webassets.Menu，编译进二进制）
//
// 因此专家版**不再需要 menu.d、不再需要 ucode、也不再需要 uhttpd**：菜单是 Go 侧数据，
// 具体动作全走 /ubus。这正是「整个网站用 Go 重新实现，只有执行具体操作才调 ubus」。
//
// 任何子路径都回同一份 HTML（单页应用，路由在 #/ 片段里）：页面刷新、深链、后退都成立。
// --luci-cgi 非空时**不走这里**（那是保留的旧路径：设备 ucode dispatcher 渲染完整 LuCI）。
func ServeExpert(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		Respond(w, r, http.StatusMethodNotAllowed, "method not allowed\n", "text/plain; charset=utf-8")
		return
	}
	Respond(w, r, http.StatusOK, buildExpertPage(luciSIDFromCookie(r)), "text/html; charset=utf-8")
}

// buildExpertPage 注入会话 id 与菜单。
//
// sid 先经过 sanitizeSID（白名单收窄到 32 位 hex）：它来自客户端 Cookie，而要拼进页面的
// JS 字符串——白名单比在 HTML/JS 两种上下文里各转义一遍可靠。
//
// 用 strings.ReplaceAll 而不是 fmt：页面里有大量 %（CSS 百分比、JS 取模），走格式化容易踩。
func buildExpertPage(sid string) string {
	page := strings.ReplaceAll(expert.HTML, "__SID__", sanitizeSID(sid))
	return strings.ReplaceAll(page, "__MENU__", expert.MenuJSON())
}
