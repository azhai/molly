#+build linux
package bindings

// libubox 的 blob 绑定（目标平台 aarch64_cortex-a53 + little-endian）。
//
// 为什么不只写 foreign 声明：
//   blob.h 里的 blob_data / blob_id / blob_is_extended / blob_len / blob_raw_len /
//   blob_pad_len / blob_next 全是 static inline，.so 里**没有**这些符号
//   （已用 `llvm-nm -D libubox.so.20260213` 核过）。所以这里按头文件逐行复刻成
//   Odin proc，保证与设备上 SDK 的布局/算术完全一致。
//
// 字节序：blob 的 id_len / namelen / 数值 payload 一律**大端**存在内存里。读的
// 时候先按本机序取 u32/u16，再手工 swap（be32_to_cpu / be16_to_cpu），与
// libubox 的 utils.h 宏等价；只在 little-endian 上正确——目标 aarch64 与开发机
// arm64 都是 LE，所以够用。
//
// 为什么全是 `proc "contextless"`：
//   这些函数会被 `proc "c"` 的回调（ubus 的 list/data handler）调用，而 `proc "c"`
//   体内**没有隐式 context**。普通 Odin proc 默认带一个隐式 context 参数，于是
//   在回调里调用会报 "context has not been defined within this scope"。全部标成
//   contextless 即可——它们本来也不碰内存分配/断言之类需要 context 的东西。
//
// 权威来源：/Users/ryan/openwrt-sdks/src/libubox/blob.h（与 sysroot 里的头一致）。

import "core:c"

// 故意保留 `import "core:c"` 为包级唯一 import：本文件只用它拿 c.int/c.uint。
foreign import ubox "system:ubox"

foreign ubox {
	blob_buf_init :: proc(buf: ^Blob_Buf, id: c.int) -> c.int ---
	blob_buf_free :: proc(buf: ^Blob_Buf) ---
	blob_nest_end :: proc(buf: ^Blob_Buf, cookie: rawptr) ---
	// blobmsg_open_nested 属于 blobmsg，但同一份库、同一份状态机，放在这里一起声明
	// 省一个文件（它跟 blob_new / blob_set_raw_len 是配套的）。
	blobmsg_open_nested :: proc(buf: ^Blob_Buf, name: cstring, array: bool) -> rawptr ---
	blobmsg_add_field :: proc(buf: ^Blob_Buf, attr_type: c.int, name: cstring, data: rawptr, len: c.uint) -> c.int ---
}

// blob.h:46-50
BLOB_ATTR_ID_MASK  :: 0x7f00_0000
BLOB_ATTR_ID_SHIFT :: 24
BLOB_ATTR_LEN_MASK :: 0x00ff_ffff
BLOB_ATTR_ALIGN    :: 4
BLOB_ATTR_EXTENDED :: 0x8000_0000

// blob.h:52-55
//
// struct blob_attr 的 `char data[]` 是柔性数组，Odin 里没法照抄（会多出一个指针
// 字段）。这里只保留头部 4 字节，payload 一律靠 blob_data + 指针算术取，正好与
// C 的布局一致。
Blob_Attr :: struct #packed {
	id_len: u32,
}
#assert(size_of(Blob_Attr) == 4)

// blob.h:64-69：{ ^blob_attr head; bool(*grow)(..); int buflen; void *buf }
// aarch64 上 8 + 8 + 4(+4 pad) + 8 = 32。工具链用错误布局的代价是静默写坏内存，
// 所以拿 #assert 钉住。
Blob_Buf :: struct {
	head:   ^Blob_Attr,
	grow:   proc "c" (buf: ^Blob_Buf, minlen: c.int) -> bool,
	buflen: c.int,
	buf:    rawptr,
}
#assert(size_of(Blob_Buf) == 32)

// utils.h:146-212 的 be16_to_cpu / be32_to_cpu（little-endian 分支就是字节反转）
@(private)
be16_to_cpu :: proc "contextless" (x: u16) -> u16 {
	return (x >> 8) | (x << 8)
}

@(private)
be32_to_cpu :: proc "contextless" (x: u32) -> u32 {
	return (x >> 24) | ((x >> 8) & 0xff00) | ((x << 8) & 0x00ff_0000) | (x << 24)
}

// blobmsg_add_u32 要用（cpu_to_be32 在 LE 上与 be32_to_cpu 是同一个操作）
@(private)
cpu_to_be32 :: proc "contextless" (x: u32) -> u32 {
	return be32_to_cpu(x)
}

// ---------------------------------------------------------------------------
// 以下是 blob.h 的 static inline 复刻（行号对应 sysroot 头文件）
// ---------------------------------------------------------------------------

// blob.h:74-78
blob_data :: proc "contextless" (attr: ^Blob_Attr) -> rawptr {
	return rawptr(uintptr(attr) + size_of(Blob_Attr))
}

// blob.h:83-88
blob_id :: proc "contextless" (attr: ^Blob_Attr) -> u32 {
	return (be32_to_cpu(attr.id_len) & BLOB_ATTR_ID_MASK) >> BLOB_ATTR_ID_SHIFT
}

// blob.h:90-94
// 注意不能写成 `attr.id_len & BLOB_ATTR_EXTENDED`：C 那边是
// `attr->id_len & cpu_to_be32(BLOB_ATTR_EXTENDED)`，u32 在内存里已是大端，
// 直接拿本机序的位去比较是错的。先 be32_to_cpu 再比才是等价的。
blob_is_extended :: proc "contextless" (attr: ^Blob_Attr) -> bool {
	return (be32_to_cpu(attr.id_len) & BLOB_ATTR_EXTENDED) != 0
}

// blob.h:99-103。畸形 blob 会让 u32 下溢，C 里靠无符号回绕兜住；Odin 的整数
// 运算同样回绕（不做溢出检查），行为一致。
blob_len :: proc "contextless" (attr: ^Blob_Attr) -> uint {
	return uint((be32_to_cpu(attr.id_len) & BLOB_ATTR_LEN_MASK) - size_of(Blob_Attr))
}

// blob.h:108-112
blob_raw_len :: proc "contextless" (attr: ^Blob_Attr) -> uint {
	return blob_len(attr) + size_of(Blob_Attr)
}

// blob.h:117-123
blob_pad_len :: proc "contextless" (attr: ^Blob_Attr) -> uint {
	return (blob_raw_len(attr) + BLOB_ATTR_ALIGN - 1) & ~uint(BLOB_ATTR_ALIGN - 1)
}

// blob.h:184-188
//
// `^T(x)` 在 Odin 里被解析成「类型 + 调用」，所以指针 cast 必须写成 `(^T)(x)`。
blob_next :: proc "contextless" (attr: ^Blob_Attr) -> ^Blob_Attr {
	return (^Blob_Attr)(rawptr(uintptr(attr) + uintptr(blob_pad_len(attr))))
}

// ---------------------------------------------------------------------------
// 迭代器：blob_for_each_attr / __blob_for_each_attr / blobmsg_for_each_attr
// 三个宏的等价物。
//
// 上游宏是「三条件 + 两步进」：
//   for (rem = attr ? blob_len(attr) : 0, pos = attr ? blob_data(attr) : NULL;
//        rem >= sizeof(struct blob_attr) && blob_pad_len(pos) <= rem
//                                     && blob_pad_len(pos) >= sizeof(struct blob_attr);
//        rem -= blob_pad_len(pos), pos = blob_next(pos))
// __blob_for_each_attr 只少了「初值那一步」（起点与长度由调用方给）。
//
// 这里把「初值 / 条件 / 步进」拆成三个小 proc，调用点就能写成正常的 for，
// 不必手写步进——那是这类代码最容易错的地方。
// ---------------------------------------------------------------------------

Blob_Iter :: struct {
	pos: ^Blob_Attr,
	rem: uint,
}

// 对应 blob_for_each_attr / blobmsg_for_each_attr：attr 是**容器**（不是它的 payload）
blob_iter :: proc "contextless" (attr: ^Blob_Attr) -> Blob_Iter {
	if attr == nil {
		return {}
	}
	return {(^Blob_Attr)(blob_data(attr)), blob_len(attr)}
}

// 对应 __blob_for_each_attr：起点与长度由调用方给（例如对 blobmsg_data 的结果）
blob_iter_data :: proc "contextless" (data: rawptr, len: uint) -> Blob_Iter {
	return {(^Blob_Attr)(data), len}
}

blob_iter_ok :: proc "contextless" (it: Blob_Iter) -> bool {
	if it.rem < size_of(Blob_Attr) {
		return false
	}
	pad := blob_pad_len(it.pos)
	return pad <= it.rem && pad >= size_of(Blob_Attr)
}

blob_iter_next :: proc "contextless" (it: Blob_Iter) -> Blob_Iter {
	return {blob_next(it.pos), it.rem - blob_pad_len(it.pos)}
}