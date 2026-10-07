package handlers

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"

import "molly:http"

// 目录回落时追加的文件名。预留它的长度，命中目录时就能就地拼接、不再分配。
INDEX_FILE :: "/index.html"

// 静态文件服务，对应上游 uhttpd 提供 /www 的那部分。
//
// 调用约定：path 必须是 http.normalize_path 的产物（已剥查询串、已百分号解码、
// 无 .. 段）；docroot 由 main 在启动时去掉尾部 '/'，且非空时不以 '/' 结尾。
//
// P2 不缓存文件内容，每次请求都真读盘。理由是目标为「空载 <2MB RSS」，缓存策略
// 要等第 7 步真机压测有数据再定；这一步只保证语义正确。
//
// 符号链接照常跟随（os.stat 而非 lstat）：与原厂 uhttpd 一致，且 /www/luci-static
// 下本来就可能存在链接。若固件把 /www 指向别处，那是固件自身的配置选择。
serve_static :: proc(s: ^http.Server, conn: ^http.Connection, req: ^http.Request, path: string) -> bool {
	// `/cgi-bin/*` 一律不外发。
	//
	// 上游 uhttpd 把 docroot 里的 `/cgi-bin/*` 当 CGI **执行**（`cgi_prefix`），从不把
	// 脚本正文当静态文件送出去；molly 只在 `--luci-cgi` 给的那条命令上执行 CGI
	// （handlers/cgi_exec.odin，且那条命令是绝对路径），所以这里必须**拒绝**而不是照发。
	//
	// 为什么现在要专门堵：换过前缀之后（专家版让到 `/pro`），`/cgi-bin/luci` 不再被
	// LuCI 路由接管，文档根里那个 CGI 兜底脚本就会退化成「可下载的纯文本」——2026-10-07
	// 真机验证时正是这么暴露的（改前缀前该路径被 serve_luci 吃掉了，看不到这个面）。
	// 用 403 而不是 404：这是策略性拒绝，不是「文件不存在」。
	if path == "/cgi-bin" || strings.has_prefix(path, "/cgi-bin/") {
		return http.respond(conn, .Forbidden, "forbidden\n", {
			keep_alive = req.keep_alive,
		})
	}

	// uhttpd 对静态路径上的 POST 也回 405（逐条对齐待真机 golden，R7）
	if req.method != .Get && req.method != .Head {
		return http.respond(conn, .Method_Not_Allowed, "method not allowed\n", {
			keep_alive = req.keep_alive,
		})
	}

	alloc := mem.dynamic_arena_allocator(&conn.arena)
	buf := make([]byte, len(s.docroot) + len(path) + len(INDEX_FILE), alloc)
	if buf == nil {
		return http.respond(conn, .Internal_Server_Error, "out of memory\n", {
			keep_alive = req.keep_alive,
		})
	}
	n := copy(buf, s.docroot)
	n += copy(buf[n:], path)
	full := transmute(string)(buf[:n])

	info, err := os.stat(full, alloc)
	if err != nil {
		// 不存在、无权限、路径中间不是目录……统一回 404：
		// 403 会把「文件存在但不可读」这种信息暴露给客户端。
		return not_found(conn, req, path)
	}

	if info.type == .Directory {
		// 目录 → index.html；没有 index.html 就 404（P2 不做目录列表，
		// 原厂 uhttpd 也只在其 dir_listing 打开时才有列表页）
		n += copy(buf[n:], INDEX_FILE)
		full = transmute(string)(buf[:n])
		idx, idx_err := os.stat(full, alloc)
		if idx_err != nil || idx.type != .Regular {
			return not_found(conn, req, path)
		}
	} else if info.type != .Regular {
		// 管道 / 套接字 / 设备节点不当作静态文件送出去
		return not_found(conn, req, path)
	}

	// ponytail: HEAD 也真读文件才拿得到长度；/www 下的文件都是 KB 级，
	//           等第 7 步真机压测显示 HEAD 有成本再改成直接回 File_Info.size。
	data, read_err := os.read_entire_file(full, alloc)
	if read_err != nil {
		return not_found(conn, req, path)
	}

	// data 指向每请求 arena，本次响应期间一直有效，所以这里只做零拷贝的类型转换。
	return http.respond(conn, .OK, transmute(string)(data), {
		content_type = http.content_type_for(full),
		keep_alive   = req.keep_alive,
		head_only    = req.method == .Head,
	})
}

// 404 响应。**逐条对齐原厂 uhttpd**（2026-10-07 真机实测）：
//   - `Content-Type: text/html`（不是 text/plain）；
//   - 正文形如 `<h1>Not Found</h1>The requested URL <路径> was not found on this server.`
//     （uhttpd 无结尾换行）。
// **已知偏离（故意）**：uhttpd 把请求路径**原样回显**，molly 做 HTML 转义——把未经转义的
// 请求数据拼进 HTML 是 XSS 面，不照抄。正文不参与 golden 对比（golden 只比状态码与头）。
@(private)
not_found :: proc(conn: ^http.Connection, req: ^http.Request, path: string) -> bool {
	alloc := mem.dynamic_arena_allocator(&conn.arena)
	body := fmt.aprintf(
		"<h1>Not Found</h1>The requested URL %s was not found on this server.",
		escape_html(path, alloc),
		allocator = alloc,
	)
	return http.respond(conn, .Not_Found, body, {
		content_type = "text/html",
		keep_alive   = req.keep_alive,
	})
}

// 与 src/luci/render.odin 的 html_escape 同一套转义（那个是 @(private) 且属 luci 包，
// 这里只要 5 行，不跨包重构）。
@(private)
escape_html :: proc(s: string, alloc: mem.Allocator) -> string {
	if !strings.contains_any(s, "&<>\"'") {
		return s // 绝大多数路径都不含特殊字符：零拷贝直接返回
	}
	b := strings.builder_make(alloc)
	for r in s {
		switch r {
		case '&':
			strings.write_string(&b, "&amp;")
		case '<':
			strings.write_string(&b, "&lt;")
		case '>':
			strings.write_string(&b, "&gt;")
		case '"':
			strings.write_string(&b, "&quot;")
		case '\'':
			strings.write_string(&b, "&#39;")
		case:
			strings.write_rune(&b, r)
		}
	}
	return strings.to_string(b)
}