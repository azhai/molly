package backend

// object_provider_linux —— linux（目标设备）上的外部对象 provider（对齐 internal/backend/linux.go）。
// 真 libubus 往返：外部对象（netifd / service / network.* …）经 molly_ubus_* 走总线。
//
// 与 Go 版的刻意一致：molly 自有的五个对象（+ luci 的 getFeatures）走**进程内**真实现
// （call_own_object），不做 ubus 往返——可观测结果与往返一致（跑同一份 handler 逻辑），
// 但避免「同 ctx 跨线程 invoke」与 uloop poll 冲突。例外：桥接态（session_on_bus）下的 session
// 交给总线上的 rpcd（登录与会话读写落 rpcd，sysauth 里的 sid 全端通用）。
//
// libubus ctx 非线程安全、shim.c 复用全局 blob_buf → HTTP 侧所有调用共用一把锁串行化（= Go 的 ubusMu）。
// 连不上**不**缓存失败，下次调用再试（代价一次 connect）。
//
// 文件名后缀 _linux 让 Odin 只在 linux 目标编本文件（darwin 走 object_provider_darwin.odin）。

import "core:mem"
import "core:strings"
import "core:sync"
import "base:runtime"

import "bindings"

// ubus_invoke_timeout_ms —— 对齐 cbind.go 的 timeoutMS。
ubus_invoke_timeout_ms :: 30000

ubus_mu     : sync.Mutex
ubus_socket : string // 私有总线路径（进程生命周期持有一份持久克隆）；空 = 系统总线
own_ctx     : rawptr
sys_ctx     : rawptr

// server_socket —— 服务线程在其整个生命周期读这条 C 串，必须进程级持久（不能用请求 arena）。
server_socket: cstring

// Set_Ubus_Socket —— 记下私有总线路径（main 于起任何线程之前调一次）。克隆进默认分配器持久持有。
Set_Ubus_Socket :: proc(path: string) {
	ubus_socket = strings.clone(path, runtime.default_allocator())
}

// ubus_in_cstr —— 入参串转 cstring（context.allocator，随请求 arena 回收，**不** molly_free）。
// 空串 → nil（对齐 shim/Go 的「NULL = 用默认 / 不追加」语义）。
ubus_in_cstr :: proc(s: string) -> cstring {
	if s == "" {
		return nil
	}
	return strings.clone_to_cstring(s)
}

// own_conn / sys_conn —— 仅在持 ubus_mu 时调用。ownCtx 是 molly 对象所在总线；
// sysConn 只在访问系统对象时用，没配私有总线时就是 own_conn（主连接即系统总线）。
own_conn :: proc() -> rawptr {
	if own_ctx == nil {
		own_ctx = bindings.molly_ubus_connect(ubus_in_cstr(ubus_socket))
	}
	return own_ctx
}

sys_conn :: proc() -> rawptr {
	if ubus_socket == "" {
		return own_conn()
	}
	if sys_ctx == nil {
		sys_ctx = bindings.molly_ubus_connect(nil)
	}
	return sys_ctx
}

// c_out_string —— 把 C 出参（malloc）串先 clone 进 alloc，再 molly_free 原缓冲。
c_out_string :: proc(cs: cstring, alloc: mem.Allocator) -> string {
	s := strings.clone_from_cstring(cs, alloc)
	bindings.molly_free(transmute(rawptr)(cs))
	return s
}

// list_on —— 在指定连接上做 GET /ubus/list[/<path>]。
list_on :: proc(ctx: rawptr, path: string, alloc: mem.Allocator) -> (json_text: string, err: i32, ok: bool) {
	out_c: cstring
	e := bindings.molly_ubus_lookup(ctx, ubus_in_cstr(path), &out_c)
	if e != 0 {
		return "", e, false
	}
	if out_c == nil {
		return "", 0, true
	}
	return c_out_string(out_c, alloc), 0, true
}

// List_Objects —— 列对象签名。私有总线模式下系统对象只挂系统总线，查不到换那条再查一次
// （ubus_http 在 invoke 前先 list 探存在性，漏这层系统对象会被误判 Object not found）。
List_Objects :: proc(path: string, alloc: mem.Allocator) -> (json_text: string, err: i32, ok: bool) {
	sync.mutex_lock(&ubus_mu)
	defer sync.mutex_unlock(&ubus_mu)

	ctx := own_conn()
	if ctx == nil {
		return "", Status_Connection_Failed, false
	}
	j, e, found := list_on(ctx, path, alloc)
	if !found {
		if sys := sys_conn(); sys != nil && sys != ctx {
			return list_on(sys, path, alloc)
		}
	}
	return j, e, found
}

// Call_Object —— 一次 ubus 调用（不含 JSON-RPC 信封）。自有对象先走进程内；
// 其余：先自己总线找对象 id，失败且系统总线不同则回退；然后同步 invoke（sid 由 shim 追加）。
Call_Object :: proc(obj, method, params_json, sid: string, alloc: mem.Allocator) -> Call_Result {
	// 自有对象走进程内真实现（桥接态的 session 例外——交给总线上的 rpcd）。
	if !(session_on_bus && obj == "session") {
		if reply, status, handled := call_own_object(obj, method, params_json, sid, alloc); handled {
			if status != 0 {
				return Call_Result{outcome = .Ok, ret = status}
			}
			return Call_Result{outcome = .Ok, ret = 0, reply = reply}
		}
	}

	sync.mutex_lock(&ubus_mu)
	defer sync.mutex_unlock(&ubus_mu)

	ctx := own_conn()
	if ctx == nil {
		return Call_Result{outcome = .Internal}
	}

	// 1) 找对象：先自己总线，失败且系统总线不同 → 回退系统总线；都失败 → Object_Not_Found。
	use := ctx
	id: u32
	e := bindings.molly_ubus_lookup_id(ctx, ubus_in_cstr(obj), &id)
	if e != 0 {
		sys := sys_conn()
		if sys == nil || sys == use {
			return Call_Result{outcome = .Object_Not_Found}
		}
		id2: u32
		if bindings.molly_ubus_lookup_id(sys, ubus_in_cstr(obj), &id2) != 0 {
			return Call_Result{outcome = .Object_Not_Found}
		}
		id, use = id2, sys
	}

	// 2) 同步调用。molly_ubus_invoke 把「请求没发出去」与「远端 INVALID_ARGUMENT」合并成同一个返回值：
	// INVALID_ARGUMENT 当本机故障（Internal），其余（NOT_FOUND / TIMEOUT / METHOD_NOT_FOUND…）当远端返回码。
	out_c: cstring
	ret := bindings.molly_ubus_invoke(use, id, ubus_in_cstr(method), ubus_in_cstr(params_json), ubus_in_cstr(sid), ubus_invoke_timeout_ms, &out_c)
	if ret != 0 {
		if ret == Status_Invalid_Argument {
			return Call_Result{outcome = .Internal}
		}
		return Call_Result{outcome = .Ok, ret = ret}
	}
	reply := ""
	if out_c != nil {
		reply = c_out_string(out_c, alloc)
	}
	return Call_Result{outcome = .Ok, ret = 0, reply = reply}
}

// Start_Server —— 起 ubus 服务线程并注册五个对象（入站回调 = backend.odin 的 mollyGoHandle，
// shim 直接接，无需另设 handler）。socket_path 为空用系统总线。main 在起 HTTP 前调一次。
Start_Server :: proc(socket_path: string) -> i32 {
	Set_Ubus_Socket(socket_path)
	if server_socket == nil && socket_path != "" {
		// 服务线程整个生命周期读这条 C 串 → 默认分配器持久持有，绝不随请求 arena 回收。
		server_socket = strings.clone_to_cstring(socket_path, runtime.default_allocator())
	}
	return bindings.molly_ubus_start_server(server_socket)
}
