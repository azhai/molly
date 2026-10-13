package main

// 阶段 1 集成 spike：证明「Odin → bindings.molly_* → shim.o → 真 libubus」这条链
// 在设备上能跑通。这里只走 ubus 客户端路径（connect/free），不触服务端回调。

import "core:fmt"

import b "molly:backend/bindings"

// shim.c 的 ubus 服务端回调目标。spike 不注册自有对象，直接回 8（NOT_SUPPORTED），
// shim 收到非 0 就不 send_reply。这同时演示 @(export) 导出 C 可调符号的机制
// （@(export) = 导出给链接器 + C 调用约定 + 无隐式 context），阶段 3 的真正 handler 就长这样。
@(export)
mollyGoHandle :: proc(obj, method, params: ^u8, reply_out: ^^u8) -> i32 {
	_ = obj; _ = method; _ = params; _ = reply_out
	return 8 // StatusNotSupported
}

main :: proc() {
	// path = nil → 用库内默认 socket（设备上 /var/run/ubus/ubus.sock）。
	ctx := b.molly_ubus_connect(nil)
	fmt.println("bindings spike: molly_ubus_connect ->", ctx)
	if ctx != nil {
		// 顺带证明 lookup_id 能解析符号：查 hostinfo（设备上通常存在）。
		id: u32 = 0
		rc := b.molly_ubus_lookup_id(ctx, "hostid", &id)
		fmt.println("bindings spike: molly_ubus_lookup_id rc=", rc, " id=", id)
		b.molly_ubus_free(ctx)
		fmt.println("bindings spike: molly_ubus_free ok")
	} else {
		fmt.println("bindings spike: connect 失败（无 ubusd？）——但链接链已验证")
	}
}
