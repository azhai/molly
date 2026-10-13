package handlers

// static —— /www 静态文件服务（对齐 internal/handlers/static.go，即上游 uhttpd 的静态部分）。
//
// 与 ubus_http 同构：把「决策」（该回哪个状态码/正文/Content-Type）抽成纯函数 resolve_static，
// 只依赖 docroot 上的真文件系统，能在 host 单测；Serve_Static 只做 http.Respond 的 I/O 粘合。
//
// 调用约定：path 是 http.Normalize_Path 的产物（已剥查询串、百分号解码、无 .. 段），
// docroot 由 main 启动时去掉尾部 '/'。不缓存文件内容（每次真读盘，与 Odin/Go 版一致）。
// 符号链接照常跟随（stat 而非 lstat）——与原厂 uhttpd 一致。
//
// 与 Go 版的差异：Go 的 serveEmbedded（-tags embed_assets 时从二进制取资源）在这里留待阶段5
// 的资源内嵌接线；当前只走 docroot。docroot 找不到就 404（Go 里也是内嵌恒 false 时的行为）。

import "core:strings"
import "core:fmt"
import "core:os"
import "molly:http"

// 目录回落时追加的文件名。
index_file :: "/index.html"

// static_outcome 是一次静态解析的结论。not_found 置位表示应走 http.Not_Found（正文含 HTML 转义
// 的回显路径，与其它码的固定正文不同源，故单独标出而非塞进 body）。
static_outcome :: struct {
	code:      int,
	body:      string,
	ct:        string,
	not_found: bool,
}

// Serve_Static —— 解析 + 发出。
Serve_Static :: proc(res: ^http.Response, req: ^http.Request, docroot, path: string) {
	oc := resolve_static(docroot, req.method, path)
	if oc.not_found {
		http.Not_Found(res, path)
		return
	}
	http.Respond(res, oc.code, oc.body, oc.ct)
}

// resolve_static —— 纯决策（host 可测，真读 docroot）。
resolve_static :: proc(docroot, method, path: string) -> static_outcome {
	// `/cgi-bin/*` 一律不外发：上游把 docroot 里的 cgi-bin 当脚本**执行**，从不送正文；
	// molly 只在 --luci-cgi 那条命令上执行 CGI，这里必须拒绝（策略性 → 403 而非 404）。
	if path == "/cgi-bin" || strings.has_prefix(path, "/cgi-bin/") {
		return static_outcome{code = 403, body = "forbidden\n", ct = "text/plain; charset=utf-8"}
	}

	// uhttpd 对静态路径上的非 GET/HEAD 回 405。
	if method != "GET" && method != "HEAD" {
		return static_outcome{code = 405, body = "method not allowed\n", ct = "text/plain; charset=utf-8"}
	}

	full := fmt.tprintf("%s%s", docroot, path)
	info, serr := os.stat(full, context.allocator)
	if serr != nil {
		// 不存在 / 无权限 / 中间不是目录……统一 404（403 会把「存在但不可读」泄露给客户端）。
		return static_outcome{not_found = true}
	}

	if info.type == .Directory {
		// 目录 → index.html；没有（或不是常规文件）就 404。
		full = fmt.tprintf("%s%s", full, index_file)
		idx, ierr := os.stat(full, context.allocator)
		if ierr != nil || idx.type != .Regular {
			return static_outcome{not_found = true}
		}
	} else if info.type != .Regular {
		// 管道 / 套接字 / 设备节点不当作静态文件送出去。
		return static_outcome{not_found = true}
	}

	data, rerr := os.read_entire_file(full, context.allocator)
	if rerr != nil {
		return static_outcome{not_found = true}
	}
	return static_outcome{code = 200, body = string(data), ct = http.Content_Type_For(full)}
}
