package backend

// uci_provider_darwin —— uci 对象的宿主（darwin 语义）平台实现（对齐 internal/backend/uci_darwin.go）。
// 文件名后缀 _darwin 让 Odin 只在 darwin 目标编本文件；设备上（linux）那份真 libuci 实现见
// uci_provider_linux.odin（同名同签名，靠平台文件名互斥，不会重复定义）。
//
// 宿主的 uci 是**只读假数据**：config/section 复用 session 也在用的 hook_uci_sections；
// changes 对 network 回一份固定假 delta，其它已知 config 回空数组、未知 config 回 4；
// state / commit / revert / 写事务 / apply / reload 一律回 Status_Not_Supported(8)。
//
// 注意方法层的**参数校验与 ACL 在 provider 之前**，所以宿主上仍能断言 2（缺参/非法名）
// 与 6（没权限），校验通过之后才落到这里回 8。
//
// 本文件是宿主的 uci provider：假数据读路径 + 写路径一律 8（写/apply 只在 linux 实现）。

import "core:mem"
import "core:encoding/json"

// Uci_Write_Txn 是 linux 侧写事务的句柄；宿主不实现写路径，仅为满足方法层的类型引用。
Uci_Write_Txn :: struct { unused: u8 }

// 宿主已知的配置名（与 hook_uci_sections 支持的集合一致）。
_host_config_names := []string{"network", "system", "rpcd", "dhcp", "empty-config"}

// 假 delta（只有 network 有）；最后一条 section 为空，用来钉住「上游整条丢掉」的行为。
_host_uci_delta := []Uci_Change{
	{kind = .Change, section = "lan", name = "ipaddr", value = "10.0.0.1"},
	{kind = .List_Add, section = "lan", name = "dns", value = "9.9.9.9"},
	{kind = .Remove, section = "wan", name = "proto"},
	{kind = .Reorder, section = "lan", value = "3"},
	{kind = .Add, section = "wg1"},
	{kind = .Change, name = "ignored"},
}

uci_host_known :: proc(config: string) -> bool {
	_, ok := hook_uci_sections(config, store_alloc)
	return ok
}

// uci_provider_configs —— 设备上是 /etc/config/* 的字母序，这里是假配置表的名字。
uci_provider_configs :: proc() -> (names: []string, ok: bool) {
	out := make([]string, len(_host_config_names), context.allocator)
	copy(out, _host_config_names)
	return out, true
}

// uci_provider_sections —— 复用假数据源。
uci_provider_sections :: proc(config: string) -> ([]Uci_Section, bool) {
	return hook_uci_sections(config, store_alloc)
}

// uci_provider_state_sections —— `state` 要读「已提交态」（/var/state），宿主没有。
uci_provider_state_sections :: proc(config: string) -> (sections: []Uci_Section, status: i32) {
	_ = config
	return nil, Status_Not_Supported
}

// uci_provider_savedir —— 假数据没有 delta 目录可切，恒真（让读路径照常跑）。
uci_provider_savedir :: proc(sid: string) -> bool {
	_ = sid
	return true
}

// uci_provider_delta —— 只有 network 有假 delta；其它已知 config 回空数组；未知 config 回 4。
uci_provider_delta :: proc(sid, config: string) -> (changes: []Uci_Change, status: i32) {
	_ = sid
	if !uci_host_known(config) {
		return nil, Status_Not_Found
	}
	if config != "network" {
		return nil, Status_OK
	}
	out := make([]Uci_Change, len(_host_uci_delta), context.allocator)
	copy(out, _host_uci_delta)
	return out, Status_OK
}

// ---------------------------------------------------------------------------
// 写事务：宿主**不实现**（按决策，写路径只在 linux 上实现），一律 8。
// ---------------------------------------------------------------------------

uci_provider_write_begin :: proc(sid, config: string) -> (^Uci_Write_Txn, i32) {
	_ = sid; _ = config
	return nil, Status_Not_Supported
}

uci_provider_write_end :: proc(txn: ^Uci_Write_Txn) { _ = txn }

uci_provider_write_sections :: proc(txn: ^Uci_Write_Txn) -> ([]Uci_Section, i32) {
	_ = txn
	return nil, Status_Not_Supported
}

uci_provider_write_add_section :: proc(txn: ^Uci_Write_Txn, type_name, name: string) -> (string, i32) {
	_ = txn; _ = type_name; _ = name
	return "", Status_Not_Supported
}

uci_provider_write_merge_set :: proc(txn: ^Uci_Write_Txn, section, option: string, value: json.Value) -> i32 {
	_ = txn; _ = section; _ = option; _ = value
	return Status_Not_Supported
}

uci_provider_write_add_value :: proc(txn: ^Uci_Write_Txn, section, option: string, value: json.Value) -> i32 {
	_ = txn; _ = section; _ = option; _ = value
	return Status_Not_Supported
}

uci_provider_write_save :: proc(txn: ^Uci_Write_Txn) -> i32 {
	_ = txn
	return Status_Not_Supported
}

uci_provider_write_delete :: proc(txn: ^Uci_Write_Txn, section: string, form: Uci_Delete_Form, names: []string) -> i32 {
	_ = txn; _ = section; _ = form; _ = names
	return Status_Not_Supported
}

uci_provider_write_rename :: proc(txn: ^Uci_Write_Txn, section, option, new_name: string) -> i32 {
	_ = txn; _ = section; _ = option; _ = new_name
	return Status_Not_Supported
}

// uci_provider_write_reorder 返回「找到了吗」——宿主没有实现，永远 false（调用方据此回 4）。
uci_provider_write_reorder :: proc(txn: ^Uci_Write_Txn, section: string, pos: int) -> bool {
	_ = txn; _ = section; _ = pos
	return false
}

// ---------------------------------------------------------------------------
// apply 系：提交要走 libuci、reload 要 fork/exec，宿主都不做 → 8。
// ---------------------------------------------------------------------------

uci_provider_apply_config :: proc(config: string, no_delta: bool) -> i32 {
	_ = config; _ = no_delta
	return Status_Not_Supported
}

uci_provider_reload_config :: proc() -> i32 { return Status_Not_Supported }

uci_provider_commit :: proc(sid, config: string) -> i32 {
	_ = sid; _ = config
	return Status_Not_Supported
}

uci_provider_revert :: proc(sid, config: string) -> i32 {
	_ = sid; _ = config
	return Status_Not_Supported
}
