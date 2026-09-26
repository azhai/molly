package handlers

import "core:mem"
import "core:os"

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
		return not_found(conn, req)
	}

	if info.type == .Directory {
		// 目录 → index.html；没有 index.html 就 404（P2 不做目录列表，
		// 原厂 uhttpd 也只在其 dir_listing 打开时才有列表页）
		n += copy(buf[n:], INDEX_FILE)
		full = transmute(string)(buf[:n])
		idx, idx_err := os.stat(full, alloc)
		if idx_err != nil || idx.type != .Regular {
			return not_found(conn, req)
		}
	} else if info.type != .Regular {
		// 管道 / 套接字 / 设备节点不当作静态文件送出去
		return not_found(conn, req)
	}

	// ponytail: HEAD 也真读文件才拿得到长度；/www 下的文件都是 KB 级，
	//           等第 7 步真机压测显示 HEAD 有成本再改成直接回 File_Info.size。
	data, read_err := os.read_entire_file(full, alloc)
	if read_err != nil {
		return not_found(conn, req)
	}

	// data 指向每请求 arena，本次响应期间一直有效，所以这里只做零拷贝的类型转换。
	return http.respond(conn, .OK, transmute(string)(data), {
		content_type = http.content_type_for(full),
		keep_alive   = req.keep_alive,
		head_only    = req.method == .Head,
	})
}

@(private)
not_found :: proc(conn: ^http.Connection, req: ^http.Request) -> bool {
	return http.respond(conn, .Not_Found, "not found\n", {
		keep_alive = req.keep_alive,
	})
}