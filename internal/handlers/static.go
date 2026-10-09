package handlers

import (
	"net/http"
	"os"
	"strings"

	"github.com/azhai/molly/internal/httpx"
	"github.com/azhai/molly/webassets"
)

// IndexFile 是目录回落时追加的文件名。
const IndexFile = "/index.html"

// ServeStatic 提供 /www 静态文件，对应上游 uhttpd 的那部分。
//
// 调用约定：path 必须是 httpx.NormalizePath 的产物（已剥查询串、已百分号解码、
// 无 .. 段）；docroot 由 main 在启动时去掉尾部 '/'。
//
// 不缓存文件内容，每次请求都真读盘（与 Odin 版一致：缓存策略等真机压测有数据再定）。
// 符号链接照常跟随（os.Stat 而非 Lstat）：与原厂 uhttpd 一致。
func ServeStatic(w http.ResponseWriter, r *http.Request, docroot, path string) {
	// `/cgi-bin/*` 一律不外发。
	//
	// 上游 uhttpd 把 docroot 里的 `/cgi-bin/*` 当 CGI **执行**（`cgi_prefix`），从不把
	// 脚本正文当静态文件送出去；molly 只在 `--luci-cgi` 给的那条命令上执行 CGI
	// （且那条命令是绝对路径），所以这里必须**拒绝**而不是照发。
	//
	// 为什么现在要专门堵：换过前缀之后（专家版让到 `/admin`），`/cgi-bin/luci` 不再被
	// LuCI 路由接管，文档根里那个 CGI 兜底脚本就会退化成「可下载的纯文本」——Odin 版
	// 2026-10-07 真机验证时正是这么暴露的（改前缀前该路径被 serve_luci 吃掉了）。
	// 用 403 而不是 404：这是策略性拒绝，不是「文件不存在」。
	if path == "/cgi-bin" || strings.HasPrefix(path, "/cgi-bin/") {
		Respond(w, r, http.StatusForbidden, "forbidden\n", "text/plain; charset=utf-8")
		return
	}

	// uhttpd 对静态路径上的 POST 也回 405
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		Respond(w, r, http.StatusMethodNotAllowed, "method not allowed\n", "text/plain; charset=utf-8")
		return
	}

	full := docroot + path
	info, err := os.Stat(full)
	if err != nil {
		// 不存在、无权限、路径中间不是目录……统一回 404：
		// 403 会把「文件存在但不可读」这种信息暴露给客户端。
		// docroot 里没有时，再看二进制里有没有带（-tags embed_assets）。
		if serveEmbedded(w, r, path) {
			return
		}
		notFound(w, r, path)
		return
	}

	if info.IsDir() {
		// 目录 → index.html；没有 index.html 就 404
		full += IndexFile
		idx, idxErr := os.Stat(full)
		if idxErr != nil || !idx.Mode().IsRegular() {
			if serveEmbedded(w, r, path+IndexFile) {
				return
			}
			notFound(w, r, path)
			return
		}
	} else if !info.Mode().IsRegular() {
		// 管道 / 套接字 / 设备节点不当作静态文件送出去
		notFound(w, r, path)
		return
	}

	data, readErr := os.ReadFile(full)
	if readErr != nil {
		notFound(w, r, path)
		return
	}

	Respond(w, r, http.StatusOK, string(data), httpx.ContentTypeFor(full))
}

// serveEmbedded 用**编进二进制**的资源回复（`-tags embed_assets` 构建时才有；
// 默认构建恒 false）。只在 docroot 里找不到时兜底——设备上的资源永远优先，
// 因为那是与设备 ucode 同版本的。
func serveEmbedded(w http.ResponseWriter, r *http.Request, path string) bool {
	data, ok := webassets.ReadFile(path)
	if !ok {
		return false
	}
	Respond(w, r, http.StatusOK, string(data), httpx.ContentTypeFor(path))
	return true
}
