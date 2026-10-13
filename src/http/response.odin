package http

// Response —— 手写 HTTP/1.1 的写侧。逐条对齐 internal/handlers/response.go 与 Odin 版
// src/http/response.odin 的语义：
//   - Content-Length 与 Content-Type 恒由本层决定；
//   - 从不发 Date / Server 头（原厂 Odin 版**故意**不发）；
//   - HEAD 回完整头但不回 body；
//   - CGI 的额外响应头**原样透传**头名（不做 MIME 规范化）。
//
// 两种用法：
//   缓冲式（绝大多数 handler / CGI / 静态）：Respond / Emit 一次写「状态行+头+体」。
//   流式（仅 SSE 订阅）：Write_Head 先发头，再 Write_Chunk 反复刷。

import "core:net"
import "core:strings"
import "core:fmt"

Response :: struct {
	sock:        net.TCP_Socket,
	req:         ^Request,
	wrote_head:  bool, // 流式已发头 → server 不再补发
	close_after: bool, // 流式（无 Content-Length 的分帧）→ server 处理完本请求即关连接，不 keep-alive
}

Status_Text :: proc(code: int) -> string {
	switch code {
	case 200: return "OK"
	case 201: return "Created"
	case 204: return "No Content"
	case 301: return "Moved Permanently"
	case 302: return "Found"
	case 303: return "See Other"
	case 304: return "Not Modified"
	case 307: return "Temporary Redirect"
	case 400: return "Bad Request"
	case 401: return "Unauthorized"
	case 403: return "Forbidden"
	case 404: return "Not Found"
	case 405: return "Method Not Allowed"
	case 408: return "Request Timeout"
	case 409: return "Conflict"
	case 411: return "Length Required"
	case 413: return "Payload Too Large"
	case 415: return "Unsupported Media Type"
	case 431: return "Request Header Fields Too Large"
	case 500: return "Internal Server Error"
	case 501: return "Not Implemented"
	case 502: return "Bad Gateway"
	case 503: return "Service Unavailable"
	}
	return "Unknown"
}

// 把一段字符串按字节追加进缓冲（Odin 的 append 对 [dynamic]u8 有字符串重载，
// 直接一次性并入 s 的字节；注意 `for c in s` 会把 c 当 rune/int，不能逐个 append）。
put_str :: proc(b: ^[dynamic]u8, s: string) {
	append(b, s)
}

// send_all 把整段字节写完（处理短写与断开）。返回 true=全部写出；false=中途出错/对端断开。
// SSE 循环要用这个返回值判客户端是否已走（Go 用 WriteString 的 err 同义）。
send_all :: proc(sock: net.TCP_Socket, data: []u8) -> bool {
	off := 0
	for off < len(data) {
		n, err := net.send_tcp(sock, data[off:])
		if err != net.TCP_Send_Error.None || n <= 0 {
			return false // 客户端断开：静默结束但回报失败（SIGPIPE 已在 main 里忽略）
		}
		off += n
	}
	return true
}

// 组状态行 + 头（给定头 + 可选 Content-Length + 可选 Connection: close + 空行）。
build_head :: proc(res: ^Response, code: int, headers: []Header, content_length: int, out: ^[dynamic]u8) {
	r := res.req
	put_str(out, fmt.tprintf("HTTP/1.1 %d %s\r\n", code, Status_Text(code)))
	for h in headers {
		put_str(out, fmt.tprintf("%s: %s\r\n", h.name, h.value))
	}
	if content_length >= 0 {
		put_str(out, fmt.tprintf("Content-Length: %d\r\n", content_length))
	}
	// 非 keep-alive 时显式标 close（keep-alive 是 HTTP/1.1 默认，无需头）。
	if r != nil && ! Keep_Alive(r) {
		put_str(out, "Connection: close\r\n")
	}
	put_str(out, "\r\n")
}

// Emit —— 缓冲式响应：状态行 + headers + 重算的 Content-Length + body，一次发出。
// HEAD 不发 body。headers 里若已含 Content-Length 会被本层覆盖（去重）。
Emit :: proc(res: ^Response, code: int, headers: []Header, body: string) {
	filtered: [dynamic]Header
	defer delete(filtered)
	for h in headers {
		if strings.to_lower(h.name) == "content-length" {
			continue
		}
		append(&filtered, h)
	}

	b: [dynamic]u8
	defer delete(b)
	build_head(res, code, filtered[:], len(body), &b)
	if res.req == nil || res.req.method != "HEAD" {
		put_str(&b, body)
	}
	send_all(res.sock, b[:])
	res.wrote_head = true
}

// Respond —— 只有 Content-Type 的普通响应。
Respond :: proc(res: ^Response, code: int, body, content_type: string) {
	hdrs := []Header{Header{"Content-Type", content_type}}
	Emit(res, code, hdrs, body)
}

// Not_Found —— 404，逐条对齐 uhttpd：text/html，正文无结尾换行；路径做 HTML 转义（防 XSS）。
Not_Found :: proc(res: ^Response, path: string) {
	body := fmt.tprintf("<h1>Not Found</h1>The requested URL %s was not found on this server.", html_escape(path))
	Respond(res, 404, body, "text/html")
}

// ---- 流式（SSE）----

// Write_Head —— 发状态行 + 给定头；不写 Content-Length（用 connection-close 分帧）。
// 流式响应没有显式长度 → 标 close_after，server 在本请求后关连接。
Write_Head :: proc(res: ^Response, code: int, headers: []Header) {
	b: [dynamic]u8
	defer delete(b)
	build_head(res, code, headers, -1, &b)
	send_all(res.sock, b[:])
	res.wrote_head = true
	res.close_after = true
}

// Write_Chunk —— 直接刷一段字节（SSE 帧）。
Write_Chunk :: proc(res: ^Response, data: []u8) {
	send_all(res.sock, data)
}

// Write_Chunk_Ok —— 同 Write_Chunk，但回报是否全部写出（false=对端已断，SSE 循环据此收尾）。
Write_Chunk_Ok :: proc(res: ^Response, data: []u8) -> bool {
	return send_all(res.sock, data)
}

// Peer_Closed —— 非阻塞探测客户端是否已关连接（SSE 空闲期的断开检测，对齐 Go 的 context.Done）。
// 只在 peek 前后瞬时把套接字切成非阻塞（写仍走阻塞，避免把「发送缓冲满」误判成断开）：
//   · recv 回 (0, None) → 对端优雅关闭；
//   · Would_Block / Interrupted → 暂无数据，未断；
//   · 其它错误（Connection_Closed 等）→ 已断。
Peer_Closed :: proc(res: ^Response) -> bool {
	_ = net.set_blocking(res.sock, false)
	b: [1]u8
	n, err := net.recv_tcp(res.sock, b[:])
	_ = net.set_blocking(res.sock, true)
	if err == net.TCP_Recv_Error.None {
		return n == 0
	}
	if err == net.TCP_Recv_Error.Would_Block || err == net.TCP_Recv_Error.Interrupted {
		return false
	}
	return true
}

html_escape :: proc(s: string) -> string {
	b: [dynamic]u8
	defer delete(b)
	for i := 0; i < len(s); i += 1 {
		switch s[i] {
		case '<': put_str(&b, "&lt;")
		case '>': put_str(&b, "&gt;")
		case '&': put_str(&b, "&amp;")
		case '"': put_str(&b, "&quot;")
		case '\'': put_str(&b, "&#39;")
		case:
			append(&b, s[i])
		}
	}
	out: []u8 = make([]u8, len(b))
	copy(out, b[:])
	return string(out)
}
