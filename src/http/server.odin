package http

// server —— 手写 HTTP/1.1 的收侧。core:net 监听 accept，每连接 spawn 一个协程；
// 在连接上按 keep-alive 循环解析「请求行 + 头 + 体」，组装成 Request 后交给 handler。
//
// 设计约束（对齐现 Go 行为与本项目需要）：
//   - 只支持 origin-form 目标（"/path?query"）与 HTTP/1.0/1.1；
//   - 请求体只认 Content-Length（cgi-io 上传、JSON-RPC 都带它）；chunked 明确拒绝 501；
//   - 显式限幅（limits.odin），超限回 414/431/413 并关连接；
//   - 每请求一个 arena（context.allocator 临时切过去），handler 里的分配随请求整体回收；
//   - 路径规范化与 400/403 判定属于路由语义，留给 handler（对齐 Go 的 router.ServeHTTP），
//     server 只把原始 target 放进 req.target。
//   - 无读写超时（与 Go http.Server{} 零超时一致）；写半路客户端断开由 send_all 静默处理，
//     SIGPIPE 在 main 里忽略。

import "core:net"
import "core:strings"
import "core:fmt"
import "core:mem"
import "core:thread"

// Handler —— 一个完整请求就绪后调用的分发函数。data 是注册时带的上下文（阶段4 的 router），
// 语义对齐 Go 的 http.Handler.ServeHTTP(w, r)：req 只读视图，res 写回通道。
Handler :: proc(data: rawptr, req: ^Request, res: ^Response)

// ACCEPT_BACKLOG —— listen 的积压队列，量级对齐 uhttpd/Go 默认。
ACCEPT_BACKLOG :: 1000

// Conn_Args —— 传给连接线程的一揽子参数（堆分配，entry 里 free）。
// 用 rawptr 版 create_and_start_with_data 而非 poly_data，避开其「值必须塞进 user_args」的尺寸约束。
Conn_Args :: struct {
	client:  net.TCP_Socket,
	source:  net.Endpoint,
	handler: Handler,
	data:    rawptr,
}

// conn_entry —— 连接线程入口：解包参数、跑 handle_conn，退出前释放堆上的 Conn_Args。
conn_entry :: proc(p: rawptr) {
	args := cast(^Conn_Args)p
	defer free(args)
	handle_conn(args.client, args.source, args.handler, args.data)
}

// Serve —— 绑定监听并进入 accept 循环（阻塞）。解析/绑定失败返回 false（由 main 记录并退出）；
// 成功则一直在循环里跑，正常不返回。每连接起一条 core:thread 线程跑 handle_conn。
Serve :: proc(listen: string, handler: Handler, data: rawptr) -> bool {
	ep, ok := parse_listen(listen)
	if !ok {
		return false
	}
	ln, err := net.listen_tcp(ep, ACCEPT_BACKLOG)
	if err != nil {
		return false
	}
	for {
		client, source, aerr := net.accept_tcp(ln)
		if aerr != net.Accept_Error.None {
			// 瞬时 accept 错误（EINTR/EMFILE 抖动）跳过；持续错误由上层择机关停。
			continue
		}
		// 每连接一条 OS 线程（dev-2026-10 去掉了 spawn 语句，改用 core:thread）。
		// self_cleanup=true：线程结束自动回收 Thread 资源，故忽略返回的 ^Thread、不 join。
		args := new(Conn_Args)
		args^ = Conn_Args{client, source, handler, data}
		thread.create_and_start_with_data(args, conn_entry, self_cleanup = true)
	}
	return true
}

// parse_listen —— 把 "HOST:PORT" 解析成监听 Endpoint。先按 IP 字面量，失败再走 DNS 解析。
parse_listen :: proc(s: string) -> (ep: net.Endpoint, ok: bool) {
	if e, good := net.parse_endpoint(s); good {
		return e, true
	}
	// 主机名（如 localhost:8080）：走解析器拿 IPv4。
	ep4, _, rerr := net.resolve(s)
	if rerr == nil {
		return ep4, true
	}
	return net.Endpoint{}, false
}

// handle_conn —— 单连接生命周期：跨 keep-alive 复用一个累积缓冲 recv_buf；
// 每个请求解析 + 派发 + 回收 arena。连接结束关 socket。
handle_conn :: proc(client: net.TCP_Socket, source: net.Endpoint, handler: Handler, data: rawptr) {
	conn_alloc := context.allocator // 连接级真实分配器（recv_buf 用它，跨 arena reset 存活）
	defer net.close(client)

	recv_buf: [dynamic]u8
	defer delete(recv_buf)

	da: mem.Dynamic_Arena
	mem.dynamic_arena_init(&da, conn_alloc, conn_alloc)
	da_alloc := mem.dynamic_arena_allocator(&da)

	remote := net.endpoint_to_string(source, conn_alloc)

	for {
		// ---- 1. 读到完整头（\r\n\r\n）----
		head_end := find_double_crlf(&recv_buf)
		for head_end < 0 {
			context.allocator = conn_alloc
			n := recv_into(client, &recv_buf)
			if n <= 0 {
				return // EOF 或对端错误：直接关
			}
			if len(recv_buf) > MAX_URI_BYTES + MAX_REQUEST_HEADERS_BYTES {
				reject(client, nil, 431) // Request Header Fields Too Large
				return
			}
			head_end = find_double_crlf(&recv_buf)
		}

		// ---- 2. 在本请求 arena 里解析头 ----
		// 注意：header 里的 name/value 是 recv_buf 字节切片的「视图」，零分配；
		// 只要 keep-alive 消费前部字节（步骤6）发生在派发之后即可。
		context.allocator = da_alloc
		req := Request{remote = remote}
		code := parse_head(&recv_buf, head_end, &req)
		if code != 0 {
			reject(client, &req, code)
			mem.dynamic_arena_reset(&da)
			context.allocator = conn_alloc
			return
		}

		// ---- 3. 需要读多少体：由 Content-Length 决定 ----
		cl := Content_Length(&req)
		if cl < 0 {
			// 无 CL：若是 chunked 明确拒绝，否则视作无请求体。
			if v, has := Header_Get(&req, "transfer-encoding"); has && strings.contains(strings.to_lower(v), "chunked") {
				reject(client, &req, 501) // Not Implemented（本服务不接 chunked 上传）
				mem.dynamic_arena_reset(&da)
				context.allocator = conn_alloc
				return
			}
			cl = 0
		}
		if cl > i64(MAX_BODY_BYTES) {
			reject(client, &req, 413) // Payload Too Large
			mem.dynamic_arena_reset(&da)
			context.allocator = conn_alloc
			return
		}

		total := head_end + 4 + int(cl) // 头 + 空行 + 体
		for len(recv_buf) < total {
			context.allocator = conn_alloc
			n := recv_into(client, &recv_buf)
			if n <= 0 {
				mem.dynamic_arena_reset(&da)
				return // 体没读全就断：静默关
			}
		}
		req.body = recv_buf[head_end+4 : total]

		// ---- 4. 组装派生视图：查询串 ----
		req.query = parse_query(req.target)

		// ---- 5. 派发 ----
		res := Response{sock = client, req = &req}
		handler(data, &req, &res)

		// ---- 6. 决定去留 & 清理本请求 ----
		keep := Keep_Alive(&req) && ! res.close_after
		mem.dynamic_arena_reset(&da)
		context.allocator = conn_alloc
		if len(recv_buf) >= total {
			// 消费掉本请求字节，保留管道里多读的下一请求：把尾部整体前移、再缩短 len。
			// 注：dev-2026-10 的 delete(arr[i:j]) 对 [dynamic] 会踩坏内部簿记（随后的
			// delete(arr) 触发 heap_free(野指针) abort），故禁用；改用 mem.copy+resize，
			// 保留原 allocator/cap，len 收到尾部长度。dst 低、src 高，naive copy 安全。
			tail := recv_buf[total:]
			mem.copy(mem.raw_data(recv_buf), mem.raw_data(tail), len(tail))
			resize(&recv_buf, len(tail))
		} else {
			return
		}
		if ! keep {
			return
		}
	}
}

// recv_into —— 从 socket 读一块追加进 buf。返回读到的字节数；0=对端正常关闭；-1=错误。
recv_into :: proc(client: net.TCP_Socket, buf: ^[dynamic]u8) -> int {
	chunk: [READ_CHUNK]u8
	n, err := net.recv_tcp(client, chunk[:])
	if err != net.TCP_Recv_Error.None {
		return -1
	}
	if n == 0 {
		return 0 // graceful close（EOF）
	}
	// [dynamic]u8 追加一段字符串（append 对 u8 动态数组有字符串重载），一次性并入。
	append(buf, string(chunk[0:n]))
	return n
}

// find_double_crlf —— 返回 "\r\n\r\n" 首个 CR 的下标；未找到 -1。
find_double_crlf :: proc(buf: ^[dynamic]u8) -> int {
	n := len(buf^)
	if n < 4 {
		return -1
	}
	i := 0
	for i+3 < n {
		if buf^[i] == '\r' && buf^[i+1] == '\n' && buf^[i+2] == '\r' && buf^[i+3] == '\n' {
			return i
		}
		i += 1
	}
	return -1
}

// find_crlf —— 在 [from, len) 里找 "\r\n" 首个 CR 下标；未找到 -1。
find_crlf :: proc(s: string, from: int) -> int {
	i := from
	for i+1 < len(s) {
		if s[i] == '\r' && s[i+1] == '\n' {
			return i
		}
		i += 1
	}
	return -1
}

// find_byte —— 在 [from, len) 里找字节 b 的下标；未找到 -1。
find_byte :: proc(s: string, b: u8, from: int) -> int {
	i := from
	for i < len(s) {
		if s[i] == b {
			return i
		}
		i += 1
	}
	return -1
}

// parse_head —— 解析 recv_buf[0:head_len]（请求行 + 头，不含结尾空行），填充 req。
// 返回 0 表示成功；否则是应回的状态码（400/405/414/431/505）。
// req.headers 是 [dynamic]Header，由调用方的 arena 分配，随请求整体回收（不单独 delete）。
parse_head :: proc(buf: ^[dynamic]u8, head_len: int, req: ^Request) -> int {
	head := string(buf^[0:head_len])

	// 请求行：METHOD SP TARGET SP HTTP/x.y
	eol := find_crlf(head, 0)
	if eol < 0 {
		return 400
	}
	line := head[0:eol]
	sp1 := find_byte(line, ' ', 0)
	if sp1 < 0 {
		return 400
	}
	sp2 := find_byte(line, ' ', sp1 + 1)
	if sp2 < 0 {
		return 400
	}
	req.method = line[0:sp1]
	req.target = line[sp1+1 : sp2]
	version := line[sp2+1:]

	if len(req.target) > MAX_URI_BYTES {
		return 414
	}
	if len(req.method) == 0 {
		return 400
	}
	// 版本：只认 HTTP/1.0 与 HTTP/1.1
	if version == "HTTP/1.1" {
		req.version = "1.1"
	} else if version == "HTTP/1.0" {
		req.version = "1.0"
	} else {
		return 505
	}

	// 头字段
	pos := eol + 2
	count := 0
	for pos < len(head) {
		e := find_crlf(head, pos)
		if e < 0 {
			e = len(head) // 末行无 CRLF（严格说不该出现，容错处理）
		}
		hline := head[pos:e]
		if len(hline) == 0 {
			pos = e + 2
			continue
		}
		colon := find_byte(hline, ':', 0)
		if colon < 0 {
			return 400 // 头缺冒号
		}
		name := hline[0:colon]
		value := strings.trim_space(hline[colon+1:])
		append(&req.headers, Header{name, value})
		count += 1
		if count > MAX_HEADER_COUNT {
			return 431
		}
		pos = e + 2
	}
	return 0
}

// reject —— 出错时的兜底应答：有 req 就用它判 keep-alive/close，没有就强制 close。
// 正文与 uhttpd 一致（text/plain，带结尾换行由调用方给；这里用简短定长文案）。
reject :: proc(client: net.TCP_Socket, req: ^Request, code: int) {
	r := req
	if r == nil {
		tmp := Request{version = "1.0"}
		r = &tmp
	}
	res := Response{sock = client, req = r}
	body := fmt.tprintf("%d %s\n", code, Status_Text(code))
	// 出错响应一律关连接：借 close_after 让 build_head 之外的 Keep_Alive 判定失效即可，
	// 这里直接 Emit（body 已定长，Content-Length 由 Emit 计算）。
	Emit(&res, code, []Header{Header{"Content-Type", "text/plain; charset=utf-8"}}, body)
}
