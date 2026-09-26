package main

// spike 01：验证两件事
//   1) Odin 能编出 aarch64 目标文件，再由 OpenWrt SDK 的 gcc 完成链接
//   2) foreign import 能真正调用 OpenWrt 现成的 libuci / libubus
//
// 验收标准：
//   - 二进制在 aarch64 OpenWrt 上跑起来
//   - 打印出 network.lan.proto 的真实取值（证明 libuci 可用）
//   - 打印出 network.interface 的对象 id 并成功 invoke dump（证明 libubus 可用）

import "core:c"
import "core:fmt"

// ---------------------------------------------------------------------------
// libuci
// ---------------------------------------------------------------------------

foreign import uci "system:uci"

// 全部当作不透明句柄，spike 只拿指针，不读它们的字段。
Uci_Context :: struct {}
Uci_Package :: struct {}
Uci_Element :: struct {}
Uci_Section :: struct {}
Uci_Option :: struct {}

// enum uci_type（uci.h 第 362 行）。
// 必须是 4 字节：Odin 的 enum 默认基类型是 int（64 位平台上是 8 字节），
// 所以这里必须显式写 c.int，否则整个 uci_ptr 的布局会全错。
Uci_Type :: enum c.int {
	Unspec  = 0,
	Delta   = 1,
	Package = 2,
	Section = 3,
	Option  = 4,
	Path    = 5,
	Backend = 6,
	Item    = 7,
	Hook    = 8,
}

// uci_ptr 里的匿名 enum 位标志
UCI_LOOKUP_DONE     :: 1 << 0
UCI_LOOKUP_COMPLETE :: 1 << 1
UCI_LOOKUP_EXTENDED :: 1 << 2

// uci.h 第 496 行（commit 66127cd7，即 ImmortalWrt 25.12.2 用的版本）：
//
//	struct uci_ptr {
//	    enum uci_type target;      // 0
//	    enum { ... } flags;        // 4  匿名 enum，4 字节
//	    struct uci_package *p;     // 8
//	    struct uci_section *s;     // 16
//	    struct uci_option  *o;     // 24
//	    struct uci_element *last;  // 32
//	    const char *package;       // 40
//	    const char *section;       // 48
//	    const char *option;        // 56
//	    const char *value;         // 64
//	};                             // sizeof = 72
//
// 注意：老版本 uci 的 uci_ptr 是以 target/package/section/option/value 这五个
// 字符串开头的，p/s/o/last 在后。新版反过来了。按老布局写会导致 uci_lookup_ptr
// 往错误偏移写数据，且不报错——所以下面加了编译期尺寸断言兜底。
// Odin 的 package / option / type / ptr 是关键字，字段名只能用别名；
// 结构体布局只按声明顺序匹配 C，不校验名字。
Uci_Ptr :: struct {
	target:  Uci_Type,
	flags:   c.int,
	p:       ^Uci_Package,
	s:       ^Uci_Section,
	o:       ^Uci_Option,
	last:    ^Uci_Element,
	pkg:     cstring, // C: package
	section: cstring,
	opt:     cstring, // C: option
	value:   cstring,
}

#assert(size_of(Uci_Ptr) == 72, "Uci_Ptr 必须与 C 的 uci_ptr 同为 72 字节")

@(default_calling_convention = "c")
foreign uci {
	uci_alloc_context :: proc() -> ^Uci_Context ---
	uci_free_context  :: proc(ctx: ^Uci_Context) ---
	uci_load          :: proc(ctx: ^Uci_Context, name: cstring, pkg: ^^Uci_Package) -> c.int ---
	uci_lookup_ptr    :: proc(ctx: ^Uci_Context, out_ptr: ^Uci_Ptr, str: cstring, extended: bool) -> c.int ---
	uci_perror        :: proc(ctx: ^Uci_Context, str: cstring) ---
}

// ---------------------------------------------------------------------------
// libubus
// ---------------------------------------------------------------------------

foreign import ubus "system:ubus"

Ubus_Context :: struct {}
Blob_Attr :: struct {}
Ubus_Request :: struct {}

Ubus_Data_Handler :: #type proc(req: ^Ubus_Request, reply_type: c.int, msg: ^Blob_Attr)

@(default_calling_convention = "c")
foreign ubus {
	ubus_connect   :: proc(path: cstring) -> ^Ubus_Context ---
	ubus_free      :: proc(ctx: ^Ubus_Context) ---
	ubus_lookup_id :: proc(ctx: ^Ubus_Context, path: cstring, id: ^u32) -> c.int ---

	// 注意：libubus.h 里的 ubus_invoke 是 static inline 包装，
	// 只是在头文件里转调 ubus_invoke_fd(..., -1)，libubus.so 并不导出它。
	// 所以这里必须绑定真正导出的 ubus_invoke_fd，末尾多一个 fd 参数。
	ubus_invoke_fd :: proc(
		ctx: ^Ubus_Context,
		obj: u32,
		method: cstring,
		msg: ^Blob_Attr,
		cb: Ubus_Data_Handler,
		priv: rawptr,
		timeout: c.int,
		fd: c.int,
	) -> c.int ---
}

on_ubus_data :: proc(req: ^Ubus_Request, reply_type: c.int, msg: ^Blob_Attr) {
	fmt.println("[ubus] dump 回调已触发，reply_type =", reply_type)
}

// ---------------------------------------------------------------------------

check_uci :: proc() {
	ctx := uci_alloc_context()
	if ctx == nil {
		fmt.eprintln("[uci] uci_alloc_context 失败")
		return
	}
	defer uci_free_context(ctx)

	pkg: ^Uci_Package
	if uci_load(ctx, "network", &pkg) != 0 {
		uci_perror(ctx, "[uci] uci_load network")
		return
	}
	fmt.println("[uci] 已加载 package: network")

	entry: Uci_Ptr
	if uci_lookup_ptr(ctx, &entry, "network.lan.proto", true) != 0 {
		uci_perror(ctx, "[uci] uci_lookup_ptr network.lan.proto")
		return
	}
	if entry.value == nil {
		fmt.println("[uci] network.lan.proto 存在但取值为空")
	} else {
		fmt.printfln("[uci] network.lan.proto = %s", entry.value)
	}
}

check_ubus :: proc() {
	ctx := ubus_connect(nil)
	if ctx == nil {
		fmt.eprintln("[ubus] ubus_connect 失败")
		return
	}
	defer ubus_free(ctx)

	id: u32
	if ubus_lookup_id(ctx, "network.interface", &id) != 0 {
		fmt.eprintln("[ubus] 找不到对象 network.interface")
		return
	}
	fmt.printfln("[ubus] network.interface 对象 id = %d", id)

	if ubus_invoke_fd(ctx, id, "dump", nil, on_ubus_data, nil, 1000, -1) != 0 {
		fmt.eprintln("[ubus] invoke network.interface.dump 失败")
		return
	}
	fmt.println("[ubus] invoke dump 成功")
}

main :: proc() {
	fmt.println("spike 01: Odin + OpenWrt SDK (aarch64_cortex-a53, musl, 动态链接)")

	check_uci()
	check_ubus()

	fmt.println("spike 01: 结束")
}
