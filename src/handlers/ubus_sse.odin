package handlers

import "core:c"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:sys/posix"

import "molly:backend"
import "molly:http"

// ---------------------------------------------------------------------------
// GET /ubus/subscribe/<对象路径> —— SSE（P3-7）
//
// 上游 `ubus.c:373-424`（逐条对齐）：
//   1. sid 从 `Authorization: Bearer` 取（`uh_ubus_get_auth`，:380）；
//   2. `uh_ubus_allowed(sid, path, ":subscribe")` 不过 → 200 + `application/json`
//      + `{"code":-13,"message":"Permission denied"}`（`uh_ubus_posix_error`，:382-386）；
//      注意这里是 **posix 负码**，不是 JSON-RPC 的 -32002——订阅走的是 GET 分支；
//   3. `ubus_register_subscriber` / `ubus_lookup_id` / `ubus_subscribe` 任一失败 →
//      同样 200 + json + `{"code":<ubus 码>,"message":…}`（:416-423）；
//   4. 成功 → 200 + `Content-Type: text/event-stream`（:405），可选 `retry: <ms>\n`（:407-408）；
//   5. 帧：`event: <method>\ndata: <json>\n\n`（:345）；
//   6. 客户端断开 → `ubus_unregister_subscriber`（:366-371）。
//
// molly 的差异（记进 docs/interfaces.md）：
//   - 通知回调发生在 ubus 线程，所以中间接了一根管道（ADR 0001 第 3 条），
//     HTTP 线程 poll 它；上游在同一个线程里直接写 socket。
//   - 上游的响应走 chunked（`ops->chunk_printf`），molly 没有 chunked 编码器，
//     这里是「无 Content-Length + Connection: close」的裸流。
//   - 上游没有心跳（靠 TCP/uhttpd 的连接超时），molly 每隔 SSE_HEARTBEAT_MS
//     发一条注释帧（`: heartbeat\n\n`），免得中间代理把长连接掐了。
//   - `retry:` 只有 uhttpd 配了 `-e` 才发；molly 没有这个选项，不发。
// ---------------------------------------------------------------------------

// 上游 `:382` 的伪方法名：订阅的权限点与 `call` 的方法名不在一个命名空间里。
UBUS_SUBSCRIBE_FN :: ":subscribe"

// EACCES（上游订阅被拒时回的是 `-EACCES`，:258、:384）。
EACCES :: 13

// 心跳间隔（毫秒）。上游没有这个值——它是 molly 为了长连接能穿过代理加的。
SSE_HEARTBEAT_MS :: 30 * 1000

// 一次最多读这么多字节；记录更长的话按「读到哪算哪」截断（发布侧单条 < 4KB）。
SSE_READ_CHUNK :: 4096

serve_subscribe :: proc(conn: ^http.Connection, req: ^http.Request, path: string) -> bool {
	alloc := mem.dynamic_arena_allocator(&conn.arena)

	// 1) ACL（上游顺序：ACL 在 lookup 之前）
	sid := auth_sid(req)
	if !backend.session_access_ubus(sid, path, UBUS_SUBSCRIBE_FN) {
		return json_subscribe_error(conn, req, -EACCES, "Permission denied", alloc)
	}

	// 2) 对象必须存在（上游 ubus_lookup_id，:397-399）
	_, err, ok := backend.list_objects(path, alloc)
	if !ok {
		return json_subscribe_error(conn, req, err, backend.ubus_error_message(err, alloc), alloc)
	}

	// 3) 订阅（拿不到管道/满了 → 当作 UNKNOWN_ERROR，与上游注册失败同形）
	sub, sub_ok := backend.event_bus_subscribe(path, alloc)
	if !sub_ok {
		return json_subscribe_error(
			conn,
			req,
			backend.UBUS_STATUS_UNKNOWN_ERROR,
			backend.ubus_error_message(backend.UBUS_STATUS_UNKNOWN_ERROR, alloc),
			alloc,
		)
	}
	defer backend.event_bus_unsubscribe(sub)

	// 4) 头（不带 Content-Length：正文长度未知，靠关闭连接收尾）
	head := "HTTP/1.1 200 OK\r\n" +
		"Content-Type: text/event-stream\r\n" +
		"Cache-Control: no-cache\r\n" +
		"Connection: close\r\n" +
		"\r\n"
	if !http.send_raw(conn.socket, head) {
		return false
	}

	// 5) 循环：poll 管道 → 发帧；超时发心跳；对端/管道出错就收尾
	tmp: [SSE_READ_CHUNK]u8
	for {
		pfd := posix.pollfd{fd = sub.rfd, events = {.IN}}
		n := posix.poll(&pfd, posix.nfds_t(1), c.int(SSE_HEARTBEAT_MS))
		if n < 0 {
			// EINTR 之外都当结束（管道不会真的坏，除非写端被关了）
			break
		}
		if n == 0 {
			if !http.send_raw(conn.socket, ": heartbeat\n\n") {
				break
			}
			continue
		}

		r := posix.read(sub.rfd, &tmp[0], c.size_t(len(tmp)))
		if r == 0 {
			break // 写端全关（订阅被注销）
		}
		if r < 0 {
			continue // 非阻塞下 EAGAIN：下一轮 poll 再见
		}

		if !sse_send_records(conn, string(tmp[:r]), alloc) {
			break
		}
	}

	// SSE 结束后连接不再复用（正文没有长度边界）
	return false
}

// 一批字节里可能有若干条记录（`<method>\t<json>\n`），逐条发一帧。
// 末尾不完整的那段丢弃：发布侧一次 write 一条完整记录，出现残段只可能是
// 单条记录超过 SSE_READ_CHUNK，而那本来就是「尽力而为」的推送。
@(private)
sse_send_records :: proc(conn: ^http.Connection, chunk: string, alloc: mem.Allocator) -> bool {
	rest := chunk
	for len(rest) > 0 {
		idx := strings.index_byte(rest, '\n')
		if idx < 0 {
			break
		}
		line := rest[:idx]
		rest = rest[idx + 1:]
		if len(line) == 0 {
			continue
		}
		method, data, ok := sse_record_split(line)
		if !ok {
			continue
		}
		frame := sse_frame(method, data, alloc)
		if !http.send_raw(conn.socket, frame) {
			return false
		}
	}
	return true
}

// 一帧 SSE（上游 `ubus.c:345` 的 `event: %s\ndata: %s\n\n`）。
sse_frame :: proc(method, data: string, alloc: mem.Allocator) -> string {
	return fmt.aprintf("event: %s\ndata: %s\n\n", method, data, allocator = alloc)
}

// 拆 `<method>\t<data>`（总线里记录的格式，见 backend/event_bus.odin）。
sse_record_split :: proc(line: string) -> (method: string, data: string, ok: bool) {
	idx := strings.index_byte(line, '\t')
	if idx < 0 {
		return "", "", false
	}
	return line[:idx], line[idx + 1:], true
}

// 订阅失败的回复：200 + `application/json` + `{"code":<码>,"message":"…"}`
// （上游 `uh_ubus_error`，:247-264：posix 错误传负码，ubus 错误传正码）。
@(private)
json_subscribe_error :: proc(
	conn: ^http.Connection,
	req: ^http.Request,
	code: int,
	message: string,
	alloc: mem.Allocator,
) -> bool {
	body := fmt.aprintf(`{{"code":%d,"message":"%s"}}`, code, message, allocator = alloc)
	return http.respond(conn, .OK, body, {
		content_type = "application/json",
		keep_alive   = req.keep_alive,
	})
}
