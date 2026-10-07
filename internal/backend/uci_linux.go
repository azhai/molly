//go:build linux

package backend

import (
	"encoding/json"
	"sync"

	"github.com/azhai/molly/internal/cbind"
)

// uci 对象的 linux 平台钩子 —— 真 libuci（uci_load / uci_set / uci_commit …）与
// /sbin/reload_config 的 fork/exec，全部经 internal/cbind 调 C。
//
// 与 uci_darwin.go **同名同签名**，签名漂移会在该平台的编译期暴露。
//
// 方法层的参数校验与 ACL 在 provider 之前，所以这里的返回值只覆盖「校验通过之后」的
// 失败（4 找不到 / 9 其它）；darwin 侧同位置一律回 8（按决策写路径只在 linux 实现）。
//
// 锁：libuci 不是线程安全的，且写事务是多步操作（中间不能让别的请求插进来）。
// HTTP 线程与 ubus 服务线程都可能进来，所以用一把包级 uciMu 串行化**所有** uci 调用；
// 写事务的锁由 Begin 拿到、End 释放（与 Odin 的 g_uci_lock 同义）。

var uciMu sync.Mutex

// uciStateSavedir 是 `state` 读「已提交态」时的 delta 目录（uci.c:619-620）。
const uciStateSavedir = "/var/state"

// uciSavedirOf 给出会话的 savedir：空 sid（内部调用）回 ""，让 cbind 用默认
// /tmp/.uci（与上游 rpc_uci_set_savedir 的 else 分支一致）。
func uciSavedirOf(sid string) string {
	if sid == "" {
		return ""
	}
	return uciSavedirPrefix + sid
}

// ---------------------------------------------------------------------------
// 读路径
// ---------------------------------------------------------------------------

// uciProviderConfigs：/etc/config/* 的字母序列表（uci.c:1390）。
func uciProviderConfigs() ([]string, bool) {
	uciMu.Lock()
	defer uciMu.Unlock()

	js, ret := cbind.UCIListConfigs()
	if ret != 0 {
		return nil, false
	}
	var names []string
	if err := json.Unmarshal([]byte(js), &names); err != nil {
		return nil, false
	}
	return names, true
}

// uciProviderSections：uci_load + section/option 遍历（libuci 的默认 delta 目录）。
func uciProviderSections(config string) ([]UciSection, bool) {
	uciMu.Lock()
	defer uciMu.Unlock()

	js, ret := cbind.UCISections(config, "")
	if ret != 0 {
		return nil, false
	}
	return uciDecodeSections(js)
}

// uciProviderStateSections：savedir 换成 /var/state 后 uci_load（读已提交态）。
func uciProviderStateSections(config string) ([]UciSection, int) {
	uciMu.Lock()
	defer uciMu.Unlock()

	js, ret := cbind.UCISections(config, uciStateSavedir)
	if ret != 0 {
		if ret == StatusNotFound {
			return nil, StatusNotFound
		}
		return nil, StatusUnknownError
	}
	sections, ok := uciDecodeSections(js)
	if !ok {
		return nil, StatusUnknownError
	}
	return sections, StatusOK
}

// uciProviderSavedir：savedir 由每个操作自己按 sid 建短命 context 承载，这里只报告
// 「能切」（linux.odin:1418-1420）。
func uciProviderSavedir(sid string) bool { return true }

// uciProviderDelta：枚举该 config 的 p->saved_delta（uci.c:1250-1251、:1285-1286）。
func uciProviderDelta(sid, config string) ([]uciChange, int) {
	uciMu.Lock()
	defer uciMu.Unlock()

	js, ret := cbind.UCIDelta(sid, config)
	if ret != 0 {
		return nil, ret
	}
	return uciDecodeDelta(js)
}

// ---------------------------------------------------------------------------
// 写事务
// ---------------------------------------------------------------------------

// uciWriteTxn 是一个写事务（uci_load 一次 → 改 → uci_save 一次）的句柄。
type uciWriteTxn struct {
	txn *cbind.Txn
}

// uciProviderWriteBegin：uci_load（配置 + 该会话 delta）。成功时一直持有 uciMu，
// 由 uciProviderWriteEnd 释放。
func uciProviderWriteBegin(sid, config string) (*uciWriteTxn, int) {
	uciMu.Lock()

	txn, status := cbind.TxnBegin(config, uciSavedirOf(sid))
	if status != 0 {
		uciMu.Unlock()
		return nil, status
	}
	return &uciWriteTxn{txn: txn}, StatusOK
}

func uciProviderWriteEnd(txn *uciWriteTxn) {
	if txn == nil {
		// begin 失败时方法层不会调到这里；防御性返回（不能重复解锁）。
		return
	}
	txn.txn.End()
	uciMu.Unlock()
}

func uciProviderWriteSections(txn *uciWriteTxn) ([]UciSection, int) {
	if txn == nil {
		return nil, StatusNotSupported
	}
	sections, ok := uciDecodeSections(txn.txn.Sections())
	if !ok {
		return nil, StatusUnknownError
	}
	return sections, StatusOK
}

func uciProviderWriteAddSection(txn *uciWriteTxn, typeName, name string) (string, int) {
	if txn == nil {
		return "", StatusNotSupported
	}
	return txn.txn.AddSection(typeName, name)
}

func uciProviderWriteMergeSet(txn *uciWriteTxn, section, option string, value json.RawMessage) int {
	if txn == nil {
		return StatusNotSupported
	}
	if !uciVerifyName(option) {
		return StatusInvalidArgument
	}
	if !txn.txn.SectionExists(section) {
		return StatusNotFound
	}
	exists, isList, val := txn.txn.OptionState(section, option)
	plan := uciPlanMergeSet(value, uciOptionState{exists: exists, isList: isList, value: val})
	return uciRunPlan(txn, section, option, plan)
}

func uciProviderWriteAddValue(txn *uciWriteTxn, section, option string, value json.RawMessage) int {
	if txn == nil {
		return StatusNotSupported
	}
	if !uciVerifyName(option) {
		return StatusInvalidArgument
	}
	if !txn.txn.SectionExists(section) {
		return StatusNotFound
	}
	return uciRunPlan(txn, section, option, uciPlanAddValue(value))
}

// uciRunPlan 按计划层给的 ops 依次执行。每条 op 都重新 lookup（delete/set 会改变元素
// 状态，缓存状态反而容易踩到已释放的 uci_section——上游也是每次重查）。
func uciRunPlan(txn *uciWriteTxn, section, option string, plan uciMergePlan) int {
	if plan.status != 0 {
		return plan.status
	}
	for _, item := range plan.ops {
		var rc int
		switch item.op {
		case uciMergeDeleteOption:
			rc = txn.txn.Delete(section, option)
		case uciMergeSetOption:
			rc = txn.txn.Set(section, option, item.value)
		case uciMergeAddList:
			rc = txn.txn.AddList(section, option, item.value)
		}
		if rc != 0 {
			return rc
		}
	}
	return StatusOK
}

func uciProviderWriteSave(txn *uciWriteTxn) int {
	if txn == nil {
		return StatusNotSupported
	}
	return txn.txn.Save()
}

func uciProviderWriteDelete(txn *uciWriteTxn, section string, form uciDeleteForm, names []string) int {
	if txn == nil {
		return StatusNotSupported
	}
	switch form {
	case uciDeleteSection:
		// 删整个 section（上游收到 NULL 的 opt）
		return txn.txn.Delete(section, "")
	case uciDeleteOption:
		if len(names) == 0 {
			return StatusNotFound
		}
		return txn.txn.Delete(section, names[0])
	case uciDeleteOptions:
		found := false
		for _, name := range names {
			if txn.txn.Delete(section, name) == StatusOK {
				found = true
			}
		}
		// 一个都没删到 → 4（uci.c:973-991 的聚合）
		if found {
			return StatusOK
		}
		return StatusNotFound
	}
	return StatusUnknownError
}

func uciProviderWriteRename(txn *uciWriteTxn, section, option, newName string) int {
	if txn == nil {
		return StatusNotSupported
	}
	return txn.txn.Rename(section, option, newName)
}

// uciProviderWriteReorder 返回「找到了吗」；调用方据此把状态码聚合成 4。
func uciProviderWriteReorder(txn *uciWriteTxn, section string, pos int) bool {
	if txn == nil {
		return false
	}
	return txn.txn.Reorder(section, pos)
}

// ---------------------------------------------------------------------------
// apply 系
// ---------------------------------------------------------------------------

// uciProviderApplyConfig：load → commit → unload → 事件；noDelta 时提交看不见任何 delta。
func uciProviderApplyConfig(config string, noDelta bool) int {
	uciMu.Lock()
	defer uciMu.Unlock()
	return cbind.UCIApplyConfig(config, noDelta)
}

// uciProviderReloadConfig：fork/exec /sbin/reload_config（父进程立刻返回）。
func uciProviderReloadConfig() int { return cbind.ReloadConfig() }

// uciProviderCommit：uci.c:1344-1351。
func uciProviderCommit(sid, config string) int {
	uciMu.Lock()
	defer uciMu.Unlock()
	return cbind.UCICommit(sid, config)
}

// uciProviderRevert：uci.c:1353-1360。
func uciProviderRevert(sid, config string) int {
	uciMu.Lock()
	defer uciMu.Unlock()
	return cbind.UCIRevert(sid, config)
}

// ---------------------------------------------------------------------------
// cbind 的 JSON 形态 → Go 结构
// ---------------------------------------------------------------------------

// uciJSONSection / uciJSONOption 对应 shim.c 里 molly_uci_append_sections 的输出：
// anonymous / list 是 u32（0/1），不是 JSON bool。
type uciJSONOption struct {
	Name   string   `json:"name"`
	List   int      `json:"list"`
	Values []string `json:"values"`
}

type uciJSONSection struct {
	Name      string          `json:"name"`
	Type      string          `json:"type"`
	Anonymous int             `json:"anonymous"`
	Options   []uciJSONOption `json:"options"`
}

func uciDecodeSections(js string) ([]UciSection, bool) {
	if js == "" {
		return nil, false
	}
	var raw []uciJSONSection
	if err := json.Unmarshal([]byte(js), &raw); err != nil {
		return nil, false
	}
	out := make([]UciSection, 0, len(raw))
	for _, s := range raw {
		opts := make([]UciOption, 0, len(s.Options))
		for _, o := range s.Options {
			vals := o.Values
			if o.List == 0 && len(vals) == 0 {
				// 与 Odin 对齐：标量型恒有 1 个元素（v.string 为 NULL 时是空串）
				vals = []string{""}
			}
			opts = append(opts, UciOption{Name: o.Name, IsList: o.List != 0, Values: vals})
		}
		out = append(out, UciSection{
			Name:      s.Name,
			TypeName:  s.Type,
			Anonymous: s.Anonymous != 0,
			Options:   opts,
		})
	}
	return out, true
}

// uciDecodeDelta 解析 shim 的 delta JSON（cmd 是 enum uci_command，与 uciChangeKind 同序）。
func uciDecodeDelta(js string) ([]uciChange, int) {
	if js == "" {
		return nil, StatusUnknownError
	}
	var raw []struct {
		Cmd     int    `json:"cmd"`
		Section string `json:"section"`
		Name    string `json:"name"`
		Value   string `json:"value"`
	}
	if err := json.Unmarshal([]byte(js), &raw); err != nil {
		return nil, StatusUnknownError
	}
	out := make([]uciChange, 0, len(raw))
	for _, r := range raw {
		out = append(out, uciChange{
			kind:    uciChangeKind(r.Cmd),
			section: r.Section,
			name:    r.Name,
			value:   r.Value,
		})
	}
	return out, StatusOK
}
