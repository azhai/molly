package bindings

// molly_* C 原生层的 Odin 绑定（阶段 1）。
//
// 边界（已确认的决策）：blob/ubus服务端(uloop+回调)/uci/netlink/iwinfo 全部留在
// src/native/shim.c（1400+ 行、已在设备验证的可移植 C）。Odin 只在此声明它导出的
// C ABI，并在上层用 core:encoding/json 解析返回的 JSON 文本。
//
// C ABI 映射约定（arm64/musl）：
//   C int            -> i32
//   C unsigned int   -> u32
//   struct *_ / void* 不透明指针 -> rawptr（ubus_context / molly_uci_txn / blob_attr）
//   const char* 入参  -> cstring（可直接传字符串字面量；可为 nil）
//   char* 返回(malloc)-> cstring（调用方转 string 后用 molly_free 释放）
//   char** 出参        -> ^cstring（调用方传 &s，s: cstring；C 侧 malloc 写入）
//
// 为什么用 `foreign import shim "system:shim"` 却不真走系统链接：交叉构建是两段式
// （odin -build-mode:obj 只编不链，zig cc 收尾把 shim.o + -luci/-lubus/... 链上）。
// obj 模式下这条 `system:` 声明是惰性的，仅用于给 foreign 块注册库名。

foreign import shim "system:shim"

foreign shim {
	// ---- 内存 ----
	// 释放任何 molly_* 返回的 malloc 串/缓冲（传 rawptr(cstring)）。
	molly_free :: proc(p: rawptr) ---

	// ---- blobmsg ⇄ JSON ----
	// 一条 ubus 消息的**子项**格式化成 JSON 对象文本；msg 为 nil 返回 nil。malloc 串。
	molly_blobmsg_to_json :: proc(msg: rawptr) -> cstring ---

	// ---- ubus 客户端（list / call）----
	// path == nil 用库内默认 socket。失败返回 nil。
	molly_ubus_connect :: proc(path: cstring) -> rawptr ---
	molly_ubus_free    :: proc(ctx: rawptr) ---

	// GET /ubus/list[/<path>]。*out 收 malloc 串。返回 ubus 状态码（0 成功）。
	molly_ubus_lookup    :: proc(ctx: rawptr, path: cstring, out: ^cstring) -> i32 ---
	molly_ubus_lookup_id :: proc(ctx: rawptr, path: cstring, out_id: ^u32) -> i32 ---

	// 同步 invoke。params_json/sid 可为 nil；成功且有回复数据时 *out 收 malloc 串。
	molly_ubus_invoke :: proc(
		ctx: rawptr,
		id: u32,
		method, params_json, sid: cstring,
		timeout_ms: i32,
		out: ^cstring,
	) -> i32 ---

	// ---- ubus 服务端（注册 molly 自有对象；独立线程跑 uloop）----
	// 成功返回 0；连不上 ubusd / 建线程失败返回非 0。
	molly_ubus_start_server :: proc(socket_path: cstring) -> i32 ---
	molly_ubus_stop_server  :: proc() ---

	// ---- uci（读）----
	// 一个 config 的全部 section（JSON）。savedir 为空用默认 delta 目录。
	molly_uci_sections     :: proc(config, savedir: cstring, out: ^cstring) -> i32 ---
	molly_uci_list_configs :: proc(out: ^cstring) -> i32 ---
	// 一个 config 的 delta（该会话 savedir 下未提交改动，JSON 数组）。
	molly_uci_delta :: proc(sid, config: cstring, out: ^cstring) -> i32 ---

	// ---- uci 写事务（一次方法调用 = load → 改 → save）----
	// 事务期间 libuci 的 ctx/pkg 被独占；上层用一把锁保证同时只有一件事务。
	molly_uci_txn_begin      :: proc(config, savedir: cstring, status: ^i32) -> rawptr --- // struct molly_uci_txn *
	molly_uci_txn_end        :: proc(txn: rawptr) ---
	molly_uci_txn_sections   :: proc(txn: rawptr) -> cstring ---
	molly_uci_txn_add_section :: proc(txn: rawptr, type_, name: cstring, out_name: ^cstring) -> i32 ---
	molly_uci_txn_section_exists :: proc(txn: rawptr, section: cstring) -> i32 ---
	molly_uci_txn_option_state :: proc(
		txn: rawptr,
		section, option: cstring,
		exists, is_list: ^i32,
		value: ^cstring,
	) -> i32 ---
	molly_uci_txn_delete :: proc(txn: rawptr, section, option: cstring) -> i32 ---
	molly_uci_txn_set    :: proc(txn: rawptr, section, option, value: cstring) -> i32 ---
	molly_uci_txn_add_list :: proc(txn: rawptr, section, option, value: cstring) -> i32 ---
	molly_uci_txn_rename   :: proc(txn: rawptr, section, option, new_name: cstring) -> i32 ---
	molly_uci_txn_reorder  :: proc(txn: rawptr, section: cstring, pos: i32) -> i32 ---
	molly_uci_txn_save     :: proc(txn: rawptr) -> i32 ---

	// ---- uci commit / revert / apply ----
	molly_uci_commit       :: proc(sid, config: cstring) -> i32 ---
	molly_uci_revert       :: proc(sid, config: cstring) -> i32 ---
	molly_uci_apply_config :: proc(config: cstring, no_delta: i32) -> i32 ---
	molly_reload_config    :: proc() -> i32 ---

	// ---- 子进程 spawn（file.exec / --luci-cgi / cgi-io / 改密码；绕开 core:os process_exec 的 SIGTRAP）----
	// argv/envp 以 nil 结尾（^cstring 指向首元素）；envp==nil 继承当前 environ。
	// stdin_data==nil 或 stdin_len<0 → /dev/null；capture_stderr!=0 → 收进 out_stderr，否则直通 molly fd 2。
	// out_stdout/out_stderr 收 malloc 缓冲（用 out_*_len 为准，二进制安全；用 molly_free 释放）。
	// out_exited：1 正常退出、0 被信号杀；out_code：退出码或信号号。返回 0=已起并回收，-1=未起。
	molly_spawn :: proc(
		argv, envp: ^cstring,
		stdin_data: ^u8,
		stdin_len, capture_stderr: i32,
		out_stdout: ^cstring, out_stdout_len: ^i32,
		out_stderr: ^cstring, out_stderr_len: ^i32,
		out_exited: ^i32, out_code: ^i32,
	) -> i32 ---

	// ---- libc ----
	// crypt(3) 比对：1 通过 / 0 不通过。
	molly_verify_password :: proc(hash, password: cstring) -> i32 ---

	// ---- luci-rpc 设备绑定（linux only；不碰 ubus，只读 sysfs/proc/netlink/dlopen）----
	molly_getifaddrs_json    :: proc(out: ^cstring) -> i32 ---
	molly_get_neighbors_json :: proc(out: ^cstring) -> i32 ---
	molly_iwinfo_json        :: proc(devname: cstring, phy_only: i32, out: ^cstring) -> i32 ---
}
