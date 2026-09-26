package http

import "core:fmt"
import "core:mem"
import "core:net"
import "core:strings"

// 只列出 P2 真正会回的状态码。取值与 uhttpd 的对齐关系待真机 golden 校准（R7）。
// 注意 413：uhttpd 对「请求头超限」和「请求体超限」都回 413，所以这里不额外定义 431。
Status :: enum u16 {
	OK                    = 200,
	Bad_Request           = 400,
	Forbidden             = 403,
	Not_Found             = 404,
	Method_Not_Allowed    = 405,
	Length_Required       = 411,
	Payload_Too_Large     = 413,
	Internal_Server_Error = 500,
	Not_Implemented       = 501,
	Service_Unavailable   = 503,
}

reason :: proc(s: Status) -> string {
	switch s {
	case .OK:
		return "OK"
	case .Bad_Request:
		return "Bad Request"
	case .Forbidden:
		return "Forbidden"
	case .Not_Found:
		return "Not Found"
	case .Method_Not_Allowed:
		return "Method Not Allowed"
	case .Length_Required:
		return "Length Required"
	case .Payload_Too_Large:
		return "Payload Too Large"
	case .Internal_Server_Error:
		return "Internal Server Error"
	case .Not_Implemented:
		return "Not Implemented"
	case .Service_Unavailable:
		return "Service Unavailable"
	}
	return "Unknown"
}

Respond_Opts :: struct {
	content_type: string,
	keep_alive:   bool,
	// HEAD 请求要回完整头（含真实 Content-Length）但不回 body
	head_only:    bool,
}

// 把一段字节写到连接上。core:net 的 send_tcp 内部会循环到写满，
// 且在 linux/darwin 上都传了 MSG_NOSIGNAL，所以这里不需要再管 SIGPIPE。
send_raw :: proc(sock: net.TCP_Socket, data: string) -> bool {
	if len(data) == 0 {
		return true
	}
	_, err := net.send_tcp(sock, transmute([]byte)data)
	return err == nil
}

// 回一个响应。响应头在栈上格式化，不做堆分配。
//
// 故意不发 Date / Server 头：它们是否出现在原厂响应里、格式如何，
// 要等真机抓样本后再定（R7）。curl 与浏览器都不依赖它们。
// 透传的响应头（CGI 桥接用：Set-Cookie / Location / Cache-Control 等我们自己的
// 代码不产生、但脚本会产生的头）。值里不得含 CRLF（解析时已按行切分）。
Extra_Header :: struct {
	name:  string,
	value: string,
}

// 通用出口：状态码与原因短语由调用方给（CGI 会返回 3xx/401 这类 Status 枚举里
// 没有的码，透传比枚举更保真），额外响应头原样带出。
//
// Content-Length 与 Connection 恒由 molly 决定：CGI 脚本给的同名头会被忽略，
// 避免长度与真实 body 不一致把 keep-alive 搞坏。
respond_full :: proc(
	conn: ^Connection,
	code: int,
	reason_phrase: string,
	extra: []Extra_Header,
	body: string,
	keep_alive: bool,
	head_only: bool,
	alloc: mem.Allocator,
) -> bool {
	b := strings.builder_make(alloc)
	fmt.sbprintf(&b, "HTTP/1.1 %d %s\r\n", code, reason_phrase)
	for h in extra {
		fmt.sbprintf(&b, "%s: %s\r\n", h.name, h.value)
	}
	fmt.sbprintf(
		&b,
		"Content-Length: %d\r\nConnection: %s\r\n\r\n",
		len(body),
		keep_alive ? "keep-alive" : "close",
	)
	if !send_raw(conn.socket, strings.to_string(b)) {
		return false
	}
	if head_only {
		return true
	}
	return send_raw(conn.socket, body)
}

respond :: proc(conn: ^Connection, status: Status, body: string, opts := Respond_Opts{content_type = "text/plain; charset=utf-8"}) -> bool {
	conn_resp: [320]byte
	head := fmt.bprintf(
		conn_resp[:],
		"HTTP/1.1 %d %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nConnection: %s\r\n\r\n",
		u16(status),
		reason(status),
		opts.content_type,
		len(body),
		opts.keep_alive ? "keep-alive" : "close",
	)
	if !send_raw(conn.socket, head) {
		return false
	}
	if opts.head_only {
		return true
	}
	return send_raw(conn.socket, body)
}