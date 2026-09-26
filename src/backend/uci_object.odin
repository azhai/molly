package backend

// ---------------------------------------------------------------------------
// uci 对象（P3-3 的 S1：只读）
//
// 契约来源：rpcd@e37ed9d814699098eb7e26c8b33c054840782dfb 的 `uci.c`（每处都标了行号）。
// 上游注册 15 个方法（uci.c:1766-1784）。本片实现只读的两个：`configs`、`get`；
// 其余按 .ai-memory/p3-luci-server.md 的分片一律回 NOT_SUPPORTED(8)：
//   `state` 要 savedir 模型（S2）／写操作要 libuci 的写绑定（S3）／
//   `apply` 系要 uloop 定时器 + ubus 事件（S4）。
// 用户已定：写路径**先只在 linux 上实现**，darwin 侧不另做一份 uci 读写替身。
//
// 与 rpcd 的差异都记在 docs/interfaces.md 的 uci 契约节，改语义前先看那里。
// ---------------------------------------------------------------------------

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strconv"

// 与 session.odin 的 SESSION_STATUS_* 是同一套 ubus 状态码，名字按对象区分。
// 8 = UBUS_STATUS_NOT_SUPPORTED，9 = UBUS_STATUS_UNKNOWN_ERROR。
UCI_STATUS_OK :: 0
UCI_STATUS_INVALID_ARGUMENT :: 2
UCI_STATUS_METHOD_NOT_FOUND :: 3
UCI_STATUS_NOT_FOUND :: 4
UCI_STATUS_PERMISSION_DENIED :: 6
UCI_STATUS_NOT_SUPPORTED :: 8
UCI_STATUS_UNKNOWN_ERROR :: 9

// ---------------------------------------------------------------------------
// 名称校验（uci.c:187-235）
//
// 三种入口只差两个布尔：extended 允许 `@type[idx]`（且只有以 '@' 开头的才算扩展），
// type 额外允许 '-'（section 类型名可以带连字符，section 名不行）。
// ---------------------------------------------------------------------------

@(private)
uci_is_alnum :: proc(c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
}

// uci.c:187-213 rpc_uci_verify_str
uci_verify_str :: proc(name: string, extended: bool, section_type: bool) -> bool {
	if len(name) == 0 {
		return false
	}

	ext := extended && name[0] == '@'
	i := ext ? 1 : 0

	for i < len(name) {
		c := name[i]
		if !uci_is_alnum(c) && c != '_' && ((!section_type && !ext) || c != '-') {
			break
		}
		i += 1
	}

	if !ext {
		return i == len(name)
	}

	if i >= len(name) || name[i] != '[' {
		return false
	}

	// C 用 strtol：至少要吃进一位数字（`e > c`），随后必须是 ']' 且串已结束。
	// 与 C 的差异：strtol 还接受前导空白与正负号（`@t[ 1]`、`@t[+1]`），
	// molly 只认纯数字——真正的设备上不会这么写，真机 golden 时会暴露。
	j := i + 1
	k := j
	for k < len(name) && name[k] >= '0' && name[k] <= '9' {
		k += 1
	}

	return k > j && k + 1 == len(name) && name[k] == ']'
}

// uci.c:218-220 / :225-227 / :233-235
uci_verify_name :: proc(name: string) -> bool {return uci_verify_str(name, false, false)}
uci_verify_type :: proc(type_name: string) -> bool {return uci_verify_str(type_name, false, true)}
uci_verify_section :: proc(section: string) -> bool {return uci_verify_str(section, true, false)}

// ---------------------------------------------------------------------------
// `match` / `type` 的筛选（uci.c:344-499）
// ---------------------------------------------------------------------------

// uci.c:344-381 rpc_uci_format_blob。只认 string / 整数 / bool 三种——C 的 switch
// 里没有 DOUBLE，浮点值会被当成「不支持」而跳过。
// 与 C 的差异：负数在 C 里按无符号打印（`%u`），这里按原值打印。
@(private)
uci_format_blob :: proc(v: json.Value, alloc: mem.Allocator) -> (string, bool) {
	#partial switch t in v {
	case json.String:
		return string(t), true
	case json.Integer:
		return fmt.aprintf("%d", i64(t), allocator = alloc), true
	case json.Boolean:
		return t ? "1" : "0", true
	}
	return "", false
}

// uci.c:415-449 rpc_uci_match_option。
//   list 型：任一元素相等即命中。
//   字符串型：按空格/制表符切词（C 用 strtok(s, " \t")），任一词相等即命中。
uci_match_option :: proc(o: Uci_Option, cmp: string) -> bool {
	if o.is_list {
		for v in o.values {
			if v == cmp {
				return true
			}
		}
		return false
	}

	if len(o.values) == 0 {
		return false
	}

	val := o.values[0]
	start := 0
	for i in 0 ..= len(val) {
		if i == len(val) || val[i] == ' ' || val[i] == '\t' {
			if i > start && val[start:i] == cmp {
				return true
			}
			start = i + 1
		}
	}

	return false
}

// uci.c:462-499 rpc_uci_match_section。
//   1) 给了 type 且不等于 section 的 type → 不匹配；
//   2) match 表里每个键：取出该 section 里同名的 option，逐个要求命中（不命中即失败）；
//      键对应的 option 在该 section 里**不存在**时，这个键不贡献 match；
//   3) 空的/缺失的 match 表恒为匹配。
//   注意 `empty || match`：全部键都被跳过（类型不支持）时返回 true，但只要有键被格式化
//   过又没有键命中，就返回 false。
uci_match_section :: proc(
	s: Uci_Section,
	type_name: string,
	match: json.Object,
	alloc: mem.Allocator,
) -> bool {
	if len(type_name) > 0 && type_name != s.type_name {
		return false
	}

	if len(match) == 0 {
		return true
	}

	hit := false
	empty := true

	for key, val in match {
		cmp, formatted := uci_format_blob(val, alloc)
		if !formatted {
			continue
		}

		exists := false
		for o in s.options {
			if o.name != key {
				continue
			}
			exists = true
			if !uci_match_option(o, cmp) {
				return false
			}
			hit = true
		}
		// 键对应的 option 不存在也要清掉 empty（与 C 的 empty = false 位置一致）
		_ = exists
		empty = false
	}

	return empty || hit
}

// ---------------------------------------------------------------------------
// dump（uci.c:510-597）
// ---------------------------------------------------------------------------

// uci.c:510-533 rpc_uci_dump_option：list 型输出数组，string 型输出字符串。
@(private)
uci_dump_option_json :: proc(o: Uci_Option, alloc: mem.Allocator) -> json.Value {
	if o.is_list {
		arr := make([dynamic]json.Value, 0, max(len(o.values), 1), alloc)
		for v in o.values {
			append(&arr, json.Value(json.String(v)))
		}
		return json.Value(json.Array(arr))
	}

	if len(o.values) == 0 {
		return json.Value(json.String(""))
	}

	return json.Value(json.String(o.values[0]))
}

// uci.c:543-566 rpc_uci_dump_section：三个特殊键 `.anonymous`/`.type`/`.name`，
// index >= 0 时额外加 `.index`（只有 package 级 dump 才给 index）。
@(private)
uci_dump_section_json :: proc(s: Uci_Section, index: int, alloc: mem.Allocator) -> json.Value {
	obj := make(json.Object, len(s.options) + 4, alloc)
	obj[".anonymous"] = json.Value(json.Boolean(s.anonymous))
	obj[".type"] = json.Value(json.String(s.type_name))
	obj[".name"] = json.Value(json.String(s.name))
	if index >= 0 {
		obj[".index"] = json.Value(json.Integer(i64(index)))
	}
	for o in s.options {
		obj[o.name] = uci_dump_option_json(o, alloc)
	}
	return json.Value(obj)
}

// uci.c:576-597 rpc_uci_dump_package。`.index` 是 section 在**整份配置**里的序号
// （C 里 i++ 发生在筛选之前，uci.c:588-590），所以筛掉的 section 照样占号。
@(private)
uci_dump_package_json :: proc(
	sections: []Uci_Section,
	type_name: string,
	match: json.Object,
	alloc: mem.Allocator,
) -> json.Value {
	obj := make(json.Object, len(sections), alloc)
	for s, i in sections {
		if !uci_match_section(s, type_name, match, alloc) {
			continue
		}
		// 键是 section 名。匿名 section 在真机上是 libuci 生成的 `cfgXXXXXX`；
		// darwin 的假数据用空串（tests/fixtures 的既有约定），真机 golden 时核对。
		obj[s.name] = uci_dump_section_json(s, i, alloc)
	}
	return json.Value(obj)
}

// `section` 参数解析：具名直接查名字；`@type[idx]` 是同类型 section 里的第 idx 个
// （uci.c:396-397 打开 UCI_LOOKUP_EXTENDED 后由 libuci 完成，这里等价实现）。
uci_find_section :: proc(sections: []Uci_Section, spec: string) -> (sec: Uci_Section, ok: bool) {
	if len(spec) == 0 {
		return {}, false
	}

	if spec[0] != '@' {
		for s in sections {
			if s.name == spec {
				return s, true
			}
		}
		return {}, false
	}

	open := -1
	for i in 0 ..< len(spec) {
		if spec[i] == '[' {
			open = i
			break
		}
	}
	if open <= 1 {
		return {}, false
	}

	rest := spec[open:]
	if len(rest) < 3 || rest[len(rest) - 1] != ']' {
		return {}, false
	}

	idx, parsed := strconv.parse_int(rest[1:len(rest) - 1])
	if !parsed || idx < 0 {
		return {}, false
	}

	type_name := spec[1:open]
	n: int
	for s in sections {
		if s.type_name != type_name {
			continue
		}
		if n == int(idx) {
			return s, true
		}
		n += 1
	}

	return {}, false
}

// ---------------------------------------------------------------------------
// 方法实现
// ---------------------------------------------------------------------------

// 从 params 里取字符串字段。字段不存在、或类型不是字符串（blobmsg_parse 会因策略
// 类型不符而丢掉该字段）都返回 false。
@(private)
uci_param_str :: proc(params: json.Object, key: string) -> (string, bool) {
	v, found := params[key]
	if !found {
		return "", false
	}
	s, is_str := v.(json.String)
	if !is_str {
		return "", false
	}
	return string(s), true
}

// uci.c:1382-1408 rpc_uci_configs：uci_list_configs → {"configs":[…]}。
// 上游这个方法**不做** ACL 检查（对象方法表里它是唯一没有策略的）。
@(private)
uci_method_configs :: proc(alloc: mem.Allocator) -> (string, int) {
	names, ok := uci_list_configs(alloc)
	if !ok {
		return "", UCI_STATUS_UNKNOWN_ERROR
	}

	arr := make([dynamic]json.Value, 0, len(names), alloc)
	for n in names {
		append(&arr, json.Value(json.String(n)))
	}

	doc := make(json.Object, 1, alloc)
	doc["configs"] = json.Value(json.Array(arr))

	// session_marshal 名字带 session，实际是这个包里通用的 json.Value → 文本
	// （P3-2 引入）。P3-9 收尾时改名。
	return session_marshal(json.Value(doc), alloc), UCI_STATUS_OK
}

// 每次调用都要按 sid 切 delta 目录：上游在 read/write_access 里做（uci.c:311-337），
// 也就是**每个方法入口**。sid 为空（内部调用）时上游用 "/tmp/.uci"。
// linux 会真的切；darwin 是空实现（假数据没有 delta 存储）。
@(private)
uci_prepare_savedir :: proc(sid: string) {
	_ = uci_set_savedir(sid)
}

// 读权限：uci.c:311-320 —— session.access("uci", <config 名>, "read")。
// 返回 false 时调用方回 PERMISSION_DENIED(6)。sid 缺失 = 内部调用，不做访问控制。
// 顺带做了 savedir 切换（与上游 read_access 做的那两件事一一对应）。
@(private)
uci_check_read :: proc(sid, config: string) -> bool {
	uci_prepare_savedir(sid)
	if len(sid) == 0 {
		return true
	}
	ses := session_get(sid)
	return ses != nil && session_acl_allowed(ses, "uci", config, "read")
}

// 写权限：uci.c:327-337，同上但 function = "write"。
@(private)
uci_check_write :: proc(sid, config: string) -> bool {
	uci_prepare_savedir(sid)
	if len(sid) == 0 {
		return true
	}
	ses := session_get(sid)
	return ses != nil && session_acl_allowed(ses, "uci", config, "write")
}

// 取会话 id（方法入口统一先取它，再决定 ACL 与 savedir）。
@(private)
uci_sid_of :: proc(params: json.Object) -> (string, bool) {
	return uci_param_str(params, "ubus_rpc_session")
}

// uci.c:600-662 rpc_uci_getcommon。`get` 与 `state` 共用，只差「从哪读」：
//   get   → 当前配置（含本会话的 delta）
//   state → savedir 换成 /var/state，即**已提交**的状态（uci.c:619-620）
// 三条回复形态由 ptr 的层级决定：
//   package → {"values": {"<section>": {…, ".index": N}}}   （uci.c:640-642）
//   section → {"values": {…}}                              （uci.c:644-646）
//   option  → {"value": <字符串或数组>}                      （uci.c:648-650）
@(private)
uci_method_get :: proc(params: json.Object, alloc: mem.Allocator, from_state: bool) -> (string, int) {
	config, has_config := uci_param_str(params, "config")
	if !has_config {
		return "", UCI_STATUS_INVALID_ARGUMENT
	}

	sid, _ := uci_sid_of(params)
	if !uci_check_read(sid, config) {
		return "", UCI_STATUS_PERMISSION_DENIED
	}

	sections: []Uci_Section
	if from_state {
		status: int
		sections, status = uci_state_sections(config, alloc)
		if status != 0 {
			return "", status
		}
	} else {
		ok: bool
		sections, ok = uci_config_sections(config, alloc)
		if !ok {
			// uci_load 失败：libuci 置 UCI_ERR_NOTFOUND，上游映射成 4（uci.c:622-623、:252-253）
			return "", UCI_STATUS_NOT_FOUND
		}
	}

	if spec, has_section := uci_param_str(params, "section"); has_section {
		sec, found := uci_find_section(sections, spec)
		if !found {
			// rpc_uci_lookup 失败或 ptr 不完整（uci.c:633-634）
			return "", UCI_STATUS_NOT_FOUND
		}

		if option, has_option := uci_param_str(params, "option"); has_option {
			for o in sec.options {
				if o.name == option {
					doc := make(json.Object, 1, alloc)
					doc["value"] = uci_dump_option_json(o, alloc)
					return session_marshal(json.Value(doc), alloc), UCI_STATUS_OK
				}
			}
			return "", UCI_STATUS_NOT_FOUND
		}

		doc := make(json.Object, 1, alloc)
		doc["values"] = uci_dump_section_json(sec, -1, alloc)
		return session_marshal(json.Value(doc), alloc), UCI_STATUS_OK
	}

	type_name, _ := uci_param_str(params, "type")

	match: json.Object
	if v, found := params["match"]; found {
		if o, is_obj := v.(json.Object); is_obj {
			match = o
		}
	}

	doc := make(json.Object, 1, alloc)
	doc["values"] = uci_dump_package_json(sections, type_name, match, alloc)
	return session_marshal(json.Value(doc), alloc), UCI_STATUS_OK
}

// uci.c:1189-1222 rpc_uci_dump_change：
//   ["<type>", "<section>", "<name>?", "<value>?"]
// type 由 enum 决定（上游用指定初始化器把枚举值映射到字符串）。
// section 缺失时整个条目被丢掉（`:1202-1203`）；name 只在 d->e.name 非空时加。
@(private)
uci_dump_change_json :: proc(c: Uci_Change, alloc: mem.Allocator) -> json.Value {
	kind := "set"
	#partial switch c.kind {
	case .Add:
		kind = "add"
	case .Remove:
		kind = "remove"
	case .Change:
		kind = "set"
	case .Rename:
		kind = "rename"
	case .Reorder:
		kind = "order"
	case .List_Add:
		kind = "list-add"
	case .List_Del:
		kind = "list-del"
	}

	arr := make([dynamic]json.Value, 0, 4, alloc)
	append(&arr, json.Value(json.String(kind)))
	append(&arr, json.Value(json.String(c.section)))
	if len(c.name) > 0 {
		append(&arr, json.Value(json.String(c.name)))
	}
	if len(c.value) > 0 {
		// `order` 的 value 是序号：上游写成 u32（uci.c:1215-1216）
		if c.kind == .Reorder {
			if n, parsed := strconv.parse_int(c.value); parsed {
				append(&arr, json.Value(json.Integer(n)))
				return json.Value(json.Array(arr))
			}
		}
		append(&arr, json.Value(json.String(c.value)))
	}
	return json.Value(json.Array(arr))
}

// 一组 delta → JSON 数组（changes 的两处都用它）。
@(private)
uci_dump_changes_json :: proc(changes: []Uci_Change, alloc: mem.Allocator) -> json.Value {
	arr := make([dynamic]json.Value, 0, len(changes), alloc)
	for c in changes {
		// uci.c:1202-1203：没有 section 的 delta 整条丢掉（不进数组）
		if len(c.section) == 0 {
			continue
		}
		append(&arr, uci_dump_change_json(c, alloc))
	}
	return json.Value(json.Array(arr))
}

// uci.c:1224-1301 rpc_uci_changes。
//   给了 config → {"changes": [ … ]}（该 config 的 delta）
//   没给 config → {"changes": {<config>: [ … ], …}}：逐 config 做读权限过滤、
//                 没有 delta 的跳过；这条分支最后是 **return 0**（不是 rpc_uci_status）
@(private)
uci_method_changes :: proc(params: json.Object, alloc: mem.Allocator) -> (string, int) {
	sid, _ := uci_sid_of(params)

	if config, has_config := uci_param_str(params, "config"); has_config {
		if !uci_check_read(sid, config) {
			return "", UCI_STATUS_PERMISSION_DENIED
		}
		changes, status := uci_delta_changes(sid, config, alloc)
		if status != 0 {
			return "", status
		}
		doc := make(json.Object, 1, alloc)
		doc["changes"] = uci_dump_changes_json(changes, alloc)
		return session_marshal(json.Value(doc), alloc), UCI_STATUS_OK
	}

	uci_prepare_savedir(sid)

	names, ok := uci_list_configs(alloc)
	if !ok {
		return "", UCI_STATUS_UNKNOWN_ERROR
	}

	inner := make(json.Object, len(names), alloc)
	for n in names {
		// 没给 sid = 内部调用：上游只在 sid 存在时做权限过滤（uci.c:1273-1276）
		if len(sid) > 0 {
			ses := session_get(sid)
			if ses == nil || !session_acl_allowed(ses, "uci", n, "read") {
				continue
			}
		}
		changes, status := uci_delta_changes(sid, n, alloc)
		if status != 0 || len(changes) == 0 {
			continue
		}
		inner[n] = uci_dump_changes_json(changes, alloc)
	}

	doc := make(json.Object, 1, alloc)
	doc["changes"] = json.Value(inner)
	return session_marshal(json.Value(doc), alloc), UCI_STATUS_OK
}

// 「有一次 apply 在等 confirm」时记下发起者 sid（uci.c 的 apply_sid）。非空期间
// `commit`/`revert` 一律回 6（uci.c:1330-1331），发起者之外的人 confirm/rollback 也回 6。
// 由 uci_apply.odin 的 apply/confirm/rollback 维护。
@(private)
g_uci_apply_sid: string

@(private)
uci_apply_pending :: proc() -> bool {
	return len(g_uci_apply_sid) > 0
}

// uci.c:1324-1379 rpc_uci_revert_commit：`commit` 与 `revert` 共用。
//   有 apply 在等确认 → 6
//   缺 config        → 2
//   无写权限         → 6
//   然后交给平台侧执行（darwin 回 8：按决策，写路径只在 linux 上实现）
@(private)
uci_method_commit_or_revert :: proc(params: json.Object, alloc: mem.Allocator, commit: bool) -> (string, int) {
	if uci_apply_pending() {
		return "", UCI_STATUS_PERMISSION_DENIED
	}

	config, has_config := uci_param_str(params, "config")
	if !has_config {
		return "", UCI_STATUS_INVALID_ARGUMENT
	}

	sid, _ := uci_sid_of(params)
	if !uci_check_write(sid, config) {
		return "", UCI_STATUS_PERMISSION_DENIED
	}

	status := uci_commit(sid, config, alloc) if commit else uci_revert(sid, config, alloc)
	if status != 0 {
		return "", status
	}
	// 上游这两个方法**不回数据**（与 session 的 set/unset 同类）→ 平台层回空表
	return "", UCI_STATUS_OK
}

// /var/run/rpcd/uci-<sid>（uci.h 的 RPC_UCI_SAVEDIR_PREFIX）。
UCI_SAVEDIR_PREFIX :: "/var/run/rpcd/uci-"

// uci.c:1414-1441 rpc_uci_purge_dir：删目录里的**普通文件**再 rmdir
// （子目录跳过——上游也是 continue）。只有 linux 上有实际意义，但用 core:os 就够，
// 放平台无关处，顺带能在 macOS 上用临时目录单测。
uci_purge_dir :: proc(path: string, alloc: mem.Allocator) {
	dir, err := os.open(path)
	if err != nil {
		return
	}
	defer os.close(dir)

	names, _ := os.read_dir(dir, -1, alloc)
	for n in names {
		full := fmt.aprintf("%s/%s", path, n.name, allocator = alloc)
		info, serr := os.stat(full, alloc)
		if serr != nil || info.type != .Regular {
			continue
		}
		_ = os.remove(full)
	}
	_ = os.remove(path)
}

// uci.c:1739-1746 rpc_uci_purge_savedir_cb：会话销毁时清掉它的 delta 目录。
uci_purge_savedir :: proc(sid: string, alloc: mem.Allocator) {
	if len(sid) == 0 {
		return
	}
	uci_purge_dir(fmt.aprintf("%s%s", UCI_SAVEDIR_PREFIX, sid, allocator = alloc), alloc)
}

// uci 对象的调用入口。与 session_call 同形：平台层（darwin 的 /ubus 路由、
// linux 的 libubus handler）把入站 blobmsg 转成 JSON 文本调它，再拿回复文本回填。
uci_call :: proc(method: string, params_json: string, alloc: mem.Allocator) -> (reply: string, status: int) {
	params := make(json.Object, 0, alloc)
	if len(params_json) > 0 {
		doc: json.Value
		if err := json.unmarshal(transmute([]byte)(params_json), &doc, .JSON, alloc); err == nil {
			if obj, is_obj := doc.(json.Object); is_obj {
				params = obj
			}
		}
	}

	switch method {
	case "configs":
		return uci_method_configs(alloc)
	case "get":
		return uci_method_get(params, alloc, false)
	case "state":
		// 已提交态（savedir 换成 /var/state）；darwin 的 provider 回 8
		return uci_method_get(params, alloc, true)
	case "changes":
		return uci_method_changes(params, alloc)
	case "commit":
		return uci_method_commit_or_revert(params, alloc, true)
	case "revert":
		return uci_method_commit_or_revert(params, alloc, false)
	case "set":
		return uci_method_set(params, alloc)
	case "add":
		return uci_method_add(params, alloc)
	case "delete":
		return uci_method_delete(params, alloc)
	case "rename":
		return uci_method_rename(params, alloc)
	case "order":
		return uci_method_order(params, alloc)
	case "apply":
		return uci_method_apply(params, alloc)
	case "confirm":
		return uci_method_confirm(params, alloc)
	case "rollback":
		return uci_method_rollback(params, alloc)
	case "reload_config":
		return uci_method_reload_config(alloc)
	case:
		// 真机上 libubus 在 handler 之前就回了 3（METHOD_NOT_FOUND），
		// 这里保持一致（session_call 同）。
		return "", UCI_STATUS_METHOD_NOT_FOUND
	}
}
