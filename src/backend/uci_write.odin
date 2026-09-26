package backend

// ---------------------------------------------------------------------------
// uci 写路径的「计划层」（P3-3 S3，第一步）
//
// 这一层把「入站 JSON 值 + 现有 option 状态」映射成对 libuci 的**原子操作序列**，
// 不碰任何平台 API，所以能在 macOS 上单测。真正执行（`uci_set` / `uci_add_list` /
// `uci_delete` / `uci_save`）在 linux provider 里；darwin 永远回 `NOT_SUPPORTED(8)`。
//
// 契约：
//   uci.c:806-872  rpc_uci_merge_set    （`set` 的每个 values 键）
//   uci.c:948-1006 rpc_uci_merge_delete （`delete` 的 option/options）
// 每条分支都标了上游行号——改语义前先回去看那一行。
//
// 关于「错误时不执行操作」：上游在出错分支里可能**已经**调过 uci_delete
// （如 :834-837），但因为 `set` 只在 `!err` 时才 `uci_save`（:940-941），
// 那些内存里的改动不会落盘。molly 的做法是：status != 0 时根本不执行 ops
// —— 可观测行为一致（什么都没写），而且不会留下半执行的现场。
// ---------------------------------------------------------------------------

import "core:encoding/json"
import "core:mem"
import "core:strings"

// 现有 option 的状态。provider 查不到 option 时 exists = false。
Uci_Option_State :: struct {
	exists:  bool,
	is_list: bool,
	// 标量型的值（list 型不用它；C 只在 :867 拿它做「值没变就不 set」的比较）
	value:   string,
}

Uci_Merge_Op :: enum {
	Delete_Option, // uci_delete：删掉现有 option（标量或 list 都删）
	Set_Option, // uci_set（值取 item.value）
	Add_List, // uci_add_list（值取 item.value）
}

Uci_Merge_Op_Item :: struct {
	op:    Uci_Merge_Op,
	value: string,
}

Uci_Merge_Plan :: struct {
	// 非 0：直接把这个状态码回给调用方，ops 不执行
	status: int,
	// status == 0 时按顺序执行
	ops:    []Uci_Merge_Op_Item,
}

// uci.c:806-872 rpc_uci_merge_set 的决策部分。
//   1) 值是数组：先删掉现有 option（如果存在），再为每个**能格式化**的元素 add_list；
//      一个都格式化不了 → 2（数组全是不支持的类型）。
//   2) 值不是数组、但现有 option 是 list：删掉 list，再 set（list → 标量）。
//   3) 其它：现有值**相同**就什么都不做（上游 :867-868 的优化，避免产生无意义的 delta），
//      否则 set；格式化失败 → 2。
uci_plan_merge_set :: proc(
	value: json.Value,
	existing: Uci_Option_State,
	alloc: mem.Allocator,
) -> Uci_Merge_Plan {
	ops := make([dynamic]Uci_Merge_Op_Item, 0, 4, alloc)

	if arr, is_array := value.(json.Array); is_array {
		if existing.exists {
			append(&ops, Uci_Merge_Op_Item{op = .Delete_Option})
		}

		// 上游初值是 INVALID_ARGUMENT，靠「至少格式化成功一个元素」把它清成 0
		status := UCI_STATUS_INVALID_ARGUMENT
		for elem in arr {
			v, ok := uci_format_blob(elem, alloc)
			if !ok {
				continue
			}
			append(&ops, Uci_Merge_Op_Item{op = .Add_List, value = v})
			status = UCI_STATUS_OK
		}

		if status != UCI_STATUS_OK {
			return Uci_Merge_Plan{status = status}
		}
		return Uci_Merge_Plan{ops = ops[:]}
	}

	v, ok := uci_format_blob(value, alloc)
	if !ok {
		return Uci_Merge_Plan{status = UCI_STATUS_INVALID_ARGUMENT}
	}

	if existing.exists && existing.is_list {
		// list → 标量：先删 list 再 set
		both := make([]Uci_Merge_Op_Item, 2, alloc)
		both[0] = Uci_Merge_Op_Item{op = .Delete_Option}
		both[1] = Uci_Merge_Op_Item{op = .Set_Option, value = v}
		return Uci_Merge_Plan{ops = both}
	}

	if existing.exists && !existing.is_list && existing.value == v {
		// 值没变：上游不 emit set（否则每次 set 都会造出一条 delta）
		return Uci_Merge_Plan{}
	}

	one := make([]Uci_Merge_Op_Item, 1, alloc)
	one[0] = Uci_Merge_Op_Item{op = .Set_Option, value = v}
	return Uci_Merge_Plan{ops = one}
}

// uci.c:948-1006 rpc_uci_merge_delete 的决策部分。三种形态：
//   form = .Section      → 删整个 section（上游 opt == NULL，:963-970）
//   form = .Option       → 删具名 option（:993-1003）：找不到 → 4
//   form = .Options      → 逐个删数组里的名字（:971-992）：只有字符串元素算数，
//                         一个都没删到 → 4
Uci_Delete_Form :: enum {
	Section,
	Option,
	Options,
}

Uci_Delete_Plan :: struct {
	status: int, // 非 0 直接回（2：值类型不对）
	form:   Uci_Delete_Form,
	// Option / Options 形态要删的名字
	names:  []string,
}

// uci_plan_merge_delete 只看 JSON 值的**类型**（上游按 blobmsg_type 分流）：
// 字符串 → 具名；数组 → 多个名字（非字符串元素跳过）；其它类型 → 2。
uci_plan_merge_delete :: proc(value: json.Value, alloc: mem.Allocator) -> Uci_Delete_Plan {
	if s, is_string := value.(json.String); is_string {
		name := string(s)
		one := make([]string, 1, alloc)
		one[0] = name
		return Uci_Delete_Plan{form = .Option, names = one}
	}

	if arr, is_array := value.(json.Array); is_array {
		names := make([dynamic]string, 0, len(arr), alloc)
		for elem in arr {
			if s, is_string := elem.(json.String); is_string {
				append(&names, string(s))
			}
		}
		return Uci_Delete_Plan{form = .Options, names = names[:]}
	}

	return Uci_Delete_Plan{status = UCI_STATUS_INVALID_ARGUMENT}
}

// 删除的结果聚合（uci.c:973-991 的数组形态）：删到至少一个 → 0，一个都没有 → 4。
// 具名形态（:998-999）是「找不到就 4」，等价于 found 传 false。
uci_delete_status :: proc(found: bool) -> int {
	if found {
		return UCI_STATUS_OK
	}
	return UCI_STATUS_NOT_FOUND
}

// ---------------------------------------------------------------------------
// `add` 的 value 语义（与 merge_set **不一样**，uci.c:757-787）
//
//   merge_set：数组 → 先删旧 option 再逐个 add_list；标量 → 仅当值变化才 set
//   add      ：数组 → 直接逐个 add_list（**不删**旧值）；标量 → 直接 set（**不比**旧值）
//   并且 add 的错误聚合是「首个错误优先」（`if (!err) err = …`），
//   而 set 是「最后一个 rv 覆盖」（`err = rv`）——两者相反。
// ---------------------------------------------------------------------------

// uci.c:757-787。数组里**任何一个**元素不能格式化 → 整体 2（与 merge_set 的
// 「至少一个成功就算成功」相反）。
uci_plan_add_value :: proc(value: json.Value, alloc: mem.Allocator) -> Uci_Merge_Plan {
	ops := make([dynamic]Uci_Merge_Op_Item, 0, 4, alloc)

	if arr, is_array := value.(json.Array); is_array {
		status := UCI_STATUS_OK
		for elem in arr {
			v, ok := uci_format_blob(elem, alloc)
			if !ok {
				status = UCI_STATUS_INVALID_ARGUMENT
				continue
			}
			append(&ops, Uci_Merge_Op_Item{op = .Add_List, value = v})
		}
		if status != UCI_STATUS_OK {
			return Uci_Merge_Plan{status = status}
		}
		return Uci_Merge_Plan{ops = ops[:]}
	}

	v, ok := uci_format_blob(value, alloc)
	if !ok {
		return Uci_Merge_Plan{status = UCI_STATUS_INVALID_ARGUMENT}
	}

	one := make([]Uci_Merge_Op_Item, 1, alloc)
	one[0] = Uci_Merge_Op_Item{op = .Set_Option, value = v}
	return Uci_Merge_Plan{ops = one}
}

// ---------------------------------------------------------------------------
// `keys`①：`values` / `match` 这类**表**型入参（策略里是 BLOBMSG_TYPE_TABLE）。
// 上游的类型不符时 blobmsg_parse 会把字段丢掉，所以这里「不是对象」= 没有这个参数。
// ---------------------------------------------------------------------------

@(private)
uci_param_table :: proc(params: json.Object, key: string) -> (json.Object, bool) {
	v, found := params[key]
	if !found {
		return nil, false
	}
	o, is_obj := v.(json.Object)
	if !is_obj {
		return nil, false
	}
	return o, true
}

// ---------------------------------------------------------------------------
// 写方法：`set` 与 `add`
//
// 平台无关的方法层：参数校验 + ACL + 聚合规则（两者相反！）都在这里，
// 真正的 libuci 调用走 uci_write_* provider（darwin 侧全部回 NOT_SUPPORTED(8)）。
// 写事务（begin/end）保证「一个方法一次 load、一次 save」——与上游一致。
// ---------------------------------------------------------------------------

// uci.c:875-946 rpc_uci_set。注意两点：
//   1) 错误聚合是**最后一个 rv 覆盖**（`:913`、`:932`），与 add 相反；
//   2) 成功时**不发回复**（整个函数没有 ubus_send_reply）。
@(private)
uci_method_set :: proc(params: json.Object, alloc: mem.Allocator) -> (string, int) {
	config, has_config := uci_param_str(params, "config")
	values, has_values := uci_param_table(params, "values")
	section, has_section := uci_param_str(params, "section")
	type_name, has_type := uci_param_str(params, "type")
	match, has_match := uci_param_table(params, "match")

	if !has_config || !has_values || (!has_section && !has_type && !has_match) {
		return "", UCI_STATUS_INVALID_ARGUMENT
	}

	sid, _ := uci_sid_of(params)
	if !uci_check_write(sid, config) {
		return "", UCI_STATUS_PERMISSION_DENIED
	}

	if has_section && !uci_verify_section(section) {
		return "", UCI_STATUS_INVALID_ARGUMENT
	}

	txn, status := uci_write_begin(sid, config, alloc)
	if status != 0 {
		return "", status
	}
	defer uci_write_end(txn)

	err := UCI_STATUS_OK
	hit := false

	if has_section {
		hit = true
		for key, val in values {
			rv := uci_write_merge_set(txn, section, key, val, alloc)
			if rv != 0 {
				err = rv // 最后一个覆盖
			}
		}
	} else {
		sections, st := uci_write_sections(txn, alloc)
		if st != 0 {
			return "", st
		}
		for s in sections {
			if !uci_match_section(s, has_type ? type_name : "", match, alloc) {
				continue
			}
			hit = true
			for key, val in values {
				rv := uci_write_merge_set(txn, s.name, key, val, alloc)
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
		return "", UCI_STATUS_NOT_FOUND
	}
	if st := uci_write_save(txn); st != 0 {
		return "", st
	}
	return "", UCI_STATUS_OK
}

// uci.c:681-804 rpc_uci_add。与 set 的差别：
//   1) `config` 与 `type` 都是必需；
//   2) 具名 section 用 `uci_set`（ptr.value = type）创建，匿名用 `uci_add_section`；
//   3) `values` 可选；每个键先 verify_name，再按 add 的 value 语义写；
//   4) 错误聚合是**首个错误优先**；
//   5) 成功时回 `{"section": "<section 名>"}`。
@(private)
uci_method_add :: proc(params: json.Object, alloc: mem.Allocator) -> (string, int) {
	config, has_config := uci_param_str(params, "config")
	type_name, has_type := uci_param_str(params, "type")

	if !has_config || !has_type {
		return "", UCI_STATUS_INVALID_ARGUMENT
	}

	sid, _ := uci_sid_of(params)
	if !uci_check_write(sid, config) {
		return "", UCI_STATUS_PERMISSION_DENIED
	}

	if !uci_verify_type(type_name) {
		return "", UCI_STATUS_INVALID_ARGUMENT
	}

	name, has_name := uci_param_str(params, "name")
	if has_name && !uci_verify_name(name) {
		return "", UCI_STATUS_INVALID_ARGUMENT
	}

	txn, status := uci_write_begin(sid, config, alloc)
	if status != 0 {
		return "", status
	}
	defer uci_write_end(txn)

	section_name, st := uci_write_add_section(txn, type_name, has_name ? name : "", alloc)
	if st != 0 {
		return "", st
	}

	err := UCI_STATUS_OK
	if values, has_values := uci_param_table(params, "values"); has_values {
		for key, val in values {
			if !uci_verify_name(key) {
				if err == 0 {
					err = UCI_STATUS_INVALID_ARGUMENT
				}
				continue
			}
			rv := uci_write_add_value(txn, section_name, key, val, alloc)
			if rv != 0 && err == 0 {
				err = rv
			}
		}
	}

	if err != 0 {
		return "", err
	}
	if st := uci_write_save(txn); st != 0 {
		return "", st
	}

	doc := make(json.Object, 1, alloc)
	doc["section"] = json.Value(json.String(section_name))
	return session_marshal(json.Value(doc), alloc), UCI_STATUS_OK
}

// `options` 是**数组**（策略里 BLOBMSG_TYPE_ARRAY），不是表。
@(private)
uci_param_array :: proc(params: json.Object, key: string) -> (json.Array, bool) {
	v, found := params[key]
	if !found {
		return nil, false
	}
	arr, is_arr := v.(json.Array)
	if !is_arr {
		return nil, false
	}
	return arr, true
}

// 把 option/options 两个参数折成一份删除计划（uci.c:1046-1049）；
// 两个都没给 → 删整个 section（上游把 NULL 的 blob 交给 merge_delete，:963-970）。
@(private)
uci_delete_plan_of :: proc(params: json.Object, alloc: mem.Allocator) -> (Uci_Delete_Plan, bool) {
	if arr, has_options := uci_param_array(params, "options"); has_options {
		return uci_plan_merge_delete(json.Value(arr), alloc), true
	}
	if option, has_option := uci_param_str(params, "option"); has_option {
		return uci_plan_merge_delete(json.Value(json.String(option)), alloc), true
	}
	return Uci_Delete_Plan{form = .Section}, true
}

// uci.c:1008-1078 rpc_uci_delete。要点：
//   * 与 `set` 一样用**最后一个错误覆盖**（`:1047`、`:1063`）；
//   * 没有 section 时按 type/match 遍历（上游用 uci_foreach_element_safe 边走边删，
//     我们这边是快照，所以先把命中项的名字克隆出来再删——见下面的注释）；
//   * 一个 section 都没命中 → 4（`:1068-1069`）；
//   * 成功不发回复。
@(private)
uci_method_delete :: proc(params: json.Object, alloc: mem.Allocator) -> (string, int) {
	config, has_config := uci_param_str(params, "config")
	section, has_section := uci_param_str(params, "section")
	type_name, has_type := uci_param_str(params, "type")
	match, has_match := uci_param_table(params, "match")

	if !has_config || (!has_section && !has_type && !has_match) {
		return "", UCI_STATUS_INVALID_ARGUMENT
	}

	sid, _ := uci_sid_of(params)
	if !uci_check_write(sid, config) {
		return "", UCI_STATUS_PERMISSION_DENIED
	}

	if has_type && !uci_verify_type(type_name) {
		return "", UCI_STATUS_INVALID_ARGUMENT
	}
	if has_section && !uci_verify_section(section) {
		return "", UCI_STATUS_INVALID_ARGUMENT
	}

	plan, _ := uci_delete_plan_of(params, alloc)
	if plan.status != 0 {
		return "", plan.status
	}

	txn, status := uci_write_begin(sid, config, alloc)
	if status != 0 {
		return "", status
	}
	defer uci_write_end(txn)

	err := UCI_STATUS_OK

	if has_section {
		err = uci_write_delete(txn, section, plan.form, plan.names, alloc)
	} else {
		sections, st := uci_write_sections(txn, alloc)
		if st != 0 {
			return "", st
		}

		// 先把命中的 section 名克隆出来，再做删除动作。原因：uci_write_sections 返回的
		// 字符串是**指向 libuci 内存的视图**，而删 section 会释放它们。上游靠
		// uci_foreach_element_safe（先缓存 next 再删当前）边走边删避开这一点；
		// 我们这边是快照，所以在两次遍历之间自己拷贝一次。
		targets := make([dynamic]string, 0, len(sections), alloc)
		for s in sections {
			if !uci_match_section(s, has_type ? type_name : "", match, alloc) {
				continue
			}
			append(&targets, strings.clone(s.name, alloc))
		}

		if len(targets) == 0 {
			return "", UCI_STATUS_NOT_FOUND
		}
		for name in targets {
			rv := uci_write_delete(txn, name, plan.form, plan.names, alloc)
			if rv != 0 {
				err = rv
			}
		}
	}

	if err != 0 {
		return "", err
	}
	if st := uci_write_save(txn); st != 0 {
		return "", st
	}
	return "", UCI_STATUS_OK
}

// uci.c:1080-1129 rpc_uci_rename。要点：name 过 verify_name（**不**校验 section 语法）；
// 上游用 `(ptr.option && !ptr.o) || !ptr.s` → 4；成功不发回复。
@(private)
uci_method_rename :: proc(params: json.Object, alloc: mem.Allocator) -> (string, int) {
	config, has_config := uci_param_str(params, "config")
	section, has_section := uci_param_str(params, "section")
	name, has_name := uci_param_str(params, "name")

	if !has_config || !has_section || !has_name {
		return "", UCI_STATUS_INVALID_ARGUMENT
	}

	sid, _ := uci_sid_of(params)
	if !uci_check_write(sid, config) {
		return "", UCI_STATUS_PERMISSION_DENIED
	}

	if !uci_verify_name(name) {
		return "", UCI_STATUS_INVALID_ARGUMENT
	}

	option, has_option := uci_param_str(params, "option")

	txn, status := uci_write_begin(sid, config, alloc)
	if status != 0 {
		return "", status
	}
	defer uci_write_end(txn)

	if rv := uci_write_rename(txn, section, has_option ? option : "", name, alloc); rv != 0 {
		return "", rv
	}
	if st := uci_write_save(txn); st != 0 {
		return "", st
	}
	return "", UCI_STATUS_OK
}

// uci.c:1131-1186 rpc_uci_order。要点：
//   * 非字符串元素 → 2（**首个**错误优先，`:1158-1164`）；
//   * lookup 不到 section → 4（同样首个优先，`:1169-1175`）；
//   * 位置计数 `i` 只对**成功**的项递增（`:1177`）；
//   * 成功不发回复。
@(private)
uci_method_order :: proc(params: json.Object, alloc: mem.Allocator) -> (string, int) {
	config, has_config := uci_param_str(params, "config")
	list, has_list := uci_param_array(params, "sections")

	if !has_config || !has_list {
		return "", UCI_STATUS_INVALID_ARGUMENT
	}

	sid, _ := uci_sid_of(params)
	if !uci_check_write(sid, config) {
		return "", UCI_STATUS_PERMISSION_DENIED
	}

	txn, status := uci_write_begin(sid, config, alloc)
	if status != 0 {
		return "", status
	}
	defer uci_write_end(txn)

	err := UCI_STATUS_OK
	pos := 0
	for elem in list {
		name, is_string := elem.(json.String)
		if !is_string {
			if err == 0 {
				err = UCI_STATUS_INVALID_ARGUMENT
			}
			continue
		}
		if !uci_write_reorder(txn, string(name), pos, alloc) {
			if err == 0 {
				err = UCI_STATUS_NOT_FOUND
			}
			continue
		}
		pos += 1
	}

	if err != 0 {
		return "", err
	}
	if st := uci_write_save(txn); st != 0 {
		return "", st
	}
	return "", UCI_STATUS_OK
}
