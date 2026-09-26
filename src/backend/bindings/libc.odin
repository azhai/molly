#+build linux
package bindings

// 只需要一个 free()。
//
// 原因：libblobmsg_json 的 blobmsg_format_json_with_cb（以及它的 inline 包装
// blobmsg_format_json）返回的是 malloc 出来的字符串（`blobmsg_json.c` 里的
// strbuf），归调用方释放——上游 uhttpd 也是拿完就 `free()`（`ubus.c:208`）。
// 这块内存不是 Odin 堆分配的，所以不能用 Odin 的 allocator 回收。

import "core:c"

foreign import libc "system:c"

foreign libc {
	// 加 c_ 前缀是为了调用点读起来明确（bindings.c_free），link_name 仍是 free。
	@(link_name = "free")
	c_free :: proc(ptr: rawptr) ---

	// crypt(3)：P3-2 的 login 用它校验 /etc/config/rpcd 里的密码 hash（rpcd session.c:850）。
	//
	// 走 system:c 而不是 system:crypt：musl 把 crypt 编在 libc 内部（OpenWrt 的
	// libcrypt.a 只是给 `-lcrypt` 用的空壳，rpcd 的 Makefile 里写的就是 -lcrypt），
	// 所以链接时由 libc 提供符号，设备上同样是 libc.so.1 导出它。
	//
	// **非线程安全**（返回内部静态缓冲）：调用点必须串行化，见 linux.odin 的
	// session_verify_password（只在 ubus 服务线程里调用）。
	@(link_name = "crypt")
	crypt :: proc(key, salt: cstring) -> cstring ---

	// realpath(3)：P3-4（file 对象）的符号链接复查用它（file.c:261-359）。
	// 与 crypt 同理走 system:c —— musl 与 glibc 都导出它。
	@(link_name = "realpath")
	c_realpath :: proc(path: cstring, resolved: [^]u8) -> cstring ---
}