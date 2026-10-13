package handlers

// ubus_sse —— GET /ubus/subscribe/<对象路径> 的**纯决策**那半（对齐 internal/handlers/ubus.go 的
// sseFrame / subscribeError，以及上游 ubus.c 的 SSE 帧格式）。
//
// 已落地的可 host 单测部分：
//   - 帧格式化：`event: <method>\ndata: <json>\n\n`（上游 ubus.c:345）与空闲心跳注释帧 `: heartbeat\n\n`；
//   - 订阅失败的 200+JSON 信封 `{"code":N,"message":"…"}`（ACL 不过给 posix **负码** -13，对象/容量给 ubus 正码）。
//
// 带 I/O 的事件循环（对齐 Go 的 ubusSubscribe）已接线：ACL 先于 lookup → 对象存在 → Subscribe →
// Write_Head(text/event-stream) → 轮询循环（backend.Try_Recv 到事件即发帧；空闲到心跳点发注释帧；
// 用 http.Peer_Closed 非阻塞探测客户端断开即收尾，对齐 Go 的 context.Done）。

import "core:encoding/json"
import "core:time"
import "molly:backend"
import "molly:http"

// 订阅权限点的伪方法名 ubus_subscribe_fn = ":subscribe" 已在 ubus_http.odin 声明（上游 ubus.c:382）。

// ubus_eacces —— posix EACCES（13）。ACL 不过时订阅回的是这个 posix **负码**（-13），
// 而非 JSON-RPC 的 -32002（对齐 ubus.go:148-149）。
ubus_eacces :: 13

// sse_heartbeat_ms —— 心跳间隔。上游没有，这是 molly 为长连接穿代理加的（对齐 Go sseHeartbeat=30s）。
sse_heartbeat_frame :: ": heartbeat\n\n"

// sse_frame —— 一帧 SSE：`event: <method>\ndata: <data>\n\n`（对齐上游 ubus.c:345 与 Go sseFrame）。
sse_frame :: proc(method, data: string) -> string {
	return build([]string{"event: ", method, "\ndata: ", data, "\n\n"})
}

// subscribe_error_json —— 订阅失败的 200+application/json 信封 `{"code":N,"message":"…"}`
// （对齐 Go subscribeError / 上游 uh_ubus_error：posix 错误传负码、ubus 错误传正码）。
// 键升序由 json_opts（sort_maps_by_key）保证：code 在 message 前。
subscribe_error_json :: proc(code: i32, message: string) -> string {
	obj := make(json.Object)
	obj["code"] = json.Integer(cast(i64)code)
	obj["message"] = json.String(message)
	return json_unparse(json.Value(obj))
}

// ubus_subscribe_acl_denied —— 「ACL 点 :subscribe 是否放行」的薄封装，供循环在 lookup 之前判
// （上游顺序：ACL 先于 ubus_lookup_id）。纯 backend 调用，无 I/O。
ubus_subscribe_acl_denied :: proc(sid, path: string) -> bool {
	return ! backend.Backend_Session_Access(sid, path, ubus_subscribe_fn)
}

// sse_heartbeat —— 空闲心跳间隔（穿代理用）。对齐 Go 的 sseHeartbeat=30s。
sse_heartbeat :: 30 * time.Second

// sse_poll —— 轮询步长：无事件时每这么多醒一次，探断开 / 判心跳。100ms 足够及时且开销忽略。
sse_poll :: 100 * time.Millisecond

// str_bytes —— string → []u8 视图（同底层布局，零拷贝；生命期跟随入 s）。写成 proc 是为了把常量
// 实参先固型为 string，再在内部 transmute（transmute 不接受无类型常量）。
str_bytes :: proc(s: string) -> []u8 {
	return transmute([]u8) s
}

// ---------------------------------------------------------------------------
// Serve_Ubus 的 GET 分支命中 ubus_subscribe_pfx 后调这里（逐步骤对齐 Go ubusSubscribe）。
// ---------------------------------------------------------------------------

// ubus_subscribe —— GET /ubus/subscribe/<对象路径> 的 SSE 入口（含 I/O 循环）。
//   1. sid 从 Authorization: Bearer 取（auth_sid）；
//   2. ACL 点 ":subscribe" 不过 → 200 + json + {"code":-13,"message":"Permission denied"}；
//   3. 对象不存在 → 200 + json + {"code":<ubus 码>,"message":…}（ACL 已在 lookup 之前判）；
//   4. 订阅容量满 → 200 + json + UNKNOWN_ERROR(9)；
//   5. 成功 → Write_Head(text/event-stream) 后进循环；defer Unsubscribe（关通道、末条触发 watch_stop）。
//
// 循环无 Go 的 select：用 backend.Try_Recv 非阻塞取事件；没取到就用 http.Peer_Closed 探客户端是否已走，
// 空闲满 sse_heartbeat 补一条注释帧；每轮小睡 sse_poll 让出。写失败或探到断开即收尾。
ubus_subscribe :: proc(res: ^http.Response, req: ^http.Request, obj_path: string) {
	sid := auth_sid(req)
	if ubus_subscribe_acl_denied(sid, obj_path) {
		http.Respond(res, 200, subscribe_error_json(-i32(ubus_eacces), "Permission denied"), "application/json")
		return
	}

	_, err_code, lok := backend.List_Objects(obj_path, context.allocator)
	if ! lok {
		http.Respond(res, 200, subscribe_error_json(err_code, backend.Ubus_Error_Message(err_code)), "application/json")
		return
	}

	sub, sok := backend.Subscribe(obj_path)
	if ! sok {
		unk := i32(backend.Status_Unknown_Error)
		http.Respond(res, 200, subscribe_error_json(unk, backend.Ubus_Error_Message(unk)), "application/json")
		return
	}
	defer backend.Unsubscribe(sub)

	hdrs := []http.Header{
		http.Header{"Content-Type", "text/event-stream"},
		http.Header{"Cache-Control", "no-cache"},
	}
	http.Write_Head(res, 200, hdrs) // 置 close_after：本请求后 server 关连接，不 keep-alive

	last_beat := time.tick_now()
	for {
		ev, got := backend.Try_Recv(sub)
		if got {
			frame := sse_frame(ev.method, ev.data)
			wrote := http.Write_Chunk_Ok(res, str_bytes(frame))
			backend.Free_Event(ev) // 所有权在此终结（无论写成功与否）
			if ! wrote {
				break
			}
			last_beat = time.tick_now()
			continue
		}
		if http.Peer_Closed(res) {
			break // 客户端已关连接
		}
		if time.tick_since(last_beat) >= sse_heartbeat {
			if ! http.Write_Chunk_Ok(res, str_bytes(sse_heartbeat_frame)) {
				break
			}
			last_beat = time.tick_now()
		}
		time.sleep(sse_poll)
	}
}
