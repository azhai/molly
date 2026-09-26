#+build linux
package bindings

// libuci 绑定。布局与 procs 全部照搬 `spike/01-toolchain/src/main.odin`——
// 那一份已经在设备（aarch64 / musl / uci commit 66127cd7）上真跑通过，别改。
//
// P2 里 uci 只有一个用途：菜单的 `depends.uci` 存在性检查。真正的配置读写
// 仍走 rpcd 的 uci 对象转发给设备（计划决策 7）。
//
// 为什么 uci_ptr 必须显式对齐到 72 字节：Odin 的 enum 默认基类型是 int
// （64 位平台 8 字节），而 C 的 `enum uci_type` 是 4 字节；不写 `c.int`
// 整个结构体会移位，uci_lookup_ptr 会往错误偏移写值，且**不报错**。
// 老版本 uci 的 uci_ptr 以 target/package/section/option/value 开头，新版
// 把 p/s/o/last 提到了前面，按老布局写同样会静默写错位置——所以下面加了
// 编译期尺寸断言兜底。
//
// 权威来源：uci.h:362（enum uci_type）、uci.h:496（struct uci_ptr）。

import "core:c"

foreign import uci "system:uci"

// uci_context 当作不透明句柄：我们只拿指针传给 libuci，不读它的字段。
Uci_Context :: struct {}

// enum uci_type（uci.h:362）。基类型必须显式写 c.int。
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

// uci_ptr.flags 里的匿名 enum 位标志（uci.h:496 起）。
UCI_LOOKUP_DONE     :: 1 << 0
UCI_LOOKUP_COMPLETE :: 1 << 1
UCI_LOOKUP_EXTENDED :: 1 << 2

// ---------------------------------------------------------------------------
// section / option 的遍历（uci.h:59-70、:386-470 的公开结构体）
//
// `depends.uci` 要回答「config 有没有 section」「section 的 option 是什么」，
// libuci 没有现成的单个 API，官方做法就是拿着这些结构体遍历——`uci_foreach_element`
// 与 `uci_to_section/option` 都是 uci.h 里的公开宏（:552、:621-622）。这里把宏
// 的语义照抄成 proc：list 是环形哨兵表头，元素通过 `list` 成员串起来，而 `list`
// 是 `uci_element` 的第一个成员，所以元素地址 == list 地址。
// ---------------------------------------------------------------------------

// struct uci_list（uci.h:59）
Uci_List :: struct {
	next: ^Uci_List,
	prev: ^Uci_List,
}

// struct uci_element（uci.h:386）：list(16) + type(4) + pad(4) + name(8) = 32
Uci_Element :: struct {
	list: Uci_List,
	type: Uci_Type,
	name: cstring,
}

// struct uci_package（uci.h:436）：e(32) + sections(16) + ctx(8) + 两个 bool(2+6) +
// path(8) + backend(8) + priv(8) + n_section(4+4) + delta(16) + saved_delta(16) = 128
Uci_Package :: struct {
	e:           Uci_Element,
	sections:    Uci_List,
	ctx:         ^Uci_Context,
	has_delta:   bool,
	uses_conf2:  bool,
	path:        cstring,
	backend:     rawptr,
	priv:        rawptr,
	n_section:   c.int,
	delta:       Uci_List,
	saved_delta: Uci_List,
}

// struct uci_section（uci.h:452）：e(32) + options(16) + package(8) + anonymous(1+7) + type(8) = 72
// （字段名只能用别名：package 是 Odin 关键字）
Uci_Section :: struct {
	e:         Uci_Element,
	options:   Uci_List,
	pkg:       ^Uci_Package,
	anonymous: bool,
	type_name: cstring,
}

// enum uci_option_type（uci.h:374）
Uci_Option_Type :: enum c.int {
	String = 0,
	List   = 1,
}

// struct uci_option（uci.h:461）：e(32) + section(8) + type(4+4) + v(16) = 64
Uci_Option :: struct {
	e:       Uci_Element,
	section: ^Uci_Section,
	type:    Uci_Option_Type,
	_pad:    u32,
	v:       struct #raw_union {
		list:   Uci_List,
		string: cstring,
	},
}

#assert(size_of(Uci_List) == 16, "Uci_List 必须与 C 的 uci_list 同为 16 字节")
#assert(size_of(Uci_Element) == 32, "Uci_Element 必须与 C 的 uci_element 同为 32 字节")
#assert(size_of(Uci_Package) == 128, "Uci_Package 必须与 C 的 uci_package 同为 128 字节")
#assert(size_of(Uci_Section) == 72, "Uci_Section 必须与 C 的 uci_section 同为 72 字节")
#assert(size_of(Uci_Option) == 64, "Uci_Option 必须与 C 的 uci_option 同为 64 字节")
#assert(offset_of(Uci_Section, options) == 32, "uci_foreach_element 依赖 options 的偏移")
#assert(offset_of(Uci_Option, v) == 48, "v 必须在 48 字节处")

// uci_foreach_element 的「第一个元素」（含哨兵判断）：表头自己就是链表尾。
uci_element_first :: proc "contextless" (head: ^Uci_List) -> ^Uci_Element {
	if head == nil || head.next == nil || head.next == head {
		return nil
	}
	return (^Uci_Element)(rawptr(head.next))
}

// uci_foreach_element 的「下一个元素」；走到哨兵表头就是 nil（循环结束）。
uci_element_next :: proc "contextless" (head: ^Uci_List, cur: ^Uci_Element) -> ^Uci_Element {
	next := cur.list.next
	if next == nil || next == head {
		return nil
	}
	return (^Uci_Element)(rawptr(next))
}

// cstring → string（nil 视为空串）。绑定层所有字符串出口都走它。
uci_cstr :: proc "contextless" (s: cstring) -> string {
	if s == nil {
		return ""
	}
	return string(s)
}

// struct uci_ptr（uci.h:496，commit 66127cd7）。字段名只能用别名：
// package / option / type / ptr 都是 Odin 关键字。结构体布局只按声明顺序
// 匹配 C，不校验字段名。
Uci_Ptr :: struct {
	target:  Uci_Type, // 0
	flags:   c.int,    // 4
	p:       ^Uci_Package, // 8
	s:       ^Uci_Section, // 16
	o:       ^Uci_Option, // 24
	last:    ^Uci_Element, // 32
	pkg:     cstring, // 40  C: package
	section: cstring, // 48
	opt:     cstring, // 56  C: option
	value:   cstring, // 64
}

#assert(size_of(Uci_Ptr) == 72, "Uci_Ptr 必须与 C 的 uci_ptr 同为 72 字节")

// ---------------------------------------------------------------------------
// delta（uci.h:475-494）
//
// `changes` 要枚举 `p->saved_delta`（rpcd uci.c:1250-1251、:1285-1286），
// 所以需要这两个结构体。注意 enum uci_command 的**顺序**与 rpcd 的 types[] 无关：
// 那边用的是指定初始化器（`[UCI_CMD_REORDER] = "order"`），这里按名字对齐。
// ---------------------------------------------------------------------------

// enum uci_command（uci.h:475）：ADD=0 REMOVE=1 CHANGE=2 RENAME=3 REORDER=4
// LIST_ADD=5 LIST_DEL=6
Uci_Cmd :: enum c.int {
	Add      = 0,
	Remove   = 1,
	Change   = 2,
	Rename   = 3,
	Reorder  = 4,
	List_Add = 5,
	List_Del = 6,
}

// struct uci_delta（uci.h:488）：e(32) + cmd(4) + pad(4) + section(8) + value(8) = 56
Uci_Delta :: struct {
	e:       Uci_Element,
	cmd:     Uci_Cmd,
	_pad:    u32,
	section: cstring,
	value:   cstring,
}

#assert(size_of(Uci_Delta) == 56, "Uci_Delta 必须与 C 的 uci_delta 同为 56 字节")
#assert(offset_of(Uci_Delta, cmd) == 32, "cmd 必须在 32 字节处")
#assert(offset_of(Uci_Delta, section) == 40, "section 必须在 40 字节处")
#assert(offset_of(Uci_Package, saved_delta) == 112, "saved_delta 必须在 112 字节处（uci.h:436-450）")

@(default_calling_convention = "c")
foreign uci {
	uci_alloc_context :: proc() -> ^Uci_Context ---
	uci_free_context  :: proc(ctx: ^Uci_Context) ---
	uci_load          :: proc(ctx: ^Uci_Context, name: cstring, pkg: ^^Uci_Package) -> c.int ---
	uci_lookup_ptr    :: proc(ctx: ^Uci_Context, out_ptr: ^Uci_Ptr, str: cstring, extended: bool) -> c.int ---
	uci_perror        :: proc(ctx: ^Uci_Context, str: cstring) ---
	// int uci_list_configs(struct uci_context *ctx, char ***list)
	// 成功时 *list 指向 malloc 的、以 NULL 结尾的字符串数组（元素也是 malloc）。
	// 释放用下面的 uci_free_configs（上游 rpcd 只 free 了数组本身，元素是漏的）。
	uci_list_configs  :: proc(ctx: ^Uci_Context, list: ^[^]cstring) -> c.int ---
	uci_unload        :: proc(ctx: ^Uci_Context, p: ^Uci_Package) -> c.int ---
	// bool overwrite：true = 覆盖现有配置并清掉 delta（uci.h:235-243）
	uci_commit        :: proc(ctx: ^Uci_Context, p: ^^Uci_Package, overwrite: bool) -> c.int ---
	uci_revert        :: proc(ctx: ^Uci_Context, ptr: ^Uci_Ptr) -> c.int ---
	// 覆盖默认的 delta 保存目录（uci.h:254-260）；pkg 目录由 uci_add_delta_path 追加
	uci_set_savedir   :: proc(ctx: ^Uci_Context, dir: cstring) -> c.int ---
	uci_add_delta_path :: proc(ctx: ^Uci_Context, dir: cstring) -> c.int ---

	// --- 写操作（P3-3 S3；签名见 uci.h:167-232）---
	// 全部走 uci_ptr：字段填好后调用，libuci 自己决定是改内存还是落盘。
	uci_set         :: proc(ctx: ^Uci_Context, ptr: ^Uci_Ptr) -> c.int ---
	uci_delete      :: proc(ctx: ^Uci_Context, ptr: ^Uci_Ptr) -> c.int ---
	uci_rename      :: proc(ctx: ^Uci_Context, ptr: ^Uci_Ptr) -> c.int ---
	uci_add_list    :: proc(ctx: ^Uci_Context, ptr: ^Uci_Ptr) -> c.int ---
	uci_del_list    :: proc(ctx: ^Uci_Context, ptr: ^Uci_Ptr) -> c.int ---
	// 建一个匿名 section（具名 section 用 uci_set + ptr.value=type，见 uci.c:713-722）
	uci_add_section :: proc(ctx: ^Uci_Context, p: ^Uci_Package, type_name: cstring, res: ^^Uci_Section) -> c.int ---
	// 把内存里的改动写进 savedir 里的 delta 文件（不碰 /etc/config，那要 uci_commit）
	uci_save        :: proc(ctx: ^Uci_Context, p: ^Uci_Package) -> c.int ---
	// 重新排 position（uci.h:205-211）；rpcd 忽略返回值
	uci_reorder_section :: proc(ctx: ^Uci_Context, sec: ^Uci_Section, pos: c.int) -> c.int ---
}

// 释放 uci_list_configs 的返回值：先逐个字符串，再数组本身。
uci_free_configs :: proc "contextless" (list: [^]cstring) {
	if list == nil {
		return
	}
	for i := 0; list[i] != nil; i += 1 {
		c_free(rawptr(list[i]))
	}
	c_free(rawptr(list))
}