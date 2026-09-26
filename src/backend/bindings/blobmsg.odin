#+build linux
package bindings

// libubox 的 blobmsg 绑定 + libblobmsg_json 的 JSON 互转。
//
// 与 blob.odin 一样，static inline 的部分必须自己复刻（.so 里没有符号）；
// 真正的函数调用（blobmsg_add_field / blobmsg_open_nested / blobmsg_parse /
// blobmsg_format_json_with_cb / blobmsg_add_json_from_string）走 foreign。
//
// 布局（权威：blobmsg.c:240-270 的 blobmsg_new）：
//   +0        u32  id_len（大端）：bit31=EXTENDED | bits24..30=类型 | bits0..23=raw_len
//   +4        u16  namelen（大端）
//   +6        char name[namelen] + NUL + 零填充到 4 字节
//   +hdrlen   值（payload），hdrlen = blobmsg_hdrlen(namelen) = (2+namelen+1) & ~3
// 也就是**名字在值之前**。blobmsg_data 仅在该 attr 是 extended 时跳过这段头部。
//
// 与 blob.odin 同理，全部标成 `proc "contextless"`，否则没法在 ubus 的
// `proc "c"` 回调里调用。

import "core:c"

foreign import ubox "system:ubox"
foreign import blobmsg_json "system:blobmsg_json"

foreign ubox {
	blobmsg_parse :: proc(policy: ^Blobmsg_Policy, policy_len: c.int, tb: [^]^Blob_Attr, data: rawptr, len: c.uint) -> c.int ---
}

foreign blobmsg_json {
	blobmsg_add_json_from_string :: proc(buf: ^Blob_Buf, str: cstring) -> bool ---
	// 需要 libblobmsg_json（SONAME libblobmsg_json.so.20260213），不在 libubox 里。
	blobmsg_format_json_with_cb :: proc(attr: ^Blob_Attr, list: bool, cb: rawptr, priv: rawptr, indent: c.int) -> cstring ---
}

// blobmsg.h:22。注意上游是 `(len + 4 - 1) & ~3`，**不是**名字里的 2——那个 2 是
// 「1 << BLOBMSG_ALIGN」。复刻时别把 2 当成对齐字节数。
BLOBMSG_ALIGN :: 2

// blobmsg.h:25-39
BLOBMSG_TYPE_UNSPEC :: 0
BLOBMSG_TYPE_ARRAY  :: 1
BLOBMSG_TYPE_TABLE  :: 2
BLOBMSG_TYPE_STRING :: 3
BLOBMSG_TYPE_INT64  :: 4
BLOBMSG_TYPE_INT32  :: 5
BLOBMSG_TYPE_INT16  :: 6
BLOBMSG_TYPE_INT8   :: 7
// 头文件里 BOOL 只是 INT8 的别名，**不是**独立取值；上游的类型映射表也据此把
// INT8 翻译成 "boolean"。别在 switch 里当成两个 case。
BLOBMSG_TYPE_BOOL   :: BLOBMSG_TYPE_INT8
BLOBMSG_TYPE_DOUBLE :: 8
BLOBMSG_TYPE_LAST   :: 8

// blobmsg.h:41-44
//
// 同样是柔性数组（uint8_t name[]），只保留 namelen；名字靠指针算术取。
Blobmsg_Hdr :: struct #packed {
	namelen: u16,
}
#assert(size_of(Blobmsg_Hdr) == 2)

// blobmsg.h:46-49：{ const char *name; enum blobmsg_type type }
Blobmsg_Policy :: struct {
	name:      cstring,
	type_code: c.int,
}
#assert(size_of(Blobmsg_Policy) == 16)

// ---------------------------------------------------------------------------
// blobmsg.h 的 static inline 复刻
// ---------------------------------------------------------------------------

// blobmsg.h:56-59：BLOBMSG_PADDING(sizeof(struct blobmsg_hdr) + namelen + 1)
blobmsg_hdrlen :: proc "contextless" (namelen: uint) -> uint {
	return (uint(size_of(Blobmsg_Hdr)) + namelen + 1 + (1 << BLOBMSG_ALIGN) - 1) & ~uint((1 << BLOBMSG_ALIGN) - 1)
}

// blobmsg.h:77-80
blobmsg_namelen :: proc "contextless" (hdr: ^Blobmsg_Hdr) -> u16 {
	return be16_to_cpu(hdr.namelen)
}

// blobmsg.h:66-70：`return (const char *)(hdr + 1)`，即紧跟 blobmsg_hdr 之后
blobmsg_name :: proc "contextless" (attr: ^Blob_Attr) -> cstring {
	return cstring(rawptr(uintptr(blob_data(attr)) + size_of(Blobmsg_Hdr)))
}

// blobmsg.h:72-75
blobmsg_type :: proc "contextless" (attr: ^Blob_Attr) -> u32 {
	return blob_id(attr)
}

// blobmsg.h:82-95
blobmsg_data :: proc "contextless" (attr: ^Blob_Attr) -> rawptr {
	if attr == nil {
		return nil
	}
	if blob_is_extended(attr) {
		hdr := cast(^Blobmsg_Hdr)blob_data(attr)
		return rawptr(uintptr(blob_data(attr)) + uintptr(blobmsg_hdrlen(uint(blobmsg_namelen(hdr)))))
	}
	return blob_data(attr)
}

// blobmsg.h:97-106。C 里 (end - start) 是 ptrdiff_t，与 size_t 的减法走隐式转换；
// Odin 必须显式转成 uint，且要先把两个 uintptr 相减再转。
blobmsg_data_len :: proc "contextless" (attr: ^Blob_Attr) -> uint {
	if attr == nil {
		return 0
	}
	start := uintptr(blob_data(attr))
	end := uintptr(blobmsg_data(attr))
	return blob_len(attr) - uint(end - start)
}

// blobmsg.h:293-296
blobmsg_get_u32 :: proc "contextless" (attr: ^Blob_Attr) -> u32 {
	return be32_to_cpu((cast(^u32)blobmsg_data(attr))^)
}

// blobmsg.h:368-374
blobmsg_get_string :: proc "contextless" (attr: ^Blob_Attr) -> cstring {
	if attr == nil {
		return nil
	}
	return cstring(blobmsg_data(attr))
}

// blobmsg.h:249-259
blobmsg_open_array :: proc "contextless" (buf: ^Blob_Buf, name: cstring) -> rawptr {
	return blobmsg_open_nested(buf, name, true)
}

blobmsg_open_table :: proc "contextless" (buf: ^Blob_Buf, name: cstring) -> rawptr {
	return blobmsg_open_nested(buf, name, false)
}

// blobmsg.h:261-271（都落到 blob_nest_end）
blobmsg_close_array :: proc "contextless" (buf: ^Blob_Buf, cookie: rawptr) {
	blob_nest_end(buf, cookie)
}

blobmsg_close_table :: proc "contextless" (buf: ^Blob_Buf, cookie: rawptr) {
	blob_nest_end(buf, cookie)
}

// blobmsg.h:273-276
blobmsg_buf_init :: proc "contextless" (buf: ^Blob_Buf) -> c.int {
	return blob_buf_init(buf, BLOBMSG_TYPE_TABLE)
}

// blobmsg.h:234-238。strlen(string)+1，与上游一致（长度含结尾 NUL）。
blobmsg_add_string :: proc "contextless" (buf: ^Blob_Buf, name: cstring, str: cstring) -> c.int {
	return blobmsg_add_field(buf, BLOBMSG_TYPE_STRING, name, rawptr(str), c.uint(len(str)) + 1)
}

// blobmsg.h:220-225（值要转大端）
blobmsg_add_u32 :: proc "contextless" (buf: ^Blob_Buf, name: cstring, val: u32) -> c.int {
	be := cpu_to_be32(val)
	return blobmsg_add_field(buf, BLOBMSG_TYPE_INT32, name, rawptr(&be), 4)
}

// blobmsg.h:240-245：把 attr 的名字/payload 原样搬进 buf（名字、类型都保留）
blobmsg_add_blob :: proc "contextless" (buf: ^Blob_Buf, attr: ^Blob_Attr) -> c.int {
	return blobmsg_add_field(buf, c.int(blobmsg_type(attr)), blobmsg_name(attr), blobmsg_data(attr), c.uint(blobmsg_data_len(attr)))
}

// blobmsg_json.h:35-38 的 inline
//   blobmsg_format_json(attr, list)
//     == blobmsg_format_json_with_cb(attr, list, NULL, NULL, -1)
// 返回值是 **malloc 内存，调用方必须 c_free**（见 libc.odin）。
blobmsg_format_json :: proc "contextless" (attr: ^Blob_Attr, list: bool) -> cstring {
	return blobmsg_format_json_with_cb(attr, list, nil, nil, -1)
}