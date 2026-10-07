package handlers

import (
	"io"
	"net/http"
	"strings"

	"github.com/azhai/molly/internal/luci"
)

// /cgi-bin/luci —— ucode dispatcher 的 HTTP 入口。
//
// PATH_INFO 是前缀**之后**的路径（上游 LuCI 的约定）：/cgi-bin/luci 本身与
// /cgi-bin/luci/ 都是空路径，走菜单树的 root firstchild；/cgi-bin/luci/admin/...
// 才逐段下降。path 已经过 httpx.NormalizePath，尾部 '/' 已被压掉。
//
// 两种模式（ADR 0003）：
//   - LuciCGI 非空 → 整个 /cgi-bin/luci 前缀交给子进程（设备上的 ucode dispatcher，
//     复刻 uhttpd 的 ucode_prefix 接线）。方法不限，由脚本自己判定。
//   - 否则       → 内置 dispatcher（internal/luci），只接 GET/HEAD。
//
// 会话 id 从 LuCI 写的 cookie 里取（`sysauth_http` / `sysauth_https`），没有 cookie
// 就是「无会话」——带 depends.acl 的节点一律不可见（路径解析不到 → 404），路径上有
// auth.login 的节点则回 403 + X-LuCI-Login-Required。
type LuciConfig struct {
	MenuDir    string
	LuciCGI    string
	Docroot    string
	UbusSocket string
	Deps       luci.Deps
}

func ServeLuci(w http.ResponseWriter, r *http.Request, path string, cfg LuciConfig) {
	// 树路径 = URL 路径去掉前缀、再补回 LuciStripSegment 省掉的那一段（见 LuciTreePath）。
	// CGI 那条路的 PATH_INFO 也用它 —— 否则 ucode dispatcher 会从树根去找 `status`，
	// 找不到（它挂在 admin 下面），于是每个页面都 404。
	treePath := LuciTreePath(path)

	if cfg.LuciCGI != "" {
		body, _ := io.ReadAll(r.Body)
		runCGI(w, r, treePath, cfg.Docroot, cfg.LuciCGI, cfg.UbusSocket, body)
		return
	}

	// 上游 CGI 只接 GET（HEAD 由 HTTP 层处理成「有头无体」）
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		Respond(w, r, http.StatusMethodNotAllowed, "method not allowed\n", "text/plain; charset=utf-8")
		return
	}

	tree, menuOK := luci.LoadTree(cfg.MenuDir, cfg.Deps)
	if !menuOK {
		// 菜单目录读不到：没有页面可服务，全部 404。LoadTree 已经打过一行日志。
		Respond(w, r, http.StatusNotFound, "not found\n", "text/plain; charset=utf-8")
		return
	}

	page := luci.Dispatch(tree, treePath, luciSIDFromCookie(r), cfg.Deps)
	switch page.Kind {
	case luci.KindPage:
		Respond(w, r, http.StatusOK, page.Body, "text/html; charset=utf-8")
	case luci.KindNotFound:
		Respond(w, r, http.StatusNotFound, "not found\n", "text/plain; charset=utf-8")
	case luci.KindNotImplemented:
		// 正文由 luci.Dispatch 给（带 action.type / view / menu，便于在设备上定位）
		Respond(w, r, http.StatusNotImplemented, page.Body, "text/plain; charset=utf-8")
	case luci.KindLoginRequired:
		// 上游 dispatcher.uc:942-960：403 Forbidden + `X-LuCI-Login-Required: yes` + 登录页
		// （正文由主题的 sysauth 模板渲染）。molly 把状态码与响应头对齐，正文换成占位提示。
		RespondFull(w, r, http.StatusForbidden, []ExtraHeader{
			{Name: "Content-Type", Value: "text/html; charset=utf-8"},
			{Name: "X-LuCI-Login-Required", Value: "yes"},
		}, page.Body)
	}
}

// luciSIDFromCookie 从 `Cookie` 头里取会话 id。三种名字都收：
//   - `sysauth_molly`：molly 侧 dispatcher 补丁下发的专属名（与 :80 的
//     `sysauth_http` 并列共存，避免同主机同路径的 cookie 互相覆盖）；
//   - `sysauth_https` / `sysauth_http`：上游按 `HTTPS` 二选一
//     （dispatcher.uc:963-966），以及未打补丁的形态。
//
// 谁在就用谁，省掉对代理链与补丁状态的猜测。cookie 之间用 ';' 分隔，取不到回空串
// （调用方按「无会话」处理）。新手版也用这个函数，于是两套界面共用同一个登录。
func luciSIDFromCookie(r *http.Request) string {
	header := r.Header.Get("Cookie")
	if header == "" {
		return ""
	}

	for _, name := range []string{"sysauth_molly", "sysauth_https", "sysauth_http"} {
		for _, part := range strings.Split(header, ";") {
			part = strings.TrimSpace(part)
			eq := strings.IndexByte(part, '=')
			if eq <= 0 {
				continue
			}
			if strings.EqualFold(part[:eq], name) {
				return strings.TrimSpace(part[eq+1:])
			}
		}
	}
	return ""
}
