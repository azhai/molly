package http

import "core:mem"
import "core:net"

// 请求头解析。全部输出都指向 conn.inbox 或每请求 arena，不留任何堆分配：
// 连接循环里 Request 只声明一次并复用它，避免每请求的分配与回收。
//
// 生命周期约定：req 里的 string/slice 只在本次处理期间有效，
// 下一次 read_request 会移动 inbox 内容（见 Connection.consumed）。

Method :: enum {
	Get,
	Head,
	Post,
	Put,
	Delete,
	Options,
	Other,
}

Header :: struct {
	name:  string,
	value: string,
}

Request :: struct {
	method:  Method,
	target:  string,
	minor:   int, // HTTP/1.<minor>
	headers: [MAX_HEAD_COUNT]Header,
	n_heads: int,

	// body 在每请求 arena 里（可能到 MAX_BODY_BYTES），不放栈上
	body:       []byte,
	keep_alive: bool,
}

// 解析结果。非 Ok 的取值直接决定回哪个状态码，所以这里不用 bool。
Parse_Result :: enum {
	Ok,
	Closed,            // 对端正常关闭，没有请求可解析
	Bad_Request,       // 400
	Head_Too_Large,    // 413
	Length_Required,   // 411（chunked，或 POST/PUT 没有 Content-Length）
	Payload_Too_Large, // 413
}

read_request :: proc(conn: ^Connection, req: ^Request) -> Parse_Result {
	// 上一轮请求已经处理完，这时才真正丢弃已消费的字节。
	// 放在这里而不是上一轮结尾，是因为 handler 还持有指向 inbox 的 string。
	if conn.consumed > 0 {
		remove_range(&conn.inbox, 0, conn.consumed)
		conn.consumed = 0
	}

	req^ = {}
	req.keep_alive = true

	head_end := -1
	for {
		if e := find_head_end(conn.inbox[:]); e >= 0 {
			head_end = e
			break
		}
		// 还没读全。头已经超过上限就没必要继续读了。
		if len(conn.inbox) >= MAX_HEAD_BYTES {
			return .Head_Too_Large
		}
		n, err := read_more(conn)
		if err != nil {
			return .Bad_Request
		}
		if n == 0 {
			// 一个字节都没读到就断连。已经读了半截头的话属于坏请求。
			return len(conn.inbox) == 0 ? .Closed : .Bad_Request
		}
	}
	if head_end > MAX_HEAD_BYTES {
		return .Head_Too_Large
	}

	// head_end 含结尾的 CRLFCRLF，解析时去掉
	if res := parse_head(conn.inbox[:head_end - 4], req); res != .Ok {
		return res
	}

	// ---- keep-alive 判定：HTTP/1.1 默认保持，1.0 默认关闭 ----
	if close_, ok := header_value(req, "connection"); ok {
		if ascii_has_token(close_, "close") {
			req.keep_alive = false
		} else if ascii_has_token(close_, "keep-alive") {
			req.keep_alive = true
		}
	} else {
		req.keep_alive = req.minor >= 1
	}

	// ---- 请求体长度 ----
	body_len := 0
	if _, te := header_value(req, "transfer-encoding"); te {
		// uhttpd 不接受 chunked；它要求长度已知，所以回 411 而不是解 chunked。
		return .Length_Required
	}
	if cl, ok := header_value(req, "content-length"); ok {
		if !parse_decimal(cl, &body_len) {
			return .Bad_Request
		}
		if body_len > MAX_BODY_BYTES {
			return .Payload_Too_Large
		}
	} else if req.method == .Post || req.method == .Put {
		return .Length_Required
	}

	// ---- 请求体 ----
	// from_inbox 是「本来就在 inbox 里、属于这个 body 的那部分」。
	// conn.consumed 只能算上这部分：剩下的 body 是直接读进 arena 的，
	// 从来没进过 inbox；而超出 body_len 的字节属于下一个请求，不能丢。
	from_inbox := 0
	if body_len > 0 {
		// Expect: 100-continue 要求先回一个临时响应，客户端才会发 body
		if exp, ok := header_value(req, "expect"); ok && ascii_has_token(exp, "100-continue") {
			if !send_raw(conn.socket, "HTTP/1.1 100 Continue\r\n\r\n") {
				return .Bad_Request
			}
		}

		alloc := mem.dynamic_arena_allocator(&conn.arena)
		body := make([]byte, body_len, alloc)
		if body == nil {
			return .Payload_Too_Large
		}

		// inbox 里可能已经有 body 的一部分，也可能连下一个请求的开头都读进来了
		from_inbox = min(len(conn.inbox) - head_end, body_len)
		copy(body, conn.inbox[head_end:head_end + from_inbox])
		have := from_inbox
		for have < body_len {
			n, err := net.recv_tcp(conn.socket, body[have:])
			if err != nil || n == 0 {
				// 请求体没读完就断了：这不是完整请求，不能当成请求处理
				return .Bad_Request
			}
			have += n
		}
		req.body = body
	}

	// 只记账，不真的移动 inbox（handler 还要用那些 string）
	conn.consumed = head_end + from_inbox
	return .Ok
}

// ---------------------------------------------------------------------------
// 头部解析
// ---------------------------------------------------------------------------

@(private)
parse_head :: proc(head: []byte, req: ^Request) -> Parse_Result {
	line, rest := next_line(head)
	m, t, v, ok := split_request_line(line)
	if !ok {
		return .Bad_Request
	}
	req.method = method_from_string(string(m))
	if len(t) == 0 || t[0] != '/' {
		// 只接受 origin-form。/ubus 与 /cgi-bin/luci 都走这条路径。
		return .Bad_Request
	}
	req.target = string(t)

	minor, v_ok := parse_http_version(string(v))
	if !v_ok {
		return .Bad_Request
	}
	req.minor = minor

	for len(rest) > 0 {
		l: []byte
		l, rest = next_line(rest)
		if len(l) == 0 {
			continue // 容错：多余的空行
		}
		colon := -1
		for i := 0; i < len(l); i += 1 {
			if l[i] == ':' {
				colon = i
				break
			}
		}
		// name 不能为空；值可以为空（如 X-Foo:）
		if colon <= 0 {
			return .Bad_Request
		}
		if req.n_heads >= MAX_HEAD_COUNT {
			return .Head_Too_Large
		}
		req.headers[req.n_heads] = {
			name  = string(trim_ows(l[:colon])),
			value = string(trim_ows(l[colon + 1:])),
		}
		req.n_heads += 1
	}
	return .Ok
}

header_value :: proc(req: ^Request, name: string) -> (string, bool) {
	for i := 0; i < req.n_heads; i += 1 {
		if ascii_equal_fold(req.headers[i].name, name) {
			return req.headers[i].value, true
		}
	}
	return "", false
}

// 在 head（已剥掉结尾 CRLFCRLF）范围内找 "\r\n\r\n"，返回其结束偏移。
@(private)
find_head_end :: proc(b: []byte) -> int {
	for i := 0; i + 4 <= len(b); i += 1 {
		if b[i] == '\r' && b[i + 1] == '\n' && b[i + 2] == '\r' && b[i + 3] == '\n' {
			return i + 4
		}
	}
	return -1
}

// 切出下一行。没有 CRLF 表示这是最后一行（head 里不含结尾的 CRLFCRLF）。
@(private)
next_line :: proc(b: []byte) -> (line, rest: []byte) {
	for i := 0; i + 1 < len(b); i += 1 {
		if b[i] == '\r' && b[i + 1] == '\n' {
			return b[:i], b[i + 2:]
		}
	}
	return b, nil
}

@(private)
split_request_line :: proc(line: []byte) -> (m, t, v: []byte, ok: bool) {
	i := 0
	for i < len(line) && line[i] != ' ' {
		i += 1
	}
	if i == 0 || i >= len(line) {
		return
	}
	m = line[:i]

	j := i + 1
	for j < len(line) && line[j] != ' ' {
		j += 1
	}
	if j == i + 1 || j >= len(line) {
		return
	}
	t = line[i + 1:j]

	k := j + 1
	for k < len(line) && line[k] != ' ' {
		k += 1
	}
	if k != len(line) || k == j + 1 {
		return
	}
	v = line[j + 1:]
	return m, t, v, true
}

@(private)
parse_http_version :: proc(v: string) -> (minor: int, ok: bool) {
	if len(v) != 8 || v[:7] != "HTTP/1." {
		return 0, false
	}
	switch v[7] {
	case '0':
		return 0, true
	case '1':
		return 1, true
	}
	return 0, false
}

@(private)
method_from_string :: proc(s: string) -> Method {
	switch s {
	case "GET":
		return .Get
	case "HEAD":
		return .Head
	case "POST":
		return .Post
	case "PUT":
		return .Put
	case "DELETE":
		return .Delete
	case "OPTIONS":
		return .Options
	}
	return .Other
}

// Content-Length 必须全是十进制数字。取值超过 MAX_BODY_BYTES 时照常返回 true，
// 由调用方判 413——这样"太大"和"格式错"两种情况能区分开。
@(private)
parse_decimal :: proc(s: string, out: ^int) -> bool {
	if len(s) == 0 {
		return false
	}
	n := 0
	for i := 0; i < len(s); i += 1 {
		ch := s[i]
		if ch < '0' || ch > '9' {
			return false
		}
		n = n * 10 + int(ch - '0')
		if n > MAX_BODY_BYTES {
			break
		}
	}
	out^ = n
	return true
}

@(private)
trim_ows :: proc(b: []byte) -> []byte {
	i := 0
	for i < len(b) && (b[i] == ' ' || b[i] == '\t') {
		i += 1
	}
	j := len(b)
	for j > i && (b[j - 1] == ' ' || b[j - 1] == '\t') {
		j -= 1
	}
	return b[i:j]
}

// ---------------------------------------------------------------------------
// 不区分大小写的 ASCII 比较 / 逗号分隔 token 查找
// ---------------------------------------------------------------------------

@(private)
lower :: proc(c: u8) -> u8 {
	return c >= 'A' && c <= 'Z' ? c + 32 : c
}

@(private)
ascii_equal_fold :: proc(a, b: string) -> bool {
	if len(a) != len(b) {
		return false
	}
	for i := 0; i < len(a); i += 1 {
		if lower(a[i]) != lower(b[i]) {
			return false
		}
	}
	return true
}

// 在逗号分隔的列表里找 token，忽略大小写与前后空白。
// 用于 Connection 和 Expect 这类可能出现多个取值的头。
@(private)
ascii_has_token :: proc(list: string, token: string) -> bool {
	rest := list
	for len(rest) > 0 {
		i := 0
		for i < len(rest) && rest[i] != ',' {
			i += 1
		}
		item := trim_ows(transmute([]byte)rest[:i])
		if ascii_equal_fold(string(item), token) {
			return true
		}
		if i >= len(rest) {
			break
		}
		rest = rest[i + 1:]
	}
	return false
}

// ---------------------------------------------------------------------------
// 入站缓冲
// ---------------------------------------------------------------------------

// 把 socket 上可读的字节追加到 inbox。返回本次读到的字节数，0 表示对端关闭。
@(private)
read_more :: proc(conn: ^Connection) -> (n: int, err: net.TCP_Recv_Error) {
	old := len(conn.inbox)
	if resize(&conn.inbox, old + READ_BUF_SIZE) != nil {
		return 0, .Insufficient_Resources
	}
	n, err = net.recv_tcp(conn.socket, conn.inbox[old:])
	if err != nil || n == 0 {
		// 回退到原长度，避免把垃圾字节当成已收到
		resize(&conn.inbox, old)
		return
	}
	resize(&conn.inbox, old + n)
	return
}