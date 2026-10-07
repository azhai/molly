// Package handlers —— HTTP 处理器层。
//
// 路由顺序与 Odin 版一致（normalize → /ubus → /cgi-bin/luci → 静态）：
// 静态文件见 static.go，/ubus 的 JSON-RPC 信封见 ubus.go，
// /cgi-bin/luci 的 dispatcher 与 CGI 子进程桥见 luci.go / cgi.go。
package handlers

import (
	"fmt"
	"html"
	"io"
	"net/http"
	"strconv"
	"strings"
)

// 路由前缀。前缀匹配必须带边界（见 cmd/molly 的 matchesPrefix），
// 否则 /ubus.html 这类真实文件会被 ubus 路由抢走。
const UBUSPrefix = "/ubus"

// LuciPrefix 是**专家版（LuCI）的 URL 前缀**，默认是上游形态 "/cgi-bin/luci"；
// `--luci-prefix` 可改（本仓部署把它放到 "/pro"，把 "/" 留给新手版，见 novice.go）。
//
// 为什么是变量而不是常量：这**一个值同时决定三件事**——路由判据、CGI 的
// SCRIPT_NAME、PATH_INFO 的切分点（见 cgi.go）。三者必须同源，散着写就会出现
// 「路由换了、SCRIPT_NAME 没换」这种 ucode 侧全错的组合（dispatcher 的 build_url
// 就是拿 SCRIPT_NAME 拼所有页面 URL 的）。
//
// 与 Odin 版 src/handlers/cgi_luci.odin 的 LUCI_PREFIX / luci_set_prefix 同名同义。
var LuciPrefix = "/cgi-bin/luci"

// SetLuciPrefix 设置专家版前缀。形态不合法时返回错误，调用方应当启动即失败
// （像 Odin 版的 luci_set_prefix + die 一样，不做静默兜底）。
func SetLuciPrefix(p string) error {
	if len(p) < 2 || p[0] != '/' || p[len(p)-1] == '/' {
		return fmt.Errorf("--luci-prefix 形态不合法：%q（要 '/' 开头、不以 '/' 结尾）", p)
	}
	if strings.ContainsAny(p, " \t?#") {
		return fmt.Errorf("--luci-prefix 不能含空白或 ? #：%q", p)
	}
	LuciPrefix = p
	return nil
}

// LuciStripSegment 是从专家版 URL 里**省掉**的那一段菜单路径（`--luci-strip`）。
//
// 为什么要这个：LuCI 的页面在 URL 上是 `/cgi-bin/luci/admin/status/overview`——顶层那个
// `admin` 是菜单树里的一个节点。本站部署嫌它多一层，想让 URL 变成 `/plus/status/overview`。
//
// 但菜单树本身没变：`status/overview` 仍然挂在 `admin` 下面。所以进树时要把这一段**补回
// 回去**（见 LuciTreePath），而 URL 侧少了它——两边不是一回事，这也是最容易搞混的地方。
//
// 空串（默认）= 不省，URL 与上游完全一致。
var LuciStripSegment = ""

// SetLuciStripSegment 设置被省掉的那一段；形态与前缀同样要求 `/` 开头、不以 `/` 结尾。
// 传空串表示不省。
func SetLuciStripSegment(seg string) error {
	seg = strings.TrimSpace(seg)
	if seg == "" {
		LuciStripSegment = ""
		return nil
	}
	// 容错：`--luci-strip admin` 与 `--luci-strip /admin` 等价。前者少写一个斜杠就
	// 让进程启动失败太不划算——这个值只是要在树路径前面拼一段，不是 URL。
	if !strings.HasPrefix(seg, "/") {
		seg = "/" + seg
	}
	if len(seg) < 2 || seg[len(seg)-1] == '/' {
		return fmt.Errorf("--luci-strip 形态不合法：%q（写成 admin 或 /admin，或留空）", seg)
	}
	LuciStripSegment = seg
	return nil
}

// LuciTreePath 把「URL 路径」换算成「菜单树路径」：
//
// 1. 去掉专家版前缀（那一段是 CGI 的 SCRIPT_NAME，不参与树解析）；
// 2. 把 LuciStripSegment 补回去（URL 省了它，树里没省）。
//
// 已经是长写法（`/<段>/…`）照旧接受，旧的链接不会因为这次改动就失效。
//
// 例（prefix=/plus、strip=admin）：`/plus/status/overview` → `/admin/status/overview`；
// `/plus/admin/status/overview` → 原样；`/plus` → `/`（root，走 firstchild）。
func LuciTreePath(urlPath string) string {
	rest := strings.TrimPrefix(urlPath, LuciPrefix)
	if LuciStripSegment == "" {
		return rest
	}
	if rest == "" || rest == "/" {
		return "/"
	}
	seg := LuciStripSegment // 归一化过：必带前导斜杠
	if rest == seg || strings.HasPrefix(rest, seg+"/") {
		return rest
	}
	return seg + rest
}

// Respond 写一个响应。
//
// 与 Odin 版 src/http/response.odin 的语义对齐：
//   - Content-Length 与 Content-Type 恒由本层决定，不依赖 Go 的自动推断；
//   - 不发 Date / Server 头（Odin 版是**故意**不发的，见 response.odin:66-69）。
//     net/http 默认会补 Date，用把该键置 nil 的方式抑制；
//   - HEAD 回完整头但不回 body。
func Respond(w http.ResponseWriter, r *http.Request, code int, body, contentType string) {
	h := w.Header()
	h["Date"] = nil // 抑制 net/http 自动补的 Date
	h.Set("Content-Type", contentType)
	h.Set("Content-Length", strconv.Itoa(len(body)))
	w.WriteHeader(code)
	if r.Method != http.MethodHead {
		_, _ = io.WriteString(w, body)
	}
}

// notFound 是 404 响应。**逐条对齐原厂 uhttpd**（2026-10-07 真机实测）：
//   - `Content-Type: text/html`（不是 text/plain）；
//   - 正文形如 `<h1>Not Found</h1>The requested URL <路径> was not found on this server.`
//     （uhttpd 无结尾换行）。
//
// **已知偏离（故意）**：uhttpd 把请求路径**原样回显**，这里做 HTML 转义——把未经转义的
// 请求数据拼进 HTML 是 XSS 面，不照抄。正文不参与 golden 对比（golden 只比状态码与头）。
func notFound(w http.ResponseWriter, r *http.Request, path string) {
	body := "<h1>Not Found</h1>The requested URL " + html.EscapeString(path) +
		" was not found on this server."
	Respond(w, r, http.StatusNotFound, body, "text/html")
}

// ExtraHeader 是一个要额外发出的响应头（CGI 桥与登录提示页用）。
// 名字保留原样，值里不得含 CRLF（解析时已按行切分）。
type ExtraHeader struct {
	Name  string
	Value string
}

// RespondFull 对齐 Odin 版 http.respond_full：状态码与额外响应头由调用方给
// （CGI 会返回 3xx/401 这类 Respond 枚举里没有的码，透传比枚举更保真），
// Content-Length 恒由本层重算，不发 Date / Server，HEAD 回完整头但不回 body。
func RespondFull(w http.ResponseWriter, r *http.Request, code int, headers []ExtraHeader, body string) {
	h := w.Header()
	h["Date"] = nil // 抑制 net/http 自动补的 Date
	for _, e := range headers {
		// 直接写 map（**不走** h.Add）：Add/Set 会按 Go 的 MIME 规范把头名规范化，
		// 即 `X-LuCI-Login-Required` → `X-Luci-Login-Required`；而 Odin 版是
		// **原样透传**头名（cgi_luci.odin:82）。要字节级对齐就必须绕过规范化，
		// net/http 写响应头时用的是 map 里的键，不会再次规范化。
		h[e.Name] = append(h[e.Name], e.Value)
	}
	h.Set("Content-Length", strconv.Itoa(len(body)))
	w.WriteHeader(code)
	if r.Method != http.MethodHead {
		_, _ = io.WriteString(w, body)
	}
}
