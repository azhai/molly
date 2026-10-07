package backend

// uci 对象 —— molly 自持的 ubus 对象之一（对齐 Odin 版 src/backend/uci_object.odin）。
//
// 契约来源：rpcd@e37ed9d814699098eb7e26c8b33c054840782dfb 的 `uci.c`（每处都标了行号）。
// 上游注册 15 个方法（uci.c:1766-1784），这里同样 15 个：只读的 `configs`/`get`/`state`、
// `changes`/`commit`/`revert`、五个写操作（`add`/`set`/`delete`/`rename`/`order`）、
// apply 系（`apply`/`confirm`/`rollback`/`reload_config`）。
//
// 本文件**不带 build tag**：方法层的参数校验、ACL 与 JSON 成型平台无关；平台相关的
// libuci / 假数据通过 uciProvider* 钩子调用（uci_darwin.go / uci_linux.go 各一份，
// 与 Odin 的 `#+build` 双实现同义）。
//
// 顺序契约（与 Odin 一致，必须保住）：参数校验与 ACL 在 provider **之前**，所以
// darwin 上写方法即使 provider 不支持，参数非法仍回 2、缺权限仍回 6，校验通过后才回 8。

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

// ---------------------------------------------------------------------------
// 名称校验（uci.c:187-235）
//
// 三种入口只差两个布尔：extended 允许 `@type[idx]`（且只有以 '@' 开头的才算扩展），
// type 额外允许 '-'（section 类型名可以带连字符，section 名不行）。
// ---------------------------------------------------------------------------

func uciIsAlnum(c byte) bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
}

// uciVerifyStr 对应 uci.c:187-213 rpc_uci_verify_str。
func uciVerifyStr(name string, extended, sectionType bool) bool {
	if len(name) == 0 {
		return false
	}

	ext := extended && name[0] == '@'
	i := 0
	if ext {
		i = 1
	}

	for i < len(name) {
		c := name[i]
		if !uciIsAlnum(c) && c != '_' && ((!sectionType && !ext) || c != '-') {
			break
		}
		i++
	}

	if !ext {
		return i == len(name)
	}

	if i >= len(name) || name[i] != '[' {
		return false
	}

	// C 用 strtol：至少要吃进一位数字（`k > j`），随后必须是 ']' 且串已结束。
	// 与 C 的差异：strtol 还接受前导空白与正负号（`@t[ 1]`、`@t[+1]`），
	// 这里只认纯数字——真正的设备上不会这么写，真机 golden 时会暴露。
	j := i + 1
	k := j
	for k < len(name) && name[k] >= '0' && name[k] <= '9' {
		k++
	}

	return k > j && k+1 == len(name) && name[k] == ']'
}

func uciVerifyName(name string) bool     { return uciVerifyStr(name, false, false) }
func uciVerifyType(typeName string) bool { return uciVerifyStr(typeName, false, true) }
func uciVerifySection(section string) bool {
	return uciVerifyStr(section, true, false)
}

// ---------------------------------------------------------------------------
// `match` / `type` 的筛选（uci.c:344-499）
// ---------------------------------------------------------------------------

// uciFormatBlob 对应 uci.c:344-381 rpc_uci_format_blob。只认 string / 整数 / bool 三种
// ——C 的 switch 里没有 DOUBLE，浮点值会被当成「不支持」而跳过。
// 与 C 的差异：负数在 C 里按无符号打印（`%u`），这里按原值打印。
func uciFormatBlob(raw json.RawMessage) (string, bool) {
	switch firstNonSpace(raw) {
	case '"':
		var s string
		if err := json.Unmarshal(raw, &s); err != nil {
			return "", false
		}
		return s, true
	case 't', 'f':
		var b bool
		if err := json.Unmarshal(raw, &b); err != nil {
			return "", false
		}
		if b {
			return "1", true
		}
		return "0", true
	}

	// 整数：Go 的 encoding/json 把数字都解成 float64，所以按原文判断——含 `.`/`e`/`E`
	// 的一律当浮点跳过（与 Odin 的 json.Integer 分支一致）。
	text := strings.TrimSpace(string(raw))
	if text == "" || strings.ContainsAny(text, ".eE") {
		return "", false
	}
	n, err := strconv.ParseInt(text, 10, 64)
	if err != nil {
		return "", false
	}
	return strconv.FormatInt(n, 10), true
}

// uciMatchOption 对应 uci.c:415-449 rpc_uci_match_option。
//
//	list 型：任一元素相等即命中。
//	字符串型：按空格/制表符切词（C 用 strtok(s, " \t")），任一词相等即命中。
func uciMatchOption(o UciOption, cmp string) bool {
	if o.IsList {
		for _, v := range o.Values {
			if v == cmp {
				return true
			}
		}
		return false
	}

	if len(o.Values) == 0 {
		return false
	}

	val := o.Values[0]
	start := 0
	for i := 0; i <= len(val); i++ {
		if i == len(val) || val[i] == ' ' || val[i] == '\t' {
			if i > start && val[start:i] == cmp {
				return true
			}
			start = i + 1
		}
	}

	return false
}

// uciMatchSection 对应 uci.c:462-499 rpc_uci_match_section。
//
//  1. 给了 type 且不等于 section 的 type → 不匹配；
//  2. match 表里每个键：取出该 section 里同名的 option，逐个要求命中（不命中即失败）；
//     键对应的 option 在该 section 里**不存在**时，这个键不贡献 match；
//  3. 空的/缺失的 match 表恒为匹配。
//
// 注意 `empty || hit`：全部键都被跳过（类型不支持）时返回 true，但只要有键被格式化
// 过又没有键命中，就返回 false。
func uciMatchSection(s UciSection, typeName string, match map[string]json.RawMessage) bool {
	if len(typeName) > 0 && typeName != s.TypeName {
		return false
	}

	if len(match) == 0 {
		return true
	}

	hit := false
	empty := true

	for key, val := range match {
		cmp, formatted := uciFormatBlob(val)
		if !formatted {
			continue
		}

		for _, o := range s.Options {
			if o.Name != key {
				continue
			}
			if !uciMatchOption(o, cmp) {
				return false
			}
			hit = true
		}
		// 键对应的 option 不存在也要清掉 empty（与 C 的 empty = false 位置一致）
		empty = false
	}

	return empty || hit
}

// ---------------------------------------------------------------------------
// dump（uci.c:510-597）
// ---------------------------------------------------------------------------

// uciDumpOptionJSON 对应 uci.c:510-533 rpc_uci_dump_option：list 型输出数组，
// string 型输出字符串。
func uciDumpOptionJSON(o UciOption) any {
	if o.IsList {
		arr := make([]string, 0, len(o.Values))
		arr = append(arr, o.Values...)
		return arr
	}

	if len(o.Values) == 0 {
		return ""
	}

	return o.Values[0]
}

// uciDumpSectionJSON 对应 uci.c:543-566 rpc_uci_dump_section：三个特殊键
// `.anonymous`/`.type`/`.name`，index >= 0 时额外加 `.index`（只有 package 级 dump
// 才给 index）。
func uciDumpSectionJSON(s UciSection, index int) map[string]any {
	obj := make(map[string]any, len(s.Options)+4)
	obj[".anonymous"] = s.Anonymous
	obj[".type"] = s.TypeName
	obj[".name"] = s.Name
	if index >= 0 {
		obj[".index"] = index
	}
	for _, o := range s.Options {
		obj[o.Name] = uciDumpOptionJSON(o)
	}
	return obj
}

// uciDumpPackageJSON 对应 uci.c:576-597 rpc_uci_dump_package。`.index` 是 section 在
// **整份配置**里的序号（C 里 i++ 发生在筛选之前，uci.c:588-590），所以筛掉的 section
// 照样占号。
func uciDumpPackageJSON(sections []UciSection, typeName string, match map[string]json.RawMessage) map[string]any {
	obj := make(map[string]any, len(sections))
	for i, s := range sections {
		if !uciMatchSection(s, typeName, match) {
			continue
		}
		// 键是 section 名。匿名 section 在真机上是 libuci 生成的 `cfgXXXXXX`；
		// darwin 的假数据用空串（tests/fixtures 的既有约定），真机 golden 时核对。
		obj[s.Name] = uciDumpSectionJSON(s, i)
	}
	return obj
}

// uciFindSection：`section` 参数解析——具名直接查名字；`@type[idx]` 是同类型 section
// 里的第 idx 个（uci.c:396-397 打开 UCI_LOOKUP_EXTENDED 后由 libuci 完成，这里等价实现）。
func uciFindSection(sections []UciSection, spec string) (UciSection, bool) {
	if len(spec) == 0 {
		return UciSection{}, false
	}

	if spec[0] != '@' {
		for _, s := range sections {
			if s.Name == spec {
				return s, true
			}
		}
		return UciSection{}, false
	}

	open := -1
	for i := 0; i < len(spec); i++ {
		if spec[i] == '[' {
			open = i
			break
		}
	}
	if open <= 1 {
		return UciSection{}, false
	}

	rest := spec[open:]
	if len(rest) < 3 || rest[len(rest)-1] != ']' {
		return UciSection{}, false
	}

	idx, err := strconv.Atoi(rest[1 : len(rest)-1])
	if err != nil || idx < 0 {
		return UciSection{}, false
	}

	typeName := spec[1:open]
	n := 0
	for _, s := range sections {
		if s.TypeName != typeName {
			continue
		}
		if n == idx {
			return s, true
		}
		n++
	}

	return UciSection{}, false
}

// ---------------------------------------------------------------------------
// 参数小工具（uci 前缀，避免与 session.go 的 helper 撞名）
// ---------------------------------------------------------------------------

// uciParamBool 取布尔字段；字段不存在或不是 bool 都返回 false（blobmsg 策略类型不符
// 会丢掉字段）。
func uciParamBool(params map[string]json.RawMessage, key string) bool {
	raw, has := params[key]
	if !has || firstNonSpace(raw) != 't' {
		return false
	}
	var b bool
	if err := json.Unmarshal(raw, &b); err != nil {
		return false
	}
	return b
}

// uciParamArray 取数组字段（策略里是 BLOBMSG_TYPE_ARRAY）；非数组返回 false。
func uciParamArray(params map[string]json.RawMessage, key string) ([]json.RawMessage, bool) {
	raw, has := params[key]
	if !has || firstNonSpace(raw) != '[' {
		return nil, false
	}
	var arr []json.RawMessage
	if err := json.Unmarshal(raw, &arr); err != nil {
		return nil, false
	}
	return arr, true
}

// ---------------------------------------------------------------------------
// 方法实现
// ---------------------------------------------------------------------------

// uciSidOf 取会话 id（方法入口统一先取它，再决定 ACL 与 savedir）。
func uciSidOf(params map[string]json.RawMessage) (string, bool) {
	return paramStr(params, "ubus_rpc_session")
}

// uciCheckRead：uci.c:311-320 —— session.access("uci", <config 名>, "read")。
// 返回 false 时调用方回 PERMISSION_DENIED(6)。sid 缺失 = 内部调用，不做访问控制。
// 顺带切 savedir（与上游 read_access 做的那两件事一一对应）。
func uciCheckRead(sid, config string) bool {
	uciProviderSavedir(sid)
	if len(sid) == 0 {
		return true
	}
	return sessionAccess(sid, "uci", config, "read")
}

// uciCheckWrite：uci.c:327-337，同上但 function = "write"。
func uciCheckWrite(sid, config string) bool {
	uciProviderSavedir(sid)
	if len(sid) == 0 {
		return true
	}
	return sessionAccess(sid, "uci", config, "write")
}

// uciMethodConfigs 对应 uci.c:1382-1408 rpc_uci_configs：uci_list_configs → {"configs":[…]}。
// 上游这个方法**不做** ACL 检查（对象方法表里它是唯一没有策略的）。
func uciMethodConfigs() (string, int) {
	names, ok := uciProviderConfigs()
	if !ok {
		return "", StatusUnknownError
	}

	arr := make([]string, 0, len(names))
	arr = append(arr, names...)

	return marshalNoEscape(map[string]any{"configs": arr}), StatusOK
}

// uciMethodGet 对应 uci.c:600-662 rpc_uci_getcommon。`get` 与 `state` 共用，只差
// 「从哪读」：
//
//	get   → 当前配置（含本会话的 delta）
//	state → savedir 换成 /var/state，即**已提交**的状态（uci.c:619-620）
//
// 三条回复形态由 ptr 的层级决定：
//
//	package → {"values": {"<section>": {…, ".index": N}}}   （uci.c:640-642）
//	section → {"values": {…}}                              （uci.c:644-646）
//	option  → {"value": <字符串或数组>}                      （uci.c:648-650）
func uciMethodGet(params map[string]json.RawMessage, fromState bool) (string, int) {
	config, hasConfig := paramStr(params, "config")
	if !hasConfig {
		return "", StatusInvalidArgument
	}

	sid, _ := uciSidOf(params)
	if !uciCheckRead(sid, config) {
		return "", StatusPermissionDenied
	}

	var sections []UciSection
	if fromState {
		status := 0
		sections, status = uciProviderStateSections(config)
		if status != 0 {
			return "", status
		}
	} else {
		ok := false
		sections, ok = uciProviderSections(config)
		if !ok {
			// uci_load 失败：libuci 置 UCI_ERR_NOTFOUND，上游映射成 4（uci.c:622-623、:252-253）
			return "", StatusNotFound
		}
	}

	if spec, hasSection := paramStr(params, "section"); hasSection {
		sec, found := uciFindSection(sections, spec)
		if !found {
			// rpc_uci_lookup 失败或 ptr 不完整（uci.c:633-634）
			return "", StatusNotFound
		}

		if option, hasOption := paramStr(params, "option"); hasOption {
			for _, o := range sec.Options {
				if o.Name == option {
					return marshalNoEscape(map[string]any{"value": uciDumpOptionJSON(o)}), StatusOK
				}
			}
			return "", StatusNotFound
		}

		return marshalNoEscape(map[string]any{"values": uciDumpSectionJSON(sec, -1)}), StatusOK
	}

	typeName, _ := paramStr(params, "type")

	var match map[string]json.RawMessage
	if v, found := params["match"]; found && firstNonSpace(v) == '{' {
		_ = json.Unmarshal(v, &match)
	}

	return marshalNoEscape(map[string]any{"values": uciDumpPackageJSON(sections, typeName, match)}), StatusOK
}

// ---------------------------------------------------------------------------
// changes（uci.c:1189-1301）
// ---------------------------------------------------------------------------

// uciChangeKind 是 delta 的七种类型（C 的 enum）。
type uciChangeKind int

const (
	uciChangeAdd uciChangeKind = iota
	uciChangeRemove
	uciChangeChange
	uciChangeRename
	uciChangeReorder
	uciChangeListAdd
	uciChangeListDel
)

// uciChange 是一条 uci delta（对应 Odin 的 Uci_Change）。
type uciChange struct {
	kind    uciChangeKind
	section string
	name    string
	value   string
}

func uciChangeKindName(k uciChangeKind) string {
	switch k {
	case uciChangeAdd:
		return "add"
	case uciChangeRemove:
		return "remove"
	case uciChangeRename:
		return "rename"
	case uciChangeReorder:
		return "order"
	case uciChangeListAdd:
		return "list-add"
	case uciChangeListDel:
		return "list-del"
	}
	return "set"
}

// uciDumpChangeJSON 对应 uci.c:1189-1222 rpc_uci_dump_change：
//
//	["<type>", "<section>", "<name>?", "<value>?"]
//
// section 缺失时整个条目被丢掉（`:1202-1203`，由 uciDumpChangesJSON 处理）；
// name 只在非空时加；`order` 的 value 是序号，上游写成 u32（`:1215-1216`）。
func uciDumpChangeJSON(c uciChange) any {
	arr := []any{uciChangeKindName(c.kind), c.section}
	if len(c.name) > 0 {
		arr = append(arr, c.name)
	}
	if len(c.value) > 0 {
		if c.kind == uciChangeReorder {
			if n, err := strconv.Atoi(c.value); err == nil {
				arr = append(arr, n)
				return arr
			}
		}
		arr = append(arr, c.value)
	}
	return arr
}

// uciDumpChangesJSON 把一组 delta → JSON 数组（changes 的两处都用它）。
func uciDumpChangesJSON(changes []uciChange) []any {
	arr := make([]any, 0, len(changes))
	for _, c := range changes {
		// uci.c:1202-1203：没有 section 的 delta 整条丢掉（不进数组）
		if len(c.section) == 0 {
			continue
		}
		arr = append(arr, uciDumpChangeJSON(c))
	}
	return arr
}

// uciMethodChanges 对应 uci.c:1224-1301 rpc_uci_changes。
//
//	给了 config → {"changes": [ … ]}（该 config 的 delta）
//	没给 config → {"changes": {<config>: [ … ], …}}：逐 config 做读权限过滤、
//	             没有 delta 的跳过
func uciMethodChanges(params map[string]json.RawMessage) (string, int) {
	sid, _ := uciSidOf(params)

	if config, hasConfig := paramStr(params, "config"); hasConfig {
		if !uciCheckRead(sid, config) {
			return "", StatusPermissionDenied
		}
		changes, status := uciProviderDelta(sid, config)
		if status != 0 {
			return "", status
		}
		return marshalNoEscape(map[string]any{"changes": uciDumpChangesJSON(changes)}), StatusOK
	}

	uciProviderSavedir(sid)

	names, ok := uciProviderConfigs()
	if !ok {
		return "", StatusUnknownError
	}

	inner := map[string]any{}
	for _, n := range names {
		// 没给 sid = 内部调用：上游只在 sid 存在时做权限过滤（uci.c:1273-1276）
		if len(sid) > 0 && !sessionAccess(sid, "uci", n, "read") {
			continue
		}
		changes, status := uciProviderDelta(sid, n)
		if status != 0 || len(changes) == 0 {
			continue
		}
		inner[n] = uciDumpChangesJSON(changes)
	}

	return marshalNoEscape(map[string]any{"changes": inner}), StatusOK
}

// ---------------------------------------------------------------------------
// 待确认的 apply（apply/confirm/rollback 维护；commit/revert 与之互斥）
// ---------------------------------------------------------------------------

var (
	uciApplyMu    sync.Mutex
	uciApplySid   string
	uciApplyGen   int
	uciApplyTimer *time.Timer
)

// uciApplyPending：「有一次 apply 在等 confirm」。
func uciApplyPending() bool {
	uciApplyMu.Lock()
	defer uciApplyMu.Unlock()
	return len(uciApplySid) > 0
}

func uciApplyGetSid() string {
	uciApplyMu.Lock()
	defer uciApplyMu.Unlock()
	return uciApplySid
}

func uciApplySetSid(sid string) {
	uciApplyMu.Lock()
	uciApplySid = sid
	uciApplyMu.Unlock()
}

func uciApplyClearSid() {
	uciApplyMu.Lock()
	uciApplySid = ""
	uciApplyMu.Unlock()
}

// uciMethodCommitOrRevert 对应 uci.c:1324-1379 rpc_uci_revert_commit：`commit` 与
// `revert` 共用。
//
//	有 apply 在等确认 → 6（上游 uci.c:1330-1331 回 PERMISSION_DENIED）
//	缺 config        → 2
//	无写权限         → 6
//	然后交给平台侧执行（darwin 回 8：按决策，写路径只在 linux 上实现）
func uciMethodCommitOrRevert(params map[string]json.RawMessage, commit bool) (string, int) {
	if uciApplyPending() {
		return "", StatusPermissionDenied
	}

	config, hasConfig := paramStr(params, "config")
	if !hasConfig {
		return "", StatusInvalidArgument
	}

	sid, _ := uciSidOf(params)
	if !uciCheckWrite(sid, config) {
		return "", StatusPermissionDenied
	}

	status := 0
	if commit {
		status = uciProviderCommit(sid, config)
	} else {
		status = uciProviderRevert(sid, config)
	}
	if status != 0 {
		return "", status
	}
	// 上游这两个方法**不回数据**（与 session 的 set/unset 同类）
	return "", StatusOK
}

// ---------------------------------------------------------------------------
// 写方法：`set` / `add` / `delete` / `rename` / `order`
//
// 平台无关的方法层：参数校验 + ACL + 聚合规则都在这里，真正的 libuci 调用走
// uciProviderWrite*（darwin 侧全部回 NOT_SUPPORTED(8)）。
// ---------------------------------------------------------------------------

// uciMethodSet 对应 uci.c:875-946 rpc_uci_set。注意两点：
//
//  1. 错误聚合是**最后一个 rv 覆盖**（`:913`、`:932`），与 add 相反；
//  2. 成功时**不发回复**。
func uciMethodSet(params map[string]json.RawMessage) (string, int) {
	config, hasConfig := paramStr(params, "config")
	values, hasValues := paramObject(params, "values")
	section, hasSection := paramStr(params, "section")
	typeName, hasType := paramStr(params, "type")
	match, hasMatch := paramObject(params, "match")

	if !hasConfig || !hasValues || (!hasSection && !hasType && !hasMatch) {
		return "", StatusInvalidArgument
	}

	sid, _ := uciSidOf(params)
	if !uciCheckWrite(sid, config) {
		return "", StatusPermissionDenied
	}

	if hasSection && !uciVerifySection(section) {
		return "", StatusInvalidArgument
	}

	txn, status := uciProviderWriteBegin(sid, config)
	if status != 0 {
		return "", status
	}
	defer uciProviderWriteEnd(txn)

	err := StatusOK
	hit := false

	if hasSection {
		hit = true
		for key, val := range values {
			rv := uciProviderWriteMergeSet(txn, section, key, val)
			if rv != 0 {
				err = rv // 最后一个覆盖
			}
		}
	} else {
		sections, st := uciProviderWriteSections(txn)
		if st != 0 {
			return "", st
		}
		tn := ""
		if hasType {
			tn = typeName
		}
		for _, s := range sections {
			if !uciMatchSection(s, tn, match) {
				continue
			}
			hit = true
			for key, val := range values {
				rv := uciProviderWriteMergeSet(txn, s.Name, key, val)
				if rv != 0 {
					err = rv
				}
			}
		}
	}

	if err != 0 {
		return "", err
	}
	if !hit {
		// 一个 section 都没命中（上游判 ptr.s，uci.c:937-938）
		return "", StatusNotFound
	}
	if st := uciProviderWriteSave(txn); st != 0 {
		return "", st
	}
	return "", StatusOK
}

// uciMethodAdd 对应 uci.c:681-804 rpc_uci_add。与 set 的差别：
//
//  1. `config` 与 `type` 都是必需；
//  2. 具名 section 用 `uci_set`（ptr.value = type）创建，匿名用 `uci_add_section`；
//  3. `values` 可选；每个键先 verify_name，再按 add 的 value 语义写；
//  4. 错误聚合是**首个错误优先**；
//  5. 成功时回 `{"section": "<section 名>"}`。
func uciMethodAdd(params map[string]json.RawMessage) (string, int) {
	config, hasConfig := paramStr(params, "config")
	typeName, hasType := paramStr(params, "type")

	if !hasConfig || !hasType {
		return "", StatusInvalidArgument
	}

	sid, _ := uciSidOf(params)
	if !uciCheckWrite(sid, config) {
		return "", StatusPermissionDenied
	}

	if !uciVerifyType(typeName) {
		return "", StatusInvalidArgument
	}

	name, hasName := paramStr(params, "name")
	if hasName && !uciVerifyName(name) {
		return "", StatusInvalidArgument
	}

	txn, status := uciProviderWriteBegin(sid, config)
	if status != 0 {
		return "", status
	}
	defer uciProviderWriteEnd(txn)

	sectionName, st := uciProviderWriteAddSection(txn, typeName, name)
	if st != 0 {
		return "", st
	}

	err := StatusOK
	if values, hasValues := paramObject(params, "values"); hasValues {
		for key, val := range values {
			if !uciVerifyName(key) {
				if err == 0 {
					err = StatusInvalidArgument
				}
				continue
			}
			rv := uciProviderWriteAddValue(txn, sectionName, key, val)
			if rv != 0 && err == 0 {
				err = rv
			}
		}
	}

	if err != 0 {
		return "", err
	}
	if st := uciProviderWriteSave(txn); st != 0 {
		return "", st
	}

	return marshalNoEscape(map[string]any{"section": sectionName}), StatusOK
}

// uciDeleteForm 是 merge_delete 的三种形态。
type uciDeleteForm int

const (
	uciDeleteSection uciDeleteForm = iota
	uciDeleteOption
	uciDeleteOptions
)

type uciDeletePlan struct {
	status int
	form   uciDeleteForm
	names  []string
}

// uciPlanMergeDelete 对应 uci.c:948-1006 的**类型分流**：字符串 → 具名；数组 →
// 多个名字（非字符串元素跳过）；其它类型 → 2。
func uciPlanMergeDelete(raw json.RawMessage) uciDeletePlan {
	switch firstNonSpace(raw) {
	case '"':
		s, ok := rawStr(raw)
		if !ok {
			return uciDeletePlan{status: StatusInvalidArgument}
		}
		return uciDeletePlan{form: uciDeleteOption, names: []string{s}}
	case '[':
		var arr []json.RawMessage
		if err := json.Unmarshal(raw, &arr); err != nil {
			return uciDeletePlan{status: StatusInvalidArgument}
		}
		names := make([]string, 0, len(arr))
		for _, el := range arr {
			if s, ok := rawStr(el); ok {
				names = append(names, s)
			}
		}
		return uciDeletePlan{form: uciDeleteOptions, names: names}
	}
	return uciDeletePlan{status: StatusInvalidArgument}
}

// uciDeletePlanOf 把 option/options 两个参数折成一份删除计划（uci.c:1046-1049）；
// 两个都没给 → 删整个 section（上游把 NULL 的 blob 交给 merge_delete，:963-970）。
func uciDeletePlanOf(params map[string]json.RawMessage) uciDeletePlan {
	if raw, hasOptions := params["options"]; hasOptions && firstNonSpace(raw) == '[' {
		return uciPlanMergeDelete(raw)
	}
	if raw, hasOption := params["option"]; hasOption && firstNonSpace(raw) == '"' {
		return uciPlanMergeDelete(raw)
	}
	return uciDeletePlan{form: uciDeleteSection}
}

// uciMethodDelete 对应 uci.c:1008-1078 rpc_uci_delete。要点：
//
//   - 与 `set` 一样用**最后一个错误覆盖**（`:1047`、`:1063`）；
//   - 没有 section 时按 type/match 遍历；
//   - 一个 section 都没命中 → 4（`:1068-1069`）；
//   - 成功不发回复。
func uciMethodDelete(params map[string]json.RawMessage) (string, int) {
	config, hasConfig := paramStr(params, "config")
	section, hasSection := paramStr(params, "section")
	typeName, hasType := paramStr(params, "type")
	match, hasMatch := paramObject(params, "match")

	if !hasConfig || (!hasSection && !hasType && !hasMatch) {
		return "", StatusInvalidArgument
	}

	sid, _ := uciSidOf(params)
	if !uciCheckWrite(sid, config) {
		return "", StatusPermissionDenied
	}

	if hasType && !uciVerifyType(typeName) {
		return "", StatusInvalidArgument
	}
	if hasSection && !uciVerifySection(section) {
		return "", StatusInvalidArgument
	}

	plan := uciDeletePlanOf(params)
	if plan.status != 0 {
		return "", plan.status
	}

	txn, status := uciProviderWriteBegin(sid, config)
	if status != 0 {
		return "", status
	}
	defer uciProviderWriteEnd(txn)

	err := StatusOK
	if hasSection {
		err = uciProviderWriteDelete(txn, section, plan.form, plan.names)
	} else {
		sections, st := uciProviderWriteSections(txn)
		if st != 0 {
			return "", st
		}
		tn := ""
		if hasType {
			tn = typeName
		}
		targets := make([]string, 0, len(sections))
		for _, s := range sections {
			if !uciMatchSection(s, tn, match) {
				continue
			}
			targets = append(targets, s.Name)
		}
		if len(targets) == 0 {
			return "", StatusNotFound
		}
		for _, name := range targets {
			rv := uciProviderWriteDelete(txn, name, plan.form, plan.names)
			if rv != 0 {
				err = rv
			}
		}
	}

	if err != 0 {
		return "", err
	}
	if st := uciProviderWriteSave(txn); st != 0 {
		return "", st
	}
	return "", StatusOK
}

// uciMethodRename 对应 uci.c:1080-1129 rpc_uci_rename。要点：name 过 verify_name
// （**不**校验 section 语法）；成功不发回复。
func uciMethodRename(params map[string]json.RawMessage) (string, int) {
	config, hasConfig := paramStr(params, "config")
	section, hasSection := paramStr(params, "section")
	name, hasName := paramStr(params, "name")

	if !hasConfig || !hasSection || !hasName {
		return "", StatusInvalidArgument
	}

	sid, _ := uciSidOf(params)
	if !uciCheckWrite(sid, config) {
		return "", StatusPermissionDenied
	}

	if !uciVerifyName(name) {
		return "", StatusInvalidArgument
	}

	option, _ := paramStr(params, "option")

	txn, status := uciProviderWriteBegin(sid, config)
	if status != 0 {
		return "", status
	}
	defer uciProviderWriteEnd(txn)

	if rv := uciProviderWriteRename(txn, section, option, name); rv != 0 {
		return "", rv
	}
	if st := uciProviderWriteSave(txn); st != 0 {
		return "", st
	}
	return "", StatusOK
}

// uciMethodOrder 对应 uci.c:1131-1186 rpc_uci_order。要点：
//
//   - 非字符串元素 → 2（**首个**错误优先，`:1158-1164`）；
//   - lookup 不到 section → 4（同样首个优先，`:1169-1175`）；
//   - 位置计数 `pos` 只对**成功**的项递增（`:1177`）；
//   - 成功不发回复。
func uciMethodOrder(params map[string]json.RawMessage) (string, int) {
	config, hasConfig := paramStr(params, "config")
	list, hasList := uciParamArray(params, "sections")

	if !hasConfig || !hasList {
		return "", StatusInvalidArgument
	}

	sid, _ := uciSidOf(params)
	if !uciCheckWrite(sid, config) {
		return "", StatusPermissionDenied
	}

	txn, status := uciProviderWriteBegin(sid, config)
	if status != 0 {
		return "", status
	}
	defer uciProviderWriteEnd(txn)

	err := StatusOK
	pos := 0
	for _, elem := range list {
		name, isString := rawStr(elem)
		if !isString {
			if err == 0 {
				err = StatusInvalidArgument
			}
			continue
		}
		if !uciProviderWriteReorder(txn, name, pos) {
			if err == 0 {
				err = StatusNotFound
			}
			continue
		}
		pos++
	}

	if err != 0 {
		return "", err
	}
	if st := uciProviderWriteSave(txn); st != 0 {
		return "", st
	}
	return "", StatusOK
}

// ---------------------------------------------------------------------------
// apply 系（uci.c:1443-1734）
//
// 机制一句话：`apply {rollback:true, timeout:N}` 把 /etc/config 与**该会话的 delta**
// 各备份一份到快照目录，然后提交（= 配置真的生效）；发起者必须在 N 秒内 `confirm`，
// 否则定时器到点**回滚**（用快照覆盖 /etc/config 并重新提交）。等确认期间 applySid
// 非空，`commit`/`revert` 一律被挡（uci.c:1330-1331）。
//
// 目录（uci.h）：
//
//	/var/run/rpcd/snapshot-files/   /etc/config 的原样备份
//	/var/run/rpcd/snapshot-delta/   delta 文件的备份
//	/var/run/rpcd/uci-<sid>/        每会话的 delta
//
// 平台相关的两件事——「提交一个 config」（要 libuci）与 `reload_config`（要 fork/exec）
// ——走 uciProviderApplyConfig / uciProviderReloadConfig；darwin 一律回 8。
// ---------------------------------------------------------------------------

const (
	// uciApplyTimeout 是默认确认窗口（RPC_APPLY_TIMEOUT，秒）。
	uciApplyTimeout = 60

	uciSnapshotFilesDir = "/var/run/rpcd/snapshot-files/"
	uciSnapshotDeltaDir = "/var/run/rpcd/snapshot-delta/"
	uciConfigDir        = "/etc/config/"
	// uciSavedirPrefix 是 /var/run/rpcd/uci-<sid>（uci.h 的 RPC_UCI_SAVEDIR_PREFIX）。
	uciSavedirPrefix = "/var/run/rpcd/uci-"

	// uciApplyMaxMs：上游把客户端给的 timeout 钳在 INT_MAX 毫秒以内，避免溢出成负数后
	// 定时器立刻到点（uci.c:1637-1645）。
	uciApplyMaxMs = 2147483647
)

// uciListSnapshotFiles 列目录里「可用的」文件名：跳过 dotfile（含 . 与 ..）与空文件
// （uci.c:1489-1498、:1620-1628）。目录不存在 → ok = false（上游 glob 失败 → 4）。
func uciListSnapshotFiles(dir string) ([]string, bool) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, false
	}
	out := make([]string, 0, len(entries))
	for _, e := range entries {
		name := e.Name()
		if len(name) == 0 || name[0] == '.' {
			continue
		}
		info, err := e.Info()
		if err != nil || info.Size() == 0 {
			continue
		}
		out = append(out, name)
	}
	return out, true
}

// uciCopyFile：<fromDir><name> → <toDir><name>（uci.c:1457-1478；上游忽略失败）。
func uciCopyFile(fromDir, toDir, name string) bool {
	data, err := os.ReadFile(fromDir + name)
	if err != nil {
		return false
	}
	return os.WriteFile(toDir+name, data, 0o644) == nil
}

// uciPurgeDir 对应 uci.c:1414-1441 rpc_uci_purge_dir：删目录里的**普通文件**再 rmdir
// （子目录跳过——上游也是 continue）。
func uciPurgeDir(path string) {
	entries, err := os.ReadDir(path)
	if err != nil {
		return
	}
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		info, err := e.Info()
		if err != nil || !info.Mode().IsRegular() {
			continue
		}
		_ = os.Remove(filepath.Join(path, e.Name()))
	}
	_ = os.Remove(path)
}

// uciApplyAccess 对应 uci.c:1480-1505 rpc_uci_apply_access：
//
//	没有任何可用文件 → 5（NO_DATA）
//	有一个 config 没写权限 → 6（PERMISSION_DENIED）
//	全都有写权限 → 0
func uciApplyAccess(sid string, names []string) int {
	if len(names) == 0 {
		return StatusNoData
	}
	for _, name := range names {
		if !sessionAccess(sid, "uci", name, "write") {
			return StatusPermissionDenied
		}
	}
	return StatusOK
}

// uciDoRollback 对应 uci.c:1507-1548 rpc_uci_do_rollback。
// 「发起 apply 的会话还在吗」用 apply_access 判断：还在（0）就连 delta 一起恢复，
// 否则只恢复 /etc/config（uci.c:1513-1522）。
func uciDoRollback(names []string) int {
	sid := uciApplyGetSid()
	deny := StatusNotFound
	if len(sid) > 0 {
		deny = uciApplyAccess(sid, names)
	}

	savedir := uciSavedirPrefix + sid + "/"
	if deny == StatusOK {
		_ = os.Mkdir(savedir, 0o755)
	}

	for _, name := range names {
		// 上游先把 delta 副本放回去，再「不合并 delta」地提交主配置（uci.c:1524-1539）：
		// no_delta = true 就是 `rpc_uci_replace_savedir("/dev/null")`——让提交看不见任何
		// delta，否则回滚会被当前的未提交改动污染。
		uciCopyFile(uciSnapshotFilesDir, uciConfigDir, name)
		if st := uciProviderApplyConfig(name, true); st != 0 {
			return st
		}
		if deny != StatusOK {
			continue
		}
		uciCopyFile(uciSnapshotDeltaDir, savedir, name)
	}

	uciPurgeDir(uciSnapshotFilesDir)
	uciPurgeDir(uciSnapshotDeltaDir)

	uciApplyTimerCancel()
	uciApplyClearSid()
	return StatusOK
}

// uciApplyTimeoutFired：定时器到点（uci.c:1550-1563 rpc_uci_apply_timeout）。
func uciApplyTimeoutFired() {
	names, ok := uciListSnapshotFiles(uciSnapshotFilesDir)
	if !ok {
		return
	}
	_ = uciDoRollback(names)
}

// uciApplyTimerStart 起确认窗口。代际号让「已经取消的那次定时」醒来后直接退出；与
// Odin 的「自清理线程 + sleep」等价（同一时刻最多一个 apply 待确认，goroutine 数有界）。
func uciApplyTimerStart(ms int) {
	uciApplyMu.Lock()
	defer uciApplyMu.Unlock()

	uciApplyGen++
	gen := uciApplyGen
	if uciApplyTimer != nil {
		uciApplyTimer.Stop()
	}
	uciApplyTimer = time.AfterFunc(time.Duration(ms)*time.Millisecond, func() {
		uciApplyMu.Lock()
		stale := uciApplyGen != gen
		uciApplyMu.Unlock()
		if stale {
			return
		}
		if uciApplyPending() {
			uciApplyTimeoutFired()
		}
	})
}

// uciApplyTimerCancel：让在跑的定时器失效；调用方负责清 uciApplySid。
func uciApplyTimerCancel() {
	uciApplyMu.Lock()
	defer uciApplyMu.Unlock()
	uciApplyGen++
	if uciApplyTimer != nil {
		uciApplyTimer.Stop()
		uciApplyTimer = nil
	}
}

// uciMethodApply 对应 uci.c:1565-1651 rpc_uci_apply。
func uciMethodApply(params map[string]json.RawMessage) (string, int) {
	rollback := uciParamBool(params, "rollback")

	// 已经有一次 apply 在等确认时，不允许再发起一个「要回滚的 apply」（uci.c:1584-1585）
	if uciApplyPending() && rollback {
		return "", StatusPermissionDenied
	}

	sid, hasSid := uciSidOf(params)
	if !hasSid {
		return "", StatusInvalidArgument
	}

	timeout := uciApplyTimeout
	if n, hasTimeout := paramInt(params, "timeout"); hasTimeout {
		timeout = n
	}

	// 每次 apply 都先清掉上次的快照（uci.c:1595-1596）
	uciPurgeDir(uciSnapshotFilesDir)
	uciPurgeDir(uciSnapshotDeltaDir)

	// 已有 apply 在等确认 → 只做上面的清理就返回（uci.c:1598 的 if (!apply_sid[0])）
	if uciApplyPending() {
		return "", StatusOK
	}

	savedir := uciSavedirPrefix + sid + "/"
	names, ok := uciListSnapshotFiles(savedir)
	if !ok {
		return "", StatusNotFound
	}

	if st := uciApplyAccess(sid, names); st != 0 {
		return "", st
	}

	_ = os.Mkdir(uciSnapshotFilesDir, 0o755)
	_ = os.Mkdir(uciSnapshotDeltaDir, 0o755)

	// 先记 sid：提交过程会调用 ubus（触发事件）并改动包级状态
	// （上游同样先 strncpy，uci.c:1616-1618）
	if rollback {
		uciApplySetSid(sid)
	}

	for _, name := range names {
		uciCopyFile(uciConfigDir, uciSnapshotFilesDir, name)
		uciCopyFile(savedir, uciSnapshotDeltaDir, name)
		if st := uciProviderApplyConfig(name, false); st != 0 {
			return "", st
		}
	}

	if rollback {
		ms := uciApplyMaxMs
		if timeout > 0 && timeout <= uciApplyMaxMs/1000 {
			ms = timeout * 1000
		}
		uciApplyTimerStart(ms)
	}

	return "", StatusOK
}

// uciMethodConfirm 对应 uci.c:1653-1683 rpc_uci_confirm。
func uciMethodConfirm(params map[string]json.RawMessage) (string, int) {
	sid, hasSid := uciSidOf(params)
	if !hasSid {
		return "", StatusInvalidArgument
	}

	if !uciApplyPending() {
		return "", StatusNoData
	}
	if uciApplyGetSid() != sid {
		return "", StatusPermissionDenied
	}

	uciPurgeDir(uciSnapshotFilesDir)
	uciPurgeDir(uciSnapshotDeltaDir)

	uciApplyTimerCancel()
	uciApplyClearSid()
	return "", StatusOK
}

// uciMethodRollback 对应 uci.c:1685-1718 rpc_uci_rollback。注意顺序：**先**判有没有
// 待确认的 apply（→ 5），再判 sid 参数（→ 2），与 confirm 正好相反。
func uciMethodRollback(params map[string]json.RawMessage) (string, int) {
	if !uciApplyPending() {
		return "", StatusNoData
	}

	sid, hasSid := uciSidOf(params)
	if !hasSid {
		return "", StatusInvalidArgument
	}
	if uciApplyGetSid() != sid {
		return "", StatusPermissionDenied
	}

	names, ok := uciListSnapshotFiles(uciSnapshotFilesDir)
	if !ok {
		return "", StatusNotFound
	}

	if st := uciDoRollback(names); st != 0 {
		return "", st
	}
	return "", StatusOK
}

// uciMethodReloadConfig 对应 uci.c:1720-1734 rpc_uci_reload：让 /sbin/reload_config
// 在响应发出后跑（provider）。
func uciMethodReloadConfig() (string, int) {
	if st := uciProviderReloadConfig(); st != 0 {
		return "", st
	}
	return "", StatusOK
}

// ---------------------------------------------------------------------------
// 入口
// ---------------------------------------------------------------------------

// callUCI 实现 uci 对象的 15 个方法。返回 (reply, status)：
// status == 0 成功，reply 是 JSON 文本（可为 ""）；status != 0 是 ubus 状态码。
func callUCI(method, paramsJSON string) (string, int) {
	var params map[string]json.RawMessage
	if len(paramsJSON) > 0 {
		if err := json.Unmarshal([]byte(paramsJSON), &params); err != nil {
			params = nil
		}
	}

	switch method {
	case "configs":
		return uciMethodConfigs()
	case "get":
		return uciMethodGet(params, false)
	case "state":
		// 已提交态（savedir 换成 /var/state）；darwin 的 provider 回 8
		return uciMethodGet(params, true)
	case "changes":
		return uciMethodChanges(params)
	case "commit":
		return uciMethodCommitOrRevert(params, true)
	case "revert":
		return uciMethodCommitOrRevert(params, false)
	case "set":
		return uciMethodSet(params)
	case "add":
		return uciMethodAdd(params)
	case "delete":
		return uciMethodDelete(params)
	case "rename":
		return uciMethodRename(params)
	case "order":
		return uciMethodOrder(params)
	case "apply":
		return uciMethodApply(params)
	case "confirm":
		return uciMethodConfirm(params)
	case "rollback":
		return uciMethodRollback(params)
	case "reload_config":
		return uciMethodReloadConfig()
	}
	// 真机上 libubus 在 handler 之前就回了 3（METHOD_NOT_FOUND），这里保持一致。
	return "", StatusMethodNotFound
}
