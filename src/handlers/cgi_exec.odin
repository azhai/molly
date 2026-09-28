package handlers

import "core:c"
import "core:fmt"
import "core:mem"
import "core:net"
import "core:strings"
import "core:sys/posix"
import "core:thread"

import "molly:backend"
import "molly:http"

// ---------------------------------------------------------------------------
// /cgi-bin/luci → 子进程的桥接（P3-8″-T1，ADR `.ai-agents/adr/0003-keep-ucode-faithful-luci2.md`）
//
// 上游 uhttpd 有两种形态，**只有第二种能从子进程跑**：
//   1) 进程内 ucode **模板**（uhttpd 的默认形态）：
//        uci add_list uhttpd.main.ucode_prefix='/cgi-bin/luci=/usr/share/ucode/luci/uhttpd.uc'
//        （luci-base/Makefile:47-48）。那个文件首行是 `{%`（ucode 的模板块），定义
//        `global.handle_request(env)`、收发走 uhttpd 注入的 `uhttpd.recv` / `uhttpd.send`——
//        必须在 uhttpd 进程里按模板编译；单独 execve 它必然语法错
//        （`Expecting expression` / `Imports may only appear at top level`）。
//   2) **CGI 兜底**：`/www/cgi-bin/luci`，LuCI 装的 `#!/usr/bin/env ucode` 脚本
//        （等价内容：`dispatch(request(getenv(), read, write))`）。
// `--luci-cgi` 要填的是 **2**（见 `main.odin` 的 USAGE 与 `docs/interfaces.md` §5.5）。
// T1 先按 CGI 做：构造环境 → fork/execve → 把子进程 stdout 当成响应回给客户端；
// T2（绑定 libucode 内嵌）等 T1 在设备上验收后再评估。
//
// 约束与取舍：
//   - fork 与 execve 之间**只做 async-signal-safe 调用**（dup2 / close / execve / _exit）：
//     进程里还有多个连接线程，任何分配都可能踩到别的线程持有的锁。argv / envp 全部在
//     fork 之前构造好。
//   - 命令来自 `--luci-cgi`（管理员配置），按空白切分，**不经过 /bin/sh**。
//   - 请求体由一个短命线程写进子进程 stdin：子进程可能先回响应再读 body，同步写会在
//     管道缓冲（macOS 16KB / Linux 64KB）上死锁。
//   - 子进程 stderr 继承 molly 的 stderr，ucode 的报错要能在日志里看到。
//   - ponytail: 不做 close(3..) 扫尾，子进程会短暂继承监听/连接 fd。CGI 子进程是短命的，
//     且把 1024 次 close 放在每次请求的热路径上更亏；将来做 T2（内嵌）后这个问题自然消失。
// ---------------------------------------------------------------------------

// CGI 规范里由环境变量表达、不能从请求头透传的头
@(private)
CGI_SPECIAL_HEADERS :: []string{"content-type", "content-length", "transfer-encoding", "connection"}

// ---------------------------------------------------------------------------
// 环境构造与响应解析：两个纯函数，单元测试直接钉（tests 见 src/handlers/cgi_test.odin）
// ---------------------------------------------------------------------------

// 构造一份 CGI 环境（每个元素是 "K=V"）。
//   path    —— 已规范化的完整路径，如 /cgi-bin/luci/admin/status/overview
//   docroot —— --docroot 的值，供脚本拼绝对路径
// 取值全部来自已解析的请求；header 值里若含 NUL，会在这里被 cstring 截断（不会越界）。
build_cgi_env :: proc(
	req: ^http.Request,
	path, peer_host, docroot: string,
	alloc: mem.Allocator,
) -> (env: [dynamic]string, ok: bool) {
	env = make([dynamic]string, 0, 16, alloc)

	query := ""
	if i := strings.index_byte(req.target, '?'); i >= 0 {
		query = req.target[i + 1:]
	}
	path_info := ""
	if len(path) > len(LUCI_PREFIX) {
		path_info = path[len(LUCI_PREFIX):]
	}

	append(&env, "GATEWAY_INTERFACE=CGI/1.1")
	append(&env, "SERVER_SOFTWARE=molly")
	append(&env, fmt.aprintf("SERVER_PROTOCOL=HTTP/1.%d", req.minor, allocator = alloc))
	append(&env, fmt.aprintf("REQUEST_METHOD=%s", method_str(req.method), allocator = alloc))
	append(&env, fmt.aprintf("REQUEST_URI=%s", req.target, allocator = alloc))
	append(&env, fmt.aprintf("SCRIPT_NAME=%s", LUCI_PREFIX, allocator = alloc))
	append(&env, fmt.aprintf("PATH_INFO=%s", path_info, allocator = alloc))
	append(&env, fmt.aprintf("QUERY_STRING=%s", query, allocator = alloc))
	append(&env, fmt.aprintf("DOCUMENT_ROOT=%s", docroot, allocator = alloc))
	append(&env, fmt.aprintf("REMOTE_ADDR=%s", peer_host, allocator = alloc))
	// CONTENT_LENGTH 恒给（GET 时是 0）：上游 uhttpd 也总是设置它，脚本会直接 +
	append(&env, fmt.aprintf("CONTENT_LENGTH=%d", len(req.body), allocator = alloc))
	if ct, has := http.header_value(req, "content-type"); has {
		append(&env, fmt.aprintf("CONTENT_TYPE=%s", ct, allocator = alloc))
	}

	for i := 0; i < req.n_heads; i += 1 {
		h := req.headers[i]
		if is_cgi_special_header(h.name) {
			continue
		}
		name := header_env_name(h.name, alloc)
		append(&env, fmt.aprintf("HTTP_%s=%s", name, h.value, allocator = alloc))
	}

	// 私有总线模式（--ubus-socket）下，CGI 子进程（ucode LuCI）必须连到 molly 那条
	// 总线，否则它看不到 molly 的 session。子进程里的 libubus **没有** socket 环境变量
	// （已核 libubus-io.c：`ubus_connect` 只认显式路径或编译期默认），所以靠设备上
	// LuCI 的 dispatcher.uc 读这个变量（一行补丁，替换原本的 `let ubus = connect();`；
	// 备份在同目录 dispatcher.uc.orig，见 linux.odin 的 g_ubus_socket_c 说明）。
	//
	// 该补丁同时把 LuCI 的 ubus 做成**双总线**代理：先在自己总线上找对象，找不到回退
	// 系统总线——否则 CGI 连了私有总线就看不到 netifd/network.* 等系统对象，页面会 500。
	if sock := backend.ubus_socket_path(); len(sock) > 0 {
		append(&env, fmt.aprintf("MOLLY_UBUS_SOCKET=%s", sock, allocator = alloc))
	}
	return env, true
}

// 解析 CGI 响应：头块（可含 `Status: <code> <reason>`）+ 空行 + body。
// 规范要求 CRLFCRLF 分隔，这里同时容忍 LF LF（桩程序与手写脚本常用）。
// Content-Type 缺失视为脚本错误（CGI 规范的要求），返回 ok = false。
parse_cgi_response :: proc(raw: string, alloc: mem.Allocator) -> (resp: Cgi_Response, ok: bool) {
	sep, sep_len := -1, 0
	if i := strings.index(raw, "\r\n\r\n"); i >= 0 {
		sep, sep_len = i, 4
	} else if i := strings.index(raw, "\n\n"); i >= 0 {
		sep, sep_len = i, 2
	}
	if sep < 0 {
		return {}, false
	}

	resp = Cgi_Response {
		code   = 200,
		reason = "OK",
		body   = raw[sep + sep_len:],
	}
	extra := make([dynamic]http.Extra_Header, 0, 4, alloc)

	rest := raw[:sep]
	first := true
	for len(rest) > 0 {
		line := rest
		if i := strings.index(rest, "\r\n"); i >= 0 {
			line, rest = rest[:i], rest[i + 2:]
		} else if i := strings.index_byte(rest, '\n'); i >= 0 {
			line, rest = rest[:i], rest[i + 1:]
		} else {
			rest = ""
		}
		if len(line) == 0 {
			continue
		}
		// 容忍非标准的 "HTTP/1.1 200 OK" 起始行（CGI 规范要求用 Status:）
		if first && strings.has_prefix(line, "HTTP/") {
			first = false
			if sp := strings.index_byte(line, ' '); sp >= 0 {
				code_str := line[sp + 1:]
				if sp2 := strings.index_byte(code_str, ' '); sp2 >= 0 {
					code_str = code_str[:sp2]
				}
				if n, parsed := parse_uint(code_str); parsed {
					resp.code = n
					resp.reason = cgi_reason(n)
				}
			}
			continue
		}
		first = false

		colon := strings.index_byte(line, ':')
		if colon <= 0 {
			continue
		}
		name := line[:colon]
		value := strings.trim_space(line[colon + 1:])

		switch {
		case ascii_eq(name, "Status"):
			code_str, reason_phrase := value, ""
			if sp := strings.index_byte(value, ' '); sp >= 0 {
				code_str, reason_phrase = value[:sp], strings.trim_space(value[sp + 1:])
			}
			n, parsed := parse_uint(code_str)
			if parsed {
				resp.code = n
				resp.reason = len(reason_phrase) > 0 ? reason_phrase : cgi_reason(n)
			}
		case ascii_eq(name, "Content-Type"):
			resp.content_type = value
		case ascii_eq(name, "Content-Length"), ascii_eq(name, "Connection"):
			// 由 molly 决定，避免脚本给的长度与真实 body 不一致把 keep-alive 搞坏
		case:
			append(&extra, http.Extra_Header{name = name, value = value})
		}
	}

	if len(resp.content_type) == 0 {
		return {}, false
	}
	resp.extra = extra[:]
	return resp, true
}

Cgi_Response :: struct {
	code:         int,
	reason:       string,
	content_type: string,
	extra:        []http.Extra_Header,
	body:         string,
}

// ---------------------------------------------------------------------------
// 桥接
// ---------------------------------------------------------------------------

// path 是已规范化的完整路径；cmd 是 --luci-cgi 的值。
run_cgi :: proc(
	conn: ^http.Connection,
	req: ^http.Request,
	path, docroot, cmd: string,
	alloc: mem.Allocator,
) -> bool {
	argv := split_command(cmd, alloc)
	if len(argv) == 0 {
		return cgi_fail(conn, req, "cgi command is empty", alloc)
	}

	peer_host := net.address_to_string(conn.peer.address, alloc)
	env, _ := build_cgi_env(req, path, peer_host, docroot, alloc)

	// fork 之前把 C 字符串数组全部构造好（子进程里不允许分配）
	argv_c := make([]cstring, len(argv) + 1, alloc)
	for a, i in argv {
		argv_c[i] = strings.clone_to_cstring(a, alloc)
	}
	argv_c[len(argv)] = nil
	env_c := make([]cstring, len(env) + 1, alloc)
	for e, i in env {
		env_c[i] = strings.clone_to_cstring(e, alloc)
	}
	env_c[len(env)] = nil

	in_pipe, out_pipe: [2]posix.FD
	if posix.pipe(&in_pipe) != .OK {
		return cgi_fail(conn, req, "pipe() failed", alloc)
	}
	if posix.pipe(&out_pipe) != .OK {
		posix.close(in_pipe[0])
		posix.close(in_pipe[1])
		return cgi_fail(conn, req, "pipe() failed", alloc)
	}

	pid := posix.fork()
	if pid < 0 {
		posix.close(in_pipe[0])
		posix.close(in_pipe[1])
		posix.close(out_pipe[0])
		posix.close(out_pipe[1])
		return cgi_fail(conn, req, "fork() failed", alloc)
	}

	if pid == 0 {
		// ★ 子进程：从这里到 execve 之间只能做 async-signal-safe 调用。
		posix.dup2(in_pipe[0], 0)
		posix.dup2(out_pipe[1], 1)
		posix.close(in_pipe[0])
		posix.close(in_pipe[1])
		posix.close(out_pipe[0])
		posix.close(out_pipe[1])
		posix.execve(argv_c[0], raw_data(argv_c), raw_data(env_c))
		posix._exit(127) // exec 失败：没有分配，也不能打印
	}

	// ★ 父进程
	posix.close(in_pipe[0])
	posix.close(out_pipe[1])

	// 请求体交给短命线程写，避免与子进程的响应互相阻塞
	writer_thread: ^thread.Thread
	if len(req.body) > 0 {
		writer := new(Cgi_Writer, alloc)
		writer^ = {fd = in_pipe[1], body = req.body}
		writer_thread = thread.create_and_start_with_poly_data(writer, cgi_write_body)
		if writer_thread == nil {
			// 起不了线程就退回同步写：body 可能撑满管道（子进程不读时），但总比什么都不发强
			cgi_write_body(writer)
		}
	} else {
		posix.close(in_pipe[1])
	}

	raw := read_all(out_pipe[0], alloc)
	posix.close(out_pipe[0])

	status: c.int
	_ = posix.waitpid(pid, &status, {})

	if writer_thread != nil {
		// 子进程已退出 → 写端立刻拿到 EPIPE，join 不会久等；join 之后 arena 才能回收 writer
		thread.join(writer_thread)
		thread.destroy(writer_thread)
	}

	resp, ok := parse_cgi_response(raw, alloc)
	if !ok {
		head := raw
		if len(head) > 200 {
			head = head[:200]
		}
		// 正文带上子进程的退出情况：`exit 1` + stdout 为空，最常见的原因就是 --luci-cgi
		// 指错了可执行文件（典型：填成 uhttpd.uc——那是模板不是脚本，它把语法错打到 stderr、
		// stdout 什么都不给）。stderr 继承 molly 的 stderr，细节在 molly 的日志里。
		return cgi_fail(
			conn,
			req,
			fmt.aprintf("invalid CGI response (%s): %q", exit_desc(status, alloc), head, allocator = alloc),
			alloc,
		)
	}

	// Content-Type 只在脚本没给时才由我们兜底（parse 已保证给了）
	extra := make([dynamic]http.Extra_Header, 0, len(resp.extra) + 1, alloc)
	append(&extra, http.Extra_Header{name = "Content-Type", value = resp.content_type})
	for h in resp.extra {
		append(&extra, h)
	}

	return http.respond_full(
		conn,
		resp.code,
		resp.reason,
		extra[:],
		resp.body,
		req.keep_alive,
		req.method == .Head,
		alloc,
	)
}

@(private)
Cgi_Writer :: struct {
	fd:   posix.FD,
	body: []byte,
}

@(private)
cgi_write_body :: proc(w: ^Cgi_Writer) {
	send_all(w.fd, w.body)
	posix.close(w.fd)
}

@(private)
send_all :: proc(fd: posix.FD, data: []byte) {
	off := 0
	for off < len(data) {
		n := posix.write(fd, raw_data(data[off:]), c.size_t(len(data)) - c.size_t(off))
		if n < 0 {
			return // EPIPE / EINTR 都直接放弃：子进程不要这个 body 了
		}
		off += int(n)
	}
}

@(private)
read_all :: proc(fd: posix.FD, alloc: mem.Allocator) -> string {
	buf := make([dynamic]byte, 0, 8192, alloc)
	chunk: [8192]byte
	for {
		n := posix.read(fd, raw_data(chunk[:]), c.size_t(len(chunk)))
		if n <= 0 {
			break
		}
		append(&buf, ..chunk[:int(n)])
	}
	return string(buf[:])
}

// 子进程是怎么结束的：`exit N` / `signal N`。只写进 500 的正文与 molly 的日志，
// 用来区分「脚本自己退出（通常是配置或语法问题）」和「被信号杀掉（崩溃/超时）」。
@(private)
exit_desc :: proc(status: c.int, alloc: mem.Allocator) -> string {
	switch {
	case posix.WIFEXITED(status):
		return fmt.aprintf("exit %d", posix.WEXITSTATUS(status), allocator = alloc)
	case posix.WIFSIGNALED(status):
		return fmt.aprintf("signal %d", int(posix.WTERMSIG(status)), allocator = alloc)
	}
	return "unknown exit status"
}

@(private)
cgi_fail :: proc(conn: ^http.Connection, req: ^http.Request, msg: string, alloc: mem.Allocator) -> bool {
	return http.respond(
		conn,
		.Internal_Server_Error,
		fmt.aprintf("%s\n", msg, allocator = alloc),
		{keep_alive = req.keep_alive},
	)
}

// 命令按空白切分（不接受引号与转义）：--luci-cgi 是管理员配置的固定命令。
@(private)
split_command :: proc(cmd: string, alloc: mem.Allocator) -> []string {
	out := make([dynamic]string, 0, 4, alloc)
	rest := cmd
	for {
		rest = strings.trim_left_space(rest)
		if len(rest) == 0 {
			break
		}
		i := strings.index_any(rest, " \t")
		if i < 0 {
			append(&out, rest)
			break
		}
		if i > 0 {
			append(&out, rest[:i])
		}
		rest = rest[i:]
	}
	return out[:]
}

@(private)
method_str :: proc(m: http.Method) -> string {
	switch m {
	case .Get:
		return "GET"
	case .Head:
		return "HEAD"
	case .Post:
		return "POST"
	case .Put:
		return "PUT"
	case .Delete:
		return "DELETE"
	case .Options:
		return "OPTIONS"
	case .Other:
		return "UNKNOWN"
	}
	return "UNKNOWN"
}

@(private)
is_cgi_special_header :: proc(name: string) -> bool {
	for s in CGI_SPECIAL_HEADERS {
		if ascii_eq(name, s) {
			return true
		}
	}
	return false
}

// X-Forwarded-For → HTTP_X_FORWARDED_FOR（ASCII 大写 + '-' → '_'）
@(private)
header_env_name :: proc(name: string, alloc: mem.Allocator) -> string {
	out := make([]byte, len(name), alloc)
	for i := 0; i < len(name); i += 1 {
		c := name[i]
		switch c {
		case '-':
			out[i] = '_'
		case 'a' ..= 'z':
			out[i] = c - 32
		case:
			out[i] = c
		}
	}
	return string(out)
}

@(private)
parse_uint :: proc(s: string) -> (n: int, ok: bool) {
	if len(s) == 0 {
		return 0, false
	}
	for i := 0; i < len(s); i += 1 {
		if s[i] < '0' || s[i] > '9' {
			return 0, false
		}
		n = n * 10 + int(s[i] - '0')
	}
	return n, true
}

// CGI 常见状态码的原因短语。表外的码不带短语（`HTTP/1.1 418 \r\n` 仍是合法状态行）。
@(private)
cgi_reason :: proc(code: int) -> string {
	switch code {
	case 200:
		return "OK"
	case 201:
		return "Created"
	case 204:
		return "No Content"
	case 301:
		return "Moved Permanently"
	case 302:
		return "Found"
	case 303:
		return "See Other"
	case 304:
		return "Not Modified"
	case 307:
		return "Temporary Redirect"
	case 308:
		return "Permanent Redirect"
	case 400:
		return "Bad Request"
	case 401:
		return "Unauthorized"
	case 403:
		return "Forbidden"
	case 404:
		return "Not Found"
	case 405:
		return "Method Not Allowed"
	case 408:
		return "Request Timeout"
	case 411:
		return "Length Required"
	case 413:
		return "Payload Too Large"
	case 415:
		return "Unsupported Media Type"
	case 422:
		return "Unprocessable Entity"
	case 429:
		return "Too Many Requests"
	case 500:
		return "Internal Server Error"
	case 501:
		return "Not Implemented"
	case 502:
		return "Bad Gateway"
	case 503:
		return "Service Unavailable"
	case 504:
		return "Gateway Timeout"
	}
	return ""
}

// ASCII 大小写不敏感比较（http 包里的同名 proc 是 @(private)，这里给 handlers 用）
@(private)
ascii_eq :: proc(a, b: string) -> bool {
	if len(a) != len(b) {
		return false
	}
	for i := 0; i < len(a); i += 1 {
		ca, cb := a[i], b[i]
		if ca >= 'A' && ca <= 'Z' {
			ca += 32
		}
		if cb >= 'A' && cb <= 'Z' {
			cb += 32
		}
		if ca != cb {
			return false
		}
	}
	return true
}
