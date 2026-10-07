//go:build darwin

package backend

import "encoding/json"

// uci 对象的 darwin 平台钩子（对齐 Odin 版 src/backend/darwin.odin 里 P3-3 那一段）。
//
// darwin 的 uci 是**只读假数据**：config/section 来自同包的 fakeUCI（uciConfigSections），
// changes 对 network 回一份固定假 delta，其它已知 config 回空数组、未知 config 回 4；
// state/commit/revert/写路径/apply/reload 一律回 StatusNotSupported(8)。
//
// 注意方法层的**参数校验与 ACL 检查在 provider 之前**，所以 darwin 上仍然能断言 2
// （缺参/非法名）与 6（没权限），校验通过之后才落到这里回 8。

// uciWriteTxn 是 linux 侧写事务的句柄；darwin 不实现写路径，仅为满足方法层的类型引用。
type uciWriteTxn struct {
	unused byte
}

// uciProviderConfigs：设备上是 /etc/config/* 的字母序列表，这里是假配置表的名字。
func uciProviderConfigs() ([]string, bool) {
	out := make([]string, 0, len(fakeUCI))
	for _, c := range fakeUCI {
		out = append(out, c.name)
	}
	return out, true
}

// uciProviderSections 复用 session.go 也在用的那份假数据源。
func uciProviderSections(config string) ([]UciSection, bool) {
	return uciConfigSections(config)
}

// uciProviderStateSections：`state` 要读「已提交态」（/var/state），darwin 没有这个目录。
func uciProviderStateSections(config string) ([]UciSection, int) {
	return nil, StatusNotSupported
}

// uciProviderSavedir：假数据没有 delta 目录可切，空实现（返回 true 让读路径照常跑）。
func uciProviderSavedir(sid string) bool {
	return true
}

// uciFakeDelta 只有 network 有（与 uciConfigSections 对得上）；最后一条 section 为空，
// 用来钉住「上游整条丢掉」（uci.c:1202-1203）这个行为。
var uciFakeDelta = []uciChange{
	{kind: uciChangeChange, section: "lan", name: "ipaddr", value: "10.0.0.1"},
	{kind: uciChangeListAdd, section: "lan", name: "dns", value: "9.9.9.9"},
	{kind: uciChangeRemove, section: "wan", name: "proto"},
	{kind: uciChangeReorder, section: "lan", value: "3"},
	{kind: uciChangeAdd, section: "wg1"},
	{kind: uciChangeChange, name: "ignored"},
}

// uciProviderDelta 对应 Odin darwin.odin 的 uci_delta_changes：只有 network 有假 delta；
// 其它已知 config 回空数组；未知 config 回 4（linux 侧 uci_load 失败 → uci.c:1244-1245）。
func uciProviderDelta(sid, config string) ([]uciChange, int) {
	known := false
	for _, c := range fakeUCI {
		if c.name == config {
			known = true
			break
		}
	}
	if !known {
		return nil, StatusNotFound
	}
	if config != "network" {
		return nil, StatusOK
	}
	return uciFakeDelta, StatusOK
}

// ---------------------------------------------------------------------------
// 写事务：darwin **不实现**（按决策，写路径只在 linux 上实现），一律 8。
// ---------------------------------------------------------------------------

func uciProviderWriteBegin(sid, config string) (*uciWriteTxn, int) {
	return nil, StatusNotSupported
}

func uciProviderWriteEnd(txn *uciWriteTxn) {}

func uciProviderWriteSections(txn *uciWriteTxn) ([]UciSection, int) {
	return nil, StatusNotSupported
}

func uciProviderWriteAddSection(txn *uciWriteTxn, typeName, name string) (string, int) {
	return "", StatusNotSupported
}

func uciProviderWriteMergeSet(txn *uciWriteTxn, section, option string, value json.RawMessage) int {
	return StatusNotSupported
}

func uciProviderWriteAddValue(txn *uciWriteTxn, section, option string, value json.RawMessage) int {
	return StatusNotSupported
}

func uciProviderWriteSave(txn *uciWriteTxn) int {
	return StatusNotSupported
}

func uciProviderWriteDelete(txn *uciWriteTxn, section string, form uciDeleteForm, names []string) int {
	return StatusNotSupported
}

func uciProviderWriteRename(txn *uciWriteTxn, section, option, newName string) int {
	return StatusNotSupported
}

// uciProviderWriteReorder 返回「找到了吗」——darwin 上没有实现，永远 false（调用方据此回 4）。
func uciProviderWriteReorder(txn *uciWriteTxn, section string, pos int) bool {
	return false
}

// ---------------------------------------------------------------------------
// apply 系：提交要走 libuci、reload 要 fork/exec，darwin 都不做 → 8。
// ---------------------------------------------------------------------------

func uciProviderApplyConfig(config string, noDelta bool) int {
	return StatusNotSupported
}

func uciProviderReloadConfig() int {
	return StatusNotSupported
}

func uciProviderCommit(sid, config string) int {
	return StatusNotSupported
}

func uciProviderRevert(sid, config string) int {
	return StatusNotSupported
}
