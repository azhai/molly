package handlers

import (
	"encoding/json"
	"net/http"
	"strings"

	"github.com/azhai/molly/internal/backend"
	"github.com/azhai/molly/webassets"
)

// 新手版（novice）—— 一页只放最常见的六件事：系统状态、实时负载、重启、内外网设置、
// 无线中继、DHCP 分配与 MAC 绑定。页面在 webassets/novice/index.html（编译期嵌入）。
//
// 与专家版（LuCI，前缀见 LuciPrefix）的分工：
//   - 专家版吃 LuciPrefix（本站部署是 `/plus`），内容交给设备上的 ucode dispatcher；
//   - 新手版吃 `/lite`（常量 NovicePrefix），页面是**编译进二进制的单文件**，不碰 ucode、
//     也不依赖 docroot 上的任何文件；`/` 只是入口，302 到 `/lite/`。
//
// **两套界面是同一条会话**：
//   - 会话载体是同一个 cookie（sessionCookie + path=/，见 setSessionCookie）——path=/
//     同时覆盖 `/`、`/lite`、`/plus`，所以在哪一边登录另一边都直接可用；
//   - 登录走同一个 ubus 对象（deps.CallObject("session","login")）——专家版那边是 ucode
//     dispatcher 调它，所以「统一」是这条链路的自然结果，不是又实现了一套；
//   - 数据面是同一个 `/ubus` JSON-RPC（前端直接发 `params: [sid, obj, meth, args]`）。
//
// 于是「在哪边登录都行，另一边刷新即可用」；没有第二套鉴权，也没有 localStorage 里的
// 影子会话。

const (
	// sessionCookie 是**两套界面共用的**会话 cookie 名。设备上 dispatcher 的补丁在
	// MOLLY_UBUS_SOCKET 存在时也下发这个名字，luciSIDFromCookie 同样优先读它。
	sessionCookie = "sysauth_molly"

	// anonSID 是 ubus 的匿名会话哨兵：只有 session.login / access 这类少数方法对它放行。
	anonSID = "00000000000000000000000000000000"

	// NovicePrefix 是**新手版**的 URL 前缀（本站 `/lite`）。`/` 自己不带页面，只 302 到这里。
	//
	// 为什么 `/` 不就地服务页面而是跳转：新手版与专家版各有一个稳定的短前缀
	// （`/lite` 与 `--luci-prefix` 给的 `/plus`），`/` 只当「进来先落到新手版」的入口。
	// 跳转过去还有个实际好处：页面里的资源链接是相对的（`luci-static/…`），停在
	// `/lite/` 上它们才解析到 `/lite/luci-static/…`。
	NovicePrefix = "/lite"
)

// IsNovicePath 报告该路径是否属于新手版页面。页面是单文件（CSS/JS 内联），所以只有入口
// 那几个：规范化后的 `/lite`、`/lite/index.html`，以及容错的 `/lite/`。
func IsNovicePath(path string) bool {
	return path == NovicePrefix || path == NovicePrefix+"/" || path == NovicePrefix+"/index.html"
}

// IsNoviceEntry 报告该路径是不是新手版**入口**（`/`）。对入口只回 302，不出页面。
func IsNoviceEntry(path string) bool { return path == "/" }

// ServeNovice 送出新手版页面（`/lite`），并把 `/` 做成跳转入口。
//
// 这里**只出页面**（GET/HEAD）：登录、退出、改口令都在 `/auth/*` 那三个共用端点上
// （见 auth.go）。此前登录/退出是 POST 打到本页的 action=login|logout，现已移除——
// 认证面散在两套界面的 URL 上正是这次要收掉的东西。
func ServeNovice(w http.ResponseWriter, r *http.Request, path string, deps backend.Backend) {
	// 入口：/ → /lite/。用 302 而不是 301/308——前缀以后还可能再挪，301 会被浏览器
	// 永久缓存住（改版后用户拿着旧地址打不开）。
	if IsNoviceEntry(path) {
		noviceRedirect(w, r, NovicePrefix+"/")
		return
	}
	if !IsNovicePath(path) {
		return
	}
	switch r.Method {
	case http.MethodGet, http.MethodHead:
		Respond(w, r, http.StatusOK, buildNovicePage(luciSIDFromCookie(r)), "text/html; charset=utf-8")
	default:
		Respond(w, r, http.StatusMethodNotAllowed, "method not allowed\n", "text/plain; charset=utf-8")
	}
}

// novicelogin 调 `session login` 并取出 sid；任何失败都回空串（调用方按登录失败处理）。
// 走 deps.CallObject 而不是自己实现鉴权：这就是专家版用的那一个对象。
func novicelogin(deps backend.Backend, paramsJSON string) string {
	if deps == nil {
		return ""
	}
	res := deps.CallObject("session", "login", paramsJSON, anonSID)
	if res.Outcome != backend.OutcomeOk || res.Ret != 0 {
		return ""
	}
	var reply struct {
		SID string `json:"ubus_rpc_session"`
	}
	if err := json.Unmarshal([]byte(res.Reply), &reply); err != nil {
		return ""
	}
	// 只接受合法形态的 sid（32 位 hex）：它随后要进 cookie 与页面，收窄一次比到处转义省心。
	return sanitizeSID(reply.SID)
}

// setSessionCookie 下发**两套界面共用**的会话 cookie。
//
// path=/ 是关键：专家版前缀（`/pro/`）与新手版（`/`）都要能读到它，否则就是对不上号的
// 两条会话。HttpOnly 让页面脚本拿不到它（页面用的是服务端注入的 sid，不需要自己读）；
// SameSite=strict 与上游 dispatcher 一致，顺带挡掉跨站提交。
func setSessionCookie(w http.ResponseWriter, sid string) {
	http.SetCookie(w, &http.Cookie{
		Name:     sessionCookie,
		Value:    sid,
		Path:     "/",
		HttpOnly: true,
		SameSite: http.SameSiteStrictMode,
	})
}

func clearSessionCookie(w http.ResponseWriter) {
	http.SetCookie(w, &http.Cookie{
		Name:     sessionCookie,
		Value:    "",
		Path:     "/",
		HttpOnly: true,
		SameSite: http.SameSiteStrictMode,
		MaxAge:   -1,
	})
}

// noviceRedirect 发一个 302。与 Respond 一样不发 Date（net/http 默认会补，用置 nil 抑制），
// 保持与其它响应一致的头部行为。
func noviceRedirect(w http.ResponseWriter, r *http.Request, location string) {
	h := w.Header()
	h["Date"] = nil
	h.Set("Location", location)
	h.Set("Content-Length", "0")
	w.WriteHeader(http.StatusFound)
}

// buildNovicePage 把页面里的两个占位符换掉：`__SID__`（会话 id）与
// `__EXPERT_PREFIX__`（专家版前缀）。
//
// 用 ReplaceAll 而不是 fmt：页面里有大量 `%`（CSS 的百分比、JS 的取模），走格式化很
// 容易踩。替换顺序也无关：两个占位符互不包含，且 sid 已被收窄成 hex。
func buildNovicePage(sid string) string {
	page := strings.ReplaceAll(webassets.NoviceHTML, "__SID__", sanitizeSID(sid))
	return strings.ReplaceAll(page, "__EXPERT_PREFIX__", LuciPrefix)
}

// sanitizeSID 只保留十六进制字符（会话 id 就是 32 位 hex）。
//
// 为什么不是「转义」而是「白名单过滤」：这个值来自客户端的 Cookie，而它要被拼进
// **HTML 里的 JavaScript 字符串**。任何引号/尖括号/反斜杠都可能变成脚本注入——
// 与其在两种上下文（HTML 与 JS）里各转义一遍，不如按已知形态收窄到「只可能是它」。
// 非法输入退化成空串，页面就显示登录卡，行为可预期。
// 按字节判即可：非 ASCII 字节必然不是 hex，直接整串丢弃。
func sanitizeSID(sid string) string {
	if sid == "" {
		return ""
	}
	buf := make([]byte, 0, 32)
	for i := 0; i < len(sid); i++ {
		c := sid[i]
		isHex := (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
		if !isHex {
			return "" // 出现非 hex 字符：整个丢弃，别做「截断到第一个非法字符」这种猜测
		}
		buf = append(buf, c)
		if len(buf) == 32 {
			break
		}
	}
	return string(buf)
}
