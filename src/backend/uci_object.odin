package backend

// uci —— molly 自持的 ubus 对象（逐段对齐 internal/backend/uci_object.go）。
//
// 契约来源：rpcd@e37ed9d 的 uci.c。上游注册 15 个方法，这里同样 15 个：只读
// configs/get/state、changes/commit/revert、五个写操作 add/set/delete/rename/order、
// apply 系 apply/confirm/rollback/reload_config。
//
// 本文件**平台无关**：参数校验、ACL、JSON 成型都在这里；平台相关的 libuci / 假数据经
// uci_provider_* 钩子调用（宿主实现见 uci_provider_host.odin，阶段 3h 拆平台）。
//
// 顺序契约（必须保住）：参数校验与 ACL 在 provider **之前**，所以宿主上写方法即使
// provider 不支持，参数非法仍回 2、缺权限仍回 6，校验通过后才回 8。

import "core:fmt"
import "core:mem"
import "core:os"
import "core:sync"
import "core:strconv"
import "core:encoding/json"

uci_apply_timeout :: 60         // RPC_APPLY_TIMEOUT（秒）
uci_apply_max_ms  :: 2147483647

uci_snapshot_files_dir :: "/var/run/rpcd/snapshot-files/"
uci_snapshot_delta_dir :: "/var/run/rpcd/snapshot-delta/"
uci_config_dir         :: "/etc/config/"
uci_savedir_prefix     :: "/var/run/rpcd/uci-"

// ---------------------------------------------------------------------------
// 名称校验（uci.c:187-235）
// ---------------------------------------------------------------------------

uci_is_alnum :: proc(ch: u8) -> bool {
	return (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9')
}

// uci_verify_str 对应 rpc_uci_verify_str。extended 允许 `@type[idx]`（且只有以 '@' 开头才算扩展），
// section_type 额外允许 '-'（section 类型名可以带连字符，section 名不行）。
uci_verify_str :: proc(name: string, extended, section_type: bool) -> bool {
	if len(name) == 0 {
		return false
	}
	ext := extended && name[0] == '@'
	i := 0
	if ext {
		i = 1
	}
	for i < len(name) {
		ch := name[i]
		if !uci_is_alnum(ch) && ch != '_' && ((!section_type && !ext) || ch != '-') {
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
	j := i + 1
	k := j
	for k < len(name) && name[k] >= '0' && name[k] <= '9' {
		k += 1
	}
	return k > j && k+1 == len(name) && name[k] == ']'
}

uci_verify_name    :: proc(name: string) -> bool { return uci_verify_str(name, false, false) }
uci_verify_type    :: proc(t: string) -> bool    { return uci_verify_str(t, false, true) }
uci_verify_section :: proc(s: string) -> bool    { return uci_verify_str(s, true, false) }

// ---------------------------------------------------------------------------
// match / type 的筛选（uci.c:344-499）
// ---------------------------------------------------------------------------

// uci_match_option：list 型任一元素相等即命中；字符串型按空格/制表符切词，任一词相等即命中。
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
	for i := 0; i <= len(val); i += 1 {
		if i == len(val) || val[i] == ' ' || val[i] == '\t' {
			if i > start && val[start:i] == cmp {
				return true
			}
			start = i + 1
		}
	}
	return false
}

// uci_match_section：type 给了须相等；match 表里每个存在的键都要求命中；空/缺 match 恒匹配。
uci_match_section :: proc(s: Uci_Section, type_name: string, match: json.Object) -> bool {
	if len(type_name) > 0 && type_name != s.type_name {
		return false
	}
	if len(match) == 0 {
		return true
	}
	hit := false
	empty := true
	for key, val in match {
		cmp, ok := uci_format_blob(val)
		if !ok {
			continue
		}
		for o in s.options {
			if o.name != key {
				continue
			}
			if !uci_match_option(o, cmp) {
				return false
			}
			hit = true
		}
		empty = false
	}
	return empty || hit
}

// ---------------------------------------------------------------------------
// dump（uci.c:510-597）
// ---------------------------------------------------------------------------

uci_dump_option_json :: proc(o: Uci_Option) -> json.Value {
	if o.is_list {
		arr: json.Array = make(json.Array)
		for v in o.values {
			append(&arr, json.String(v))
		}
		return json.Value(arr)
	}
	if len(o.values) == 0 {
		return json.Value(json.String(""))
	}
	return json.Value(json.String(o.values[0]))
}

uci_dump_section_json :: proc(s: Uci_Section, index: int) -> json.Value {
	obj: json.Object = make(json.Object)
	obj[".anonymous"] = json.Boolean(s.anonymous)
	obj[".type"] = json.String(s.type_name)
	obj[".name"] = json.String(s.name)
	if index >= 0 {
		obj[".index"] = json.Integer(index)
	}
	for o in s.options {
		obj[o.name] = uci_dump_option_json(o)
	}
	return json.Value(obj)
}

uci_dump_package_json :: proc(sections: []Uci_Section, type_name: string, match: json.Object) -> json.Value {
	obj: json.Object = make(json.Object)
	for i := 0; i < len(sections); i += 1 {
		s := sections[i]
		if !uci_match_section(s, type_name, match) {
			continue
		}
		obj[s.name] = uci_dump_section_json(s, i)
	}
	return json.Value(obj)
}

// uci_find_section：具名直接查名字；`@type[idx]` 是同类型里的第 idx 个。
uci_find_section :: proc(sections: []Uci_Section, spec: string) -> (Uci_Section, bool) {
	if len(spec) == 0 {
		return Uci_Section{}, false
	}
	if spec[0] != '@' {
		for s in sections {
			if s.name == spec {
				return s, true
			}
		}
		return Uci_Section{}, false
	}
	open := -1
	for i := 0; i < len(spec); i += 1 {
		if spec[i] == '[' {
			open = i
			break
		}
	}
	if open <= 1 {
		return Uci_Section{}, false
	}
	rest := spec[open:]
	if len(rest) < 3 || rest[len(rest)-1] != ']' {
		return Uci_Section{}, false
	}
	idx, ok := strconv.parse_int(rest[1:len(rest)-1], 10)
	if !ok || idx < 0 {
		return Uci_Section{}, false
	}
	type_name := spec[1:open]
	n := 0
	for s in sections {
		if s.type_name != type_name {
			continue
		}
		if n == idx {
			return s, true
		}
		n += 1
	}
	return Uci_Section{}, false
}

// ---------------------------------------------------------------------------
// delta（changes）的七种类型（uci.c:1189-1301）
// ---------------------------------------------------------------------------

Uci_Change_Kind :: enum {
	Add,       // 0
	Remove,    // 1
	Change,    // 2 → "set"
	Rename,    // 3
	Reorder,   // 4
	List_Add,  // 5
	List_Del,  // 6
}

Uci_Change :: struct {
	kind:    Uci_Change_Kind,
	section: string,
	name:    string,
	value:   string,
}

uci_change_kind_name :: proc(k: Uci_Change_Kind) -> string {
	#partial switch k {
	case .Add:      return "add"
	case .Remove:   return "remove"
	case .Rename:   return "rename"
	case .Reorder:  return "order"
	case .List_Add: return "list-add"
	case .List_Del: return "list-del"
	}
	return "set"
}

// uci_dump_change_json：["<type>","<section>","<name>?","<value>?"]；order 的 value 是数字。
uci_dump_change_json :: proc(c: Uci_Change) -> json.Value {
	arr: json.Array = make(json.Array)
	append(&arr, json.String(uci_change_kind_name(c.kind)))
	append(&arr, json.String(c.section))
	if len(c.name) > 0 {
		append(&arr, json.String(c.name))
	}
	if len(c.value) > 0 {
		if c.kind == .Reorder {
			if n, ok := strconv.parse_int(c.value, 10); ok {
				append(&arr, json.Integer(n))
				return json.Value(arr)
			}
		}
		append(&arr, json.String(c.value))
	}
	return json.Value(arr)
}

// uci_dump_changes_json：没有 section 的 delta 整条丢掉（uci.c:1202-1203）。
uci_dump_changes_json :: proc(changes: []Uci_Change) -> json.Value {
	arr: json.Array = make(json.Array)
	for c in changes {
		if len(c.section) == 0 {
			continue
		}
		append(&arr, uci_dump_change_json(c))
	}
	return json.Value(arr)
}

// ---------------------------------------------------------------------------
// 参数小工具（uci 前缀，避免与 session 的 helper 撞名）
// ---------------------------------------------------------------------------

uci_raw_str :: proc(v: json.Value) -> (string, bool) {
	s, ok := v.(json.String)
	return string(s), ok
}

uci_param_object :: proc(o: json.Object, key: string) -> (json.Object, bool) {
	v, has := o[key]
	if !has {
		return nil, false
	}
	obj, is_obj := v.(json.Object)
	return obj, is_obj
}

uci_param_array :: proc(o: json.Object, key: string) -> (json.Array, bool) {
	v, has := o[key]
	if !has {
		return nil, false
	}
	arr, is_arr := v.(json.Array)
	return arr, is_arr
}

// uci_param_bool：字段不存在或不是 true 布尔都返回 false（blobmsg 策略类型不符丢字段）。
uci_param_bool :: proc(o: json.Object, key: string) -> bool {
	v, has := o[key]
	if !has {
		return false
	}
	b, ok := v.(json.Boolean)
	return ok && b
}

// ---------------------------------------------------------------------------
// ACL / savedir
// ---------------------------------------------------------------------------

uci_sid_of :: proc(o: json.Object) -> (string, bool) {
	return param_str(o, "ubus_rpc_session")
}

uci_check_read :: proc(sid, config: string) -> bool {
	uci_provider_savedir(sid)
	if len(sid) == 0 {
		return true
	}
	return session_access(sid, "uci", config, "read")
}

uci_check_write :: proc(sid, config: string) -> bool {
	uci_provider_savedir(sid)
	if len(sid) == 0 {
		return true
	}
	return session_access(sid, "uci", config, "write")
}

// ---------------------------------------------------------------------------
// 只读方法：configs / get / changes / commit / revert
// ---------------------------------------------------------------------------

// uci_method_configs：uci_list_configs → {"configs":[…]}；上游**不做** ACL。
uci_method_configs :: proc() -> (status: i32, reply: string) {
	names, ok := uci_provider_configs()
	if !ok {
		return Status_Unknown_Error, ""
	}
	arr: json.Array = make(json.Array)
	for n in names {
		append(&arr, json.String(n))
	}
	doc: json.Object = make(json.Object)
	doc["configs"] = json.Value(arr)
	return Status_OK, json_unparse(json.Value(doc))
}

// uci_method_get：`get`/`state` 共用，只差从哪读。回复形态由 ptr 层级决定。
uci_method_get :: proc(params: json.Object, from_state: bool) -> (status: i32, reply: string) {
	config, has_config := param_str(params, "config")
	if !has_config {
		return Status_Invalid_Argument, ""
	}
	sid, _ := uci_sid_of(params)
	if !uci_check_read(sid, config) {
		return Status_Permission_Denied, ""
	}

	sections: []Uci_Section
	if from_state {
		s, st := uci_provider_state_sections(config)
		if st != 0 {
			return st, ""
		}
		sections = s
	} else {
		s, ok := uci_provider_sections(config)
		if !ok {
			return Status_Not_Found, ""
		}
		sections = s
	}

	if spec, has_section := param_str(params, "section"); has_section {
		sec, found := uci_find_section(sections, spec)
		if !found {
			return Status_Not_Found, ""
		}
		if option, has_option := param_str(params, "option"); has_option {
			for o in sec.options {
				if o.name == option {
					doc: json.Object = make(json.Object)
					doc["value"] = uci_dump_option_json(o)
					return Status_OK, json_unparse(json.Value(doc))
				}
			}
			return Status_Not_Found, ""
		}
		doc: json.Object = make(json.Object)
		doc["values"] = uci_dump_section_json(sec, -1)
		return Status_OK, json_unparse(json.Value(doc))
	}

	type_name, _ := param_str(params, "type")
	match: json.Object
	if mv, found := params["match"]; found {
		if mo, is_obj := mv.(json.Object); is_obj {
			match = mo
		}
	}
	doc: json.Object = make(json.Object)
	doc["values"] = uci_dump_package_json(sections, type_name, match)
	return Status_OK, json_unparse(json.Value(doc))
}

// uci_method_changes：给了 config → {"changes":[…]}；没给 → {"changes":{<config>:[…],…}}。
uci_method_changes :: proc(params: json.Object) -> (status: i32, reply: string) {
	sid, _ := uci_sid_of(params)

	if config, has_config := param_str(params, "config"); has_config {
		if !uci_check_read(sid, config) {
			return Status_Permission_Denied, ""
		}
		changes, st := uci_provider_delta(sid, config)
		if st != 0 {
			return st, ""
		}
		doc: json.Object = make(json.Object)
		doc["changes"] = uci_dump_changes_json(changes)
		return Status_OK, json_unparse(json.Value(doc))
	}

	uci_provider_savedir(sid)
	names, ok := uci_provider_configs()
	if !ok {
		return Status_Unknown_Error, ""
	}
	inner: json.Object = make(json.Object)
	for n in names {
		if len(sid) > 0 && !session_access(sid, "uci", n, "read") {
			continue
		}
		changes, st := uci_provider_delta(sid, n)
		if st != 0 || len(changes) == 0 {
			continue
		}
		inner[n] = uci_dump_changes_json(changes)
	}
	doc: json.Object = make(json.Object)
	doc["changes"] = json.Value(inner)
	return Status_OK, json_unparse(json.Value(doc))
}

// ---------------------------------------------------------------------------
// 待确认 apply 的状态机（apply/confirm/rollback 维护；commit/revert 与之互斥）
// ---------------------------------------------------------------------------

uci_apply_mu:  sync.Mutex
uci_apply_sid: string
uci_apply_gen: int

uci_apply_pending :: proc() -> bool {
	sync.mutex_lock(&uci_apply_mu)
	defer sync.mutex_unlock(&uci_apply_mu)
	return len(uci_apply_sid) > 0
}

uci_apply_get_sid :: proc() -> string {
	sync.mutex_lock(&uci_apply_mu)
	defer sync.mutex_unlock(&uci_apply_mu)
	return uci_apply_sid
}

uci_apply_set_sid :: proc(sid: string) {
	sync.mutex_lock(&uci_apply_mu)
	defer sync.mutex_unlock(&uci_apply_mu)
	uci_apply_sid = sid
}

uci_apply_clear_sid :: proc() {
	sync.mutex_lock(&uci_apply_mu)
	defer sync.mutex_unlock(&uci_apply_mu)
	uci_apply_sid = ""
}

// uci_apply_timer_start / _cancel：推进代际号让「已取消的那次定时」醒来即退出。
// 真正的延迟回滚线程（sleep ms 后调 uci_apply_timeout_fired）在 linux 运行期接（阶段 3h）——
// 宿主上 apply 在列 delta 目录就回 4，永不进入这里，pending sid 恒空。
uci_apply_timer_start :: proc(ms: int) {
	_ = ms
	sync.mutex_lock(&uci_apply_mu)
	defer sync.mutex_unlock(&uci_apply_mu)
	uci_apply_gen += 1
}

uci_apply_timer_cancel :: proc() {
	sync.mutex_lock(&uci_apply_mu)
	defer sync.mutex_unlock(&uci_apply_mu)
	uci_apply_gen += 1
}

// ---------------------------------------------------------------------------
// commit / revert（uci.c:1324-1379）
// ---------------------------------------------------------------------------

uci_method_commit_or_revert :: proc(params: json.Object, commit: bool) -> (status: i32, reply: string) {
	if uci_apply_pending() {
		return Status_Permission_Denied, ""
	}
	config, has_config := param_str(params, "config")
	if !has_config {
		return Status_Invalid_Argument, ""
	}
	sid, _ := uci_sid_of(params)
	if !uci_check_write(sid, config) {
		return Status_Permission_Denied, ""
	}
	st: i32 = 0
	if commit {
		st = uci_provider_commit(sid, config)
	} else {
		st = uci_provider_revert(sid, config)
	}
	if st != 0 {
		return st, ""
	}
	return Status_OK, ""
}

// ---------------------------------------------------------------------------
// 写方法：set / add / delete / rename / order
// ---------------------------------------------------------------------------

uci_method_set :: proc(params: json.Object) -> (status: i32, reply: string) {
	config, has_config := param_str(params, "config")
	values, has_values := uci_param_object(params, "values")
	section, has_section := param_str(params, "section")
	type_name, has_type := param_str(params, "type")
	match, has_match := uci_param_object(params, "match")

	if !has_config || !has_values || (!has_section && !has_type && !has_match) {
		return Status_Invalid_Argument, ""
	}
	sid, _ := uci_sid_of(params)
	if !uci_check_write(sid, config) {
		return Status_Permission_Denied, ""
	}
	if has_section && !uci_verify_section(section) {
		return Status_Invalid_Argument, ""
	}

	txn, st := uci_provider_write_begin(sid, config)
	if st != 0 {
		return st, ""
	}
	defer uci_provider_write_end(txn)

	err: i32 = Status_OK
	hit := false
	if has_section {
		hit = true
		for key, val in values {
			if rv := uci_provider_write_merge_set(txn, section, key, val); rv != 0 {
				err = rv // 最后一个覆盖
			}
		}
	} else {
		sections, st2 := uci_provider_write_sections(txn)
		if st2 != 0 {
			return st2, ""
		}
		tn := ""
		if has_type {
			tn = type_name
		}
		for s in sections {
			if !uci_match_section(s, tn, match) {
				continue
			}
			hit = true
			for key, val in values {
				if rv := uci_provider_write_merge_set(txn, s.name, key, val); rv != 0 {
					err = rv
				}
			}
		}
	}

	if err != 0 {
		return err, ""
	}
	if !hit {
		return Status_Not_Found, ""
	}
	if st3 := uci_provider_write_save(txn); st3 != 0 {
		return st3, ""
	}
	return Status_OK, ""
}

uci_method_add :: proc(params: json.Object) -> (status: i32, reply: string) {
	config, has_config := param_str(params, "config")
	type_name, has_type := param_str(params, "type")
	if !has_config || !has_type {
		return Status_Invalid_Argument, ""
	}
	sid, _ := uci_sid_of(params)
	if !uci_check_write(sid, config) {
		return Status_Permission_Denied, ""
	}
	if !uci_verify_type(type_name) {
		return Status_Invalid_Argument, ""
	}
	name, has_name := param_str(params, "name")
	if has_name && !uci_verify_name(name) {
		return Status_Invalid_Argument, ""
	}

	txn, st := uci_provider_write_begin(sid, config)
	if st != 0 {
		return st, ""
	}
	defer uci_provider_write_end(txn)

	section_name, st2 := uci_provider_write_add_section(txn, type_name, name)
	if st2 != 0 {
		return st2, ""
	}

	err: i32 = Status_OK
	if values, has_values := uci_param_object(params, "values"); has_values {
		for key, val in values {
			if !uci_verify_name(key) {
				if err == 0 {
					err = Status_Invalid_Argument // 首个错误优先
				}
				continue
			}
			if rv := uci_provider_write_add_value(txn, section_name, key, val); rv != 0 && err == 0 {
				err = rv
			}
		}
	}
	if err != 0 {
		return err, ""
	}
	if st3 := uci_provider_write_save(txn); st3 != 0 {
		return st3, ""
	}
	doc: json.Object = make(json.Object)
	doc["section"] = json.String(section_name)
	return Status_OK, json_unparse(json.Value(doc))
}

Uci_Delete_Form :: enum {
	Section, // 删整个 section
	Option,  // 删具名 option
	Options, // 删多个 option
}

Uci_Delete_Plan :: struct {
	status: i32,
	form:   Uci_Delete_Form,
	names:  []string,
}

// uci_plan_merge_delete（uci.c:948-1006 的类型分流）：字符串→具名；数组→多个名字；其它→2。
uci_plan_merge_delete :: proc(raw: json.Value) -> Uci_Delete_Plan {
	if s, is_str := raw.(json.String); is_str {
		names := make([]string, 1, context.allocator)
		names[0] = string(s)
		return Uci_Delete_Plan{form = .Option, names = names}
	}
	if arr, is_arr := raw.(json.Array); is_arr {
		names: [dynamic]string
		for el in arr {
			if s, is_str := el.(json.String); is_str {
				append(&names, string(s))
			}
		}
		return Uci_Delete_Plan{form = .Options, names = names[:]}
	}
	return Uci_Delete_Plan{status = Status_Invalid_Argument}
}

// uci_delete_plan_of：options/option 折成删除计划；都没给 → 删整个 section。
uci_delete_plan_of :: proc(params: json.Object) -> Uci_Delete_Plan {
	if raw, has := params["options"]; has {
		if _, is_arr := raw.(json.Array); is_arr {
			return uci_plan_merge_delete(raw)
		}
	}
	if raw, has := params["option"]; has {
		if _, is_str := raw.(json.String); is_str {
			return uci_plan_merge_delete(raw)
		}
	}
	return Uci_Delete_Plan{form = .Section}
}

uci_method_delete :: proc(params: json.Object) -> (status: i32, reply: string) {
	config, has_config := param_str(params, "config")
	section, has_section := param_str(params, "section")
	type_name, has_type := param_str(params, "type")
	match, has_match := uci_param_object(params, "match")

	if !has_config || (!has_section && !has_type && !has_match) {
		return Status_Invalid_Argument, ""
	}
	sid, _ := uci_sid_of(params)
	if !uci_check_write(sid, config) {
		return Status_Permission_Denied, ""
	}
	if has_type && !uci_verify_type(type_name) {
		return Status_Invalid_Argument, ""
	}
	if has_section && !uci_verify_section(section) {
		return Status_Invalid_Argument, ""
	}
	plan := uci_delete_plan_of(params)
	if plan.status != 0 {
		return plan.status, ""
	}

	txn, st := uci_provider_write_begin(sid, config)
	if st != 0 {
		return st, ""
	}
	defer uci_provider_write_end(txn)

	err: i32 = Status_OK
	if has_section {
		err = uci_provider_write_delete(txn, section, plan.form, plan.names)
	} else {
		sections, st2 := uci_provider_write_sections(txn)
		if st2 != 0 {
			return st2, ""
		}
		tn := ""
		if has_type {
			tn = type_name
		}
		targets: [dynamic]string
		for s in sections {
			if !uci_match_section(s, tn, match) {
				continue
			}
			append(&targets, s.name)
		}
		if len(targets) == 0 {
			return Status_Not_Found, ""
		}
		for name in targets {
			if rv := uci_provider_write_delete(txn, name, plan.form, plan.names); rv != 0 {
				err = rv
			}
		}
	}
	if err != 0 {
		return err, ""
	}
	if st3 := uci_provider_write_save(txn); st3 != 0 {
		return st3, ""
	}
	return Status_OK, ""
}

uci_method_rename :: proc(params: json.Object) -> (status: i32, reply: string) {
	config, has_config := param_str(params, "config")
	section, has_section := param_str(params, "section")
	name, has_name := param_str(params, "name")
	if !has_config || !has_section || !has_name {
		return Status_Invalid_Argument, ""
	}
	sid, _ := uci_sid_of(params)
	if !uci_check_write(sid, config) {
		return Status_Permission_Denied, ""
	}
	if !uci_verify_name(name) {
		return Status_Invalid_Argument, ""
	}
	option, _ := param_str(params, "option")

	txn, st := uci_provider_write_begin(sid, config)
	if st != 0 {
		return st, ""
	}
	defer uci_provider_write_end(txn)

	if rv := uci_provider_write_rename(txn, section, option, name); rv != 0 {
		return rv, ""
	}
	if st2 := uci_provider_write_save(txn); st2 != 0 {
		return st2, ""
	}
	return Status_OK, ""
}

uci_method_order :: proc(params: json.Object) -> (status: i32, reply: string) {
	config, has_config := param_str(params, "config")
	list, has_list := uci_param_array(params, "sections")
	if !has_config || !has_list {
		return Status_Invalid_Argument, ""
	}
	sid, _ := uci_sid_of(params)
	if !uci_check_write(sid, config) {
		return Status_Permission_Denied, ""
	}

	txn, st := uci_provider_write_begin(sid, config)
	if st != 0 {
		return st, ""
	}
	defer uci_provider_write_end(txn)

	err: i32 = Status_OK
	pos := 0
	for el in list {
		name, is_str := uci_raw_str(el)
		if !is_str {
			if err == 0 {
				err = Status_Invalid_Argument // 首个错误优先
			}
			continue
		}
		if !uci_provider_write_reorder(txn, name, pos) {
			if err == 0 {
				err = Status_Not_Found
			}
			continue
		}
		pos += 1
	}
	if err != 0 {
		return err, ""
	}
	if st2 := uci_provider_write_save(txn); st2 != 0 {
		return st2, ""
	}
	return Status_OK, ""
}

// ---------------------------------------------------------------------------
// apply 系（uci.c:1443-1734）
// ---------------------------------------------------------------------------

// uci_list_snapshot_files：列目录里可用的文件名（跳过 dotfile 与空文件）。目录不存在 → false。
uci_list_snapshot_files :: proc(dir: string) -> (names: []string, ok: bool) {
	infos, err := os.read_all_directory_by_path(dir, context.allocator)
	if err != nil {
		return nil, false
	}
	out: [dynamic]string
	for info in infos {
		nm := info.name
		if len(nm) == 0 || nm[0] == '.' {
			continue
		}
		if info.size == 0 {
			continue
		}
		append(&out, nm)
	}
	return out[:], true
}

uci_copy_file :: proc(from_dir, to_dir, name: string) -> bool {
	data, err := os.read_entire_file(path_join(from_dir, name), context.allocator)
	if err != nil {
		return false
	}
	return os.write_entire_file(path_join(to_dir, name), data) == nil
}

// uci_purge_dir：删目录里的普通文件再 rmdir（子目录跳过——上游也是 continue）。
uci_purge_dir :: proc(path: string) {
	infos, err := os.read_all_directory_by_path(path, context.allocator)
	if err != nil {
		return
	}
	for info in infos {
		if info.type == .Directory {
			continue
		}
		os.remove(path_join(path, info.name))
	}
	os.remove(path)
}

// uci_apply_access：没有可用文件→5；有一个 config 没写权限→6；全有→0。
uci_apply_access :: proc(sid: string, names: []string) -> i32 {
	if len(names) == 0 {
		return Status_No_Data
	}
	for name in names {
		if !session_access(sid, "uci", name, "write") {
			return Status_Permission_Denied
		}
	}
	return Status_OK
}

// uci_do_rollback（uci.c:1507-1548）。
uci_do_rollback :: proc(names: []string) -> i32 {
	sid := uci_apply_get_sid()
	deny: i32 = Status_Not_Found
	if len(sid) > 0 {
		deny = uci_apply_access(sid, names)
	}
	savedir := fmt.tprintf("%s%s/", uci_savedir_prefix, sid)
	if deny == Status_OK {
		os.mkdir(savedir)
	}
	for name in names {
		uci_copy_file(uci_snapshot_files_dir, uci_config_dir, name)
		if st := uci_provider_apply_config(name, true); st != 0 {
			return st
		}
		if deny != Status_OK {
			continue
		}
		uci_copy_file(uci_snapshot_delta_dir, savedir, name)
	}
	uci_purge_dir(uci_snapshot_files_dir)
	uci_purge_dir(uci_snapshot_delta_dir)
	uci_apply_timer_cancel()
	uci_apply_clear_sid()
	return Status_OK
}

uci_method_apply :: proc(params: json.Object) -> (status: i32, reply: string) {
	rollback := uci_param_bool(params, "rollback")
	if uci_apply_pending() && rollback {
		return Status_Permission_Denied, ""
	}
	sid, has_sid := uci_sid_of(params)
	if !has_sid {
		return Status_Invalid_Argument, ""
	}
	timeout := uci_apply_timeout
	if n, ok := param_int(params, "timeout"); ok {
		timeout = n
	}

	uci_purge_dir(uci_snapshot_files_dir)
	uci_purge_dir(uci_snapshot_delta_dir)

	if uci_apply_pending() {
		return Status_OK, ""
	}

	savedir := fmt.tprintf("%s%s/", uci_savedir_prefix, sid)
	names, ok := uci_list_snapshot_files(savedir)
	if !ok {
		return Status_Not_Found, ""
	}
	if st := uci_apply_access(sid, names); st != 0 {
		return st, ""
	}

	os.mkdir(uci_snapshot_files_dir)
	os.mkdir(uci_snapshot_delta_dir)

	if rollback {
		uci_apply_set_sid(sid)
	}
	for name in names {
		uci_copy_file(uci_config_dir, uci_snapshot_files_dir, name)
		uci_copy_file(savedir, uci_snapshot_delta_dir, name)
		if st := uci_provider_apply_config(name, false); st != 0 {
			return st, ""
		}
	}
	if rollback {
		ms := uci_apply_max_ms
		if timeout > 0 && timeout <= uci_apply_max_ms/1000 {
			ms = timeout * 1000
		}
		uci_apply_timer_start(ms)
	}
	return Status_OK, ""
}

uci_method_confirm :: proc(params: json.Object) -> (status: i32, reply: string) {
	sid, has_sid := uci_sid_of(params)
	if !has_sid {
		return Status_Invalid_Argument, ""
	}
	if !uci_apply_pending() {
		return Status_No_Data, ""
	}
	if uci_apply_get_sid() != sid {
		return Status_Permission_Denied, ""
	}
	uci_purge_dir(uci_snapshot_files_dir)
	uci_purge_dir(uci_snapshot_delta_dir)
	uci_apply_timer_cancel()
	uci_apply_clear_sid()
	return Status_OK, ""
}

// uci_method_rollback：先判 pending（5），再判 sid 参数（2），与 confirm 相反。
uci_method_rollback :: proc(params: json.Object) -> (status: i32, reply: string) {
	if !uci_apply_pending() {
		return Status_No_Data, ""
	}
	sid, has_sid := uci_sid_of(params)
	if !has_sid {
		return Status_Invalid_Argument, ""
	}
	if uci_apply_get_sid() != sid {
		return Status_Permission_Denied, ""
	}
	names, ok := uci_list_snapshot_files(uci_snapshot_files_dir)
	if !ok {
		return Status_Not_Found, ""
	}
	if st := uci_do_rollback(names); st != 0 {
		return st, ""
	}
	return Status_OK, ""
}

uci_method_reload_config :: proc() -> (status: i32, reply: string) {
	if st := uci_provider_reload_config(); st != 0 {
		return st, ""
	}
	return Status_OK, ""
}

// ---------------------------------------------------------------------------
// 入口（注册为 "uci" 对象）
// ---------------------------------------------------------------------------

uci_handler :: proc(method, params_json: string, alloc: mem.Allocator) -> (status: i32, reply: string) {
	_ = alloc
	// 读路径的 config/section 来自 hook_uci_sections（宿主实现），它由 session_ensure_store
	// 安装。configs/get（无 sid）不走 session_access，故这里显式保证钩子就绪（幂等）。
	session_ensure_store()
	params: json.Object
	if len(params_json) > 0 {
		if v, err := json.parse_string(params_json, .JSON, true, context.allocator); err == nil {
			if o, ok := v.(json.Object); ok {
				params = o
			}
		}
	}
	if params == nil {
		params = make(json.Object)
	}

	switch method {
	case "configs":      return uci_method_configs()
	case "get":          return uci_method_get(params, false)
	case "state":        return uci_method_get(params, true)
	case "changes":      return uci_method_changes(params)
	case "commit":       return uci_method_commit_or_revert(params, true)
	case "revert":       return uci_method_commit_or_revert(params, false)
	case "set":          return uci_method_set(params)
	case "add":          return uci_method_add(params)
	case "delete":       return uci_method_delete(params)
	case "rename":       return uci_method_rename(params)
	case "order":        return uci_method_order(params)
	case "apply":        return uci_method_apply(params)
	case "confirm":      return uci_method_confirm(params)
	case "rollback":     return uci_method_rollback(params)
	case "reload_config": return uci_method_reload_config()
	}
	return Status_Method_Not_Found, ""
}
