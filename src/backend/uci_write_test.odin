package backend

// P3-3（S3 第一步）的单元测试：写路径的**计划层**（uci_write.odin）。
//
// 这一层是纯函数：入站 JSON 值 + 现有 option 状态 → 对 libuci 的操作序列。
// 契约逐条对应 uci.c:806-872（merge_set）与 :948-1006（merge_delete）。

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:testing"

@(private)
w_val :: proc(text: string, alloc: mem.Allocator) -> json.Value {
	return parse_json_value(text, alloc)
}

// 把 ops 渲染成便于断言的文本："Delete,Set=static" / "Add_List=a,Add_List=b"
@(private)
w_ops :: proc(plan: Uci_Merge_Plan, alloc: mem.Allocator) -> string {
	if len(plan.ops) == 0 {
		return "<none>"
	}
	out := ""
	for item, i in plan.ops {
		if i > 0 {
			out = fmt.aprintf("%s,%s", out, w_op_name(item, alloc), allocator = alloc)
		} else {
			out = w_op_name(item, alloc)
		}
	}
	return out
}

@(private)
w_op_name :: proc(item: Uci_Merge_Op_Item, alloc: mem.Allocator) -> string {
	switch item.op {
	case .Delete_Option:
		return "Delete"
	case .Set_Option:
		return fmt.aprintf("Set=%s", item.value, allocator = alloc)
	case .Add_List:
		return fmt.aprintf("AddList=%s", item.value, allocator = alloc)
	}
	return "?"
}

@(test)
test_uci_plan_merge_set :: proc(t: ^testing.T) {
	alloc, ar := mk_arena()
	defer drop_arena(ar)

	absent := Uci_Option_State{}

	scalar_existing := Uci_Option_State{exists = true, value = "static"}
	list_existing := Uci_Option_State{exists = true, is_list = true}

	// 1) 标量 + 不存在 → 一条 Set
	plan := uci_plan_merge_set(w_val(`"dhcp"`, alloc), absent, alloc)
	testing.expect_value(t, plan.status, UCI_STATUS_OK)
	testing.expect_value(t, w_ops(plan, alloc), "Set=dhcp")

	// 2) 标量 + 现有值相同 → **什么都不做**（上游 :867-868，否则每次 set 都造一条 delta）
	plan = uci_plan_merge_set(w_val(`"static"`, alloc), scalar_existing, alloc)
	testing.expect_value(t, plan.status, UCI_STATUS_OK)
	testing.expect_value(t, w_ops(plan, alloc), "<none>")

	// 3) 标量 + 现有值不同 → Set
	plan = uci_plan_merge_set(w_val(`"dhcp"`, alloc), scalar_existing, alloc)
	testing.expect_value(t, w_ops(plan, alloc), "Set=dhcp")

	// 4) 标量 + 现有是 list → 先删再 set（list → 标量，uci.c:852-861）
	plan = uci_plan_merge_set(w_val(`"dhcp"`, alloc), list_existing, alloc)
	testing.expect_value(t, w_ops(plan, alloc), "Delete,Set=dhcp")

	// 5) 数组 + 不存在 → 逐个 add_list（uci.c:832-851）
	plan = uci_plan_merge_set(w_val(`["1.1.1.1","8.8.8.8"]`, alloc), absent, alloc)
	testing.expect_value(t, plan.status, UCI_STATUS_OK)
	testing.expect_value(t, w_ops(plan, alloc), "AddList=1.1.1.1,AddList=8.8.8.8")

	// 6) 数组 + 现有 option → 先删（无论它是不是 list）再 add_list
	plan = uci_plan_merge_set(w_val(`["1.1.1.1"]`, alloc), scalar_existing, alloc)
	testing.expect_value(t, w_ops(plan, alloc), "Delete,AddList=1.1.1.1")

	// 7) 数字/bool 也能格式化（_format_blob 的 INT/INT8 分支）
	plan = uci_plan_merge_set(w_val(`60`, alloc), absent, alloc)
	testing.expect_value(t, w_ops(plan, alloc), "Set=60")
	plan = uci_plan_merge_set(w_val(`true`, alloc), absent, alloc)
	testing.expect_value(t, w_ops(plan, alloc), "Set=1")

	// 8) 数组里混着不能格式化的元素：能格式化的照加，且整体算成功（上游 rv 被清成 0）
	plan = uci_plan_merge_set(w_val(`["ok",1.5,{}]`, alloc), absent, alloc)
	testing.expect_value(t, plan.status, UCI_STATUS_OK)
	testing.expect_value(t, w_ops(plan, alloc), "AddList=ok")

	// 9) 数组里一个都不能格式化 → 2（含空数组：上游 rv 初值就是 2）
	plan = uci_plan_merge_set(w_val(`[1.5,{}]`, alloc), absent, alloc)
	testing.expect_value(t, plan.status, UCI_STATUS_INVALID_ARGUMENT)
	testing.expect_value(t, len(plan.ops), 0)
	plan = uci_plan_merge_set(w_val(`[]`, alloc), absent, alloc)
	testing.expect_value(t, plan.status, UCI_STATUS_INVALID_ARGUMENT)

	// 10) 标量本身不能格式化（浮点：C 的 switch 没有 DOUBLE 分支）→ 2
	plan = uci_plan_merge_set(w_val(`1.5`, alloc), absent, alloc)
	testing.expect_value(t, plan.status, UCI_STATUS_INVALID_ARGUMENT)
	plan = uci_plan_merge_set(w_val(`{}`, alloc), absent, alloc)
	testing.expect_value(t, plan.status, UCI_STATUS_INVALID_ARGUMENT)
}

@(test)
test_uci_plan_merge_delete :: proc(t: ^testing.T) {
	alloc, ar := mk_arena()
	defer drop_arena(ar)

	// 字符串 → 具名删一个（uci.c:993-1003）
	plan := uci_plan_merge_delete(w_val(`"dns"`, alloc), alloc)
	testing.expect_value(t, plan.status, UCI_STATUS_OK)
	testing.expect_value(t, plan.form, Uci_Delete_Form.Option)
	testing.expect_value(t, len(plan.names), 1)
	testing.expect_value(t, plan.names[0], "dns")

	// 数组 → 多个名字；非字符串元素跳过（uci.c:975-979）
	plan = uci_plan_merge_delete(w_val(`["dns","mtu",1.5,true]`, alloc), alloc)
	testing.expect_value(t, plan.form, Uci_Delete_Form.Options)
	testing.expect_value(t, len(plan.names), 2)
	testing.expect_value(t, plan.names[0], "dns")
	testing.expect_value(t, plan.names[1], "mtu")

	// 空数组 → Options 形态但一个名字都没有（上游：rv 保持 4 → 调用方回 4）
	plan = uci_plan_merge_delete(w_val(`[]`, alloc), alloc)
	testing.expect_value(t, plan.form, Uci_Delete_Form.Options)
	testing.expect_value(t, len(plan.names), 0)

	// 其它类型 → 2（uci.c:1005）
	plan = uci_plan_merge_delete(w_val(`42`, alloc), alloc)
	testing.expect_value(t, plan.status, UCI_STATUS_INVALID_ARGUMENT)
	plan = uci_plan_merge_delete(w_val(`{}`, alloc), alloc)
	testing.expect_value(t, plan.status, UCI_STATUS_INVALID_ARGUMENT)

	// 聚合：删到至少一个 → 0；一个都没有 → 4（uci.c:973-991）
	testing.expect_value(t, uci_delete_status(true), UCI_STATUS_OK)
	testing.expect_value(t, uci_delete_status(false), UCI_STATUS_NOT_FOUND)
}

@(test)
test_uci_plan_add_value :: proc(t: ^testing.T) {
	alloc, ar := mk_arena()
	defer drop_arena(ar)

	// 数组：直接逐个 add_list，**不删**旧值（与 merge_set 的 :832-837 相反，uci.c:757-773）
	plan := uci_plan_add_value(w_val(`["a","b"]`, alloc), alloc)
	testing.expect_value(t, plan.status, UCI_STATUS_OK)
	testing.expect_value(t, w_ops(plan, alloc), "AddList=a,AddList=b")

	// 数组里**任何一个**元素不能格式化 → 整体 2（与 merge_set 的「至少一个成功」相反，:762-768）
	plan = uci_plan_add_value(w_val(`["a",1.5]`, alloc), alloc)
	testing.expect_value(t, plan.status, UCI_STATUS_INVALID_ARGUMENT)
	testing.expect_value(t, len(plan.ops), 0)
	plan = uci_plan_add_value(w_val(`[]`, alloc), alloc)
	testing.expect_value(t, plan.status, UCI_STATUS_OK)
	testing.expect_value(t, len(plan.ops), 0)

	// 标量：直接 set，不做「值没变就不写」的比较（:775-786）
	plan = uci_plan_add_value(w_val(`"static"`, alloc), alloc)
	testing.expect_value(t, plan.status, UCI_STATUS_OK)
	testing.expect_value(t, w_ops(plan, alloc), "Set=static")
	plan = uci_plan_add_value(w_val(`1.5`, alloc), alloc)
	testing.expect_value(t, plan.status, UCI_STATUS_INVALID_ARGUMENT)
}

@(test)
test_uci_write_method_validation :: proc(t: ^testing.T) {
	alloc, ar := mk_arena()
	defer drop_arena(ar)

	// --- 参数校验在 ACL 之前（无 sid 也能测出 2）---
	testing.expect_value(t, uci_call_status(t, "set", `{}`, alloc), UCI_STATUS_INVALID_ARGUMENT)
	testing.expect_value(
		t,
		uci_call_status(t, "set", `{"config":"network","values":{"proto":"static"}}`, alloc),
		UCI_STATUS_INVALID_ARGUMENT, // 既没 section 也没 type/match
	)
	testing.expect_value(
		t,
		uci_call_status(t, "set", `{"config":"network","values":[],"section":"lan"}`, alloc),
		UCI_STATUS_INVALID_ARGUMENT, // values 不是表
	)
	testing.expect_value(
		t,
		uci_call_status(t, "set", `{"config":"network","values":{"a":"b"},"section":"lan[0]"}`, alloc),
		UCI_STATUS_INVALID_ARGUMENT, // section 不是合法 id（扩展形式必须以 @ 开头）
	)
	testing.expect_value(t, uci_call_status(t, "add", `{"config":"network"}`, alloc), UCI_STATUS_INVALID_ARGUMENT)
	testing.expect_value(
		t,
		uci_call_status(t, "add", `{"config":"network","type":"wifi-iface[0]"}`, alloc),
		UCI_STATUS_INVALID_ARGUMENT, // type 不是合法类型名
	)
	testing.expect_value(
		t,
		uci_call_status(t, "add", `{"config":"network","type":"interface","name":"lan-x"}`, alloc),
		UCI_STATUS_INVALID_ARGUMENT, // section 名不允许 '-'
	)

	// --- 有 sid 但没写权限 → 6（校验都过了才会走到 ACL）---
	sid := w_new_session(t, alloc)
	q := fmt.aprintf(`"ubus_rpc_session":"%s",`, sid, allocator = alloc)
	body := fmt.aprintf(`{{%s"config":"network","values":{{"proto":"static"}},"section":"lan"}}`, q, allocator = alloc)
	testing.expect_value(t, uci_call_status(t, "set", body, alloc), UCI_STATUS_PERMISSION_DENIED)

	add_body := fmt.aprintf(`{{%s"config":"network","type":"interface","name":"molly0"}}`, q, allocator = alloc)
	testing.expect_value(t, uci_call_status(t, "add", add_body, alloc), UCI_STATUS_PERMISSION_DENIED)

	// --- 授权写之后：darwin 没有写事务 → 8（linux 上这里会真的写 delta）---
	sid_body := fmt.aprintf(`{{"ubus_rpc_session":"%s"}}`, sid, allocator = alloc)
	_, gst := session_call(
		"grant",
		fmt.aprintf(
			`{{"ubus_rpc_session":"%s","scope":"uci","objects":[["*","write"]]}}`,
			sid,
			allocator = alloc,
		),
		alloc,
	)
	testing.expect_value(t, gst, SESSION_STATUS_OK)

	testing.expect_value(t, uci_call_status(t, "set", body, alloc), UCI_STATUS_NOT_SUPPORTED)
	testing.expect_value(t, uci_call_status(t, "add", add_body, alloc), UCI_STATUS_NOT_SUPPORTED)

	// 清场
	_, dst := session_call("destroy", sid_body, alloc)
	testing.expect_value(t, dst, SESSION_STATUS_OK)
}

// 只取状态码（写方法成功时 set 没有回复数据、add 有，这里不关心回复）
@(private)
uci_call_status :: proc(t: ^testing.T, method, params: string, alloc: mem.Allocator) -> int {
	_, status := uci_call(method, params, alloc)
	return status
}

// 建一个干净会话（没有任何 ACL），返回 sid
@(private)
w_new_session :: proc(t: ^testing.T, alloc: mem.Allocator) -> string {
	reply, status := session_call("create", `{}`, alloc)
	testing.expect_value(t, status, SESSION_STATUS_OK)

	doc: json.Value
	testing.expect(t, json.unmarshal(transmute([]byte)(reply), &doc, .JSON, alloc) == nil)
	obj, is_obj := doc.(json.Object)
	testing.expect(t, is_obj)
	if !is_obj {
		return ""
	}
	sid, _ := obj["ubus_rpc_session"].(json.String)
	return string(sid)
}

@(test)
test_uci_delete_rename_order_validation :: proc(t: ^testing.T) {
	alloc, ar := mk_arena()
	defer drop_arena(ar)

	// --- 必需参数缺失（在 ACL 之前：无 sid 也能测出 2）---
	testing.expect_value(t, uci_call_status(t, "delete", `{}`, alloc), UCI_STATUS_INVALID_ARGUMENT)
	testing.expect_value(
		t,
		uci_call_status(t, "delete", `{"config":"network"}`, alloc),
		UCI_STATUS_INVALID_ARGUMENT, // 既没 section 也没 type/match
	)
	testing.expect_value(t, uci_call_status(t, "rename", `{}`, alloc), UCI_STATUS_INVALID_ARGUMENT)
	testing.expect_value(
		t,
		uci_call_status(t, "rename", `{"config":"network","section":"lan"}`, alloc),
		UCI_STATUS_INVALID_ARGUMENT, // 缺 name
	)
	testing.expect_value(t, uci_call_status(t, "order", `{}`, alloc), UCI_STATUS_INVALID_ARGUMENT)
	testing.expect_value(
		t,
		uci_call_status(t, "order", `{"config":"network","sections":"lan"}`, alloc),
		UCI_STATUS_INVALID_ARGUMENT, // sections 不是数组
	)

	// --- 无 sid（内部调用）→ 语法校验：type/section/name ---
	testing.expect_value(
		t,
		uci_call_status(t, "delete", `{"config":"network","type":"wifi-iface[0]"}`, alloc),
		UCI_STATUS_INVALID_ARGUMENT,
	)
	testing.expect_value(
		t,
		uci_call_status(t, "delete", `{"config":"network","section":"lan[0]"}`, alloc),
		UCI_STATUS_INVALID_ARGUMENT,
	)
	testing.expect_value(
		t,
		uci_call_status(t, "rename", `{"config":"network","section":"lan","name":"lan-x"}`, alloc),
		UCI_STATUS_INVALID_ARGUMENT, // name 不允许 '-'
	)

	// --- 有 sid 但没写权限 → 6；注意**语法校验在 ACL 之后**（与上游一致）---
	sid := w_new_session(t, alloc)
	q := fmt.aprintf(`"ubus_rpc_session":"%s",`, sid, allocator = alloc)

	del_body := fmt.aprintf(`{{%s"config":"network","section":"lan","options":["dns"]}}`, q, allocator = alloc)
	testing.expect_value(t, uci_call_status(t, "delete", del_body, alloc), UCI_STATUS_PERMISSION_DENIED)
	// 同一个请求把 section 写成非法值，仍然是 6（ACL 先于语法）
	del_bad := fmt.aprintf(`{{%s"config":"network","section":"lan[0]"}}`, q, allocator = alloc)
	testing.expect_value(t, uci_call_status(t, "delete", del_bad, alloc), UCI_STATUS_PERMISSION_DENIED)

	ren_body := fmt.aprintf(`{{%s"config":"network","section":"lan","name":"lan2"}}`, q, allocator = alloc)
	testing.expect_value(t, uci_call_status(t, "rename", ren_body, alloc), UCI_STATUS_PERMISSION_DENIED)
	ren_bad := fmt.aprintf(`{{%s"config":"network","section":"lan","name":"lan-x"}}`, q, allocator = alloc)
	testing.expect_value(t, uci_call_status(t, "rename", ren_bad, alloc), UCI_STATUS_PERMISSION_DENIED)

	ord_body := fmt.aprintf(`{{%s"config":"network","sections":["wan","lan"]}}`, q, allocator = alloc)
	testing.expect_value(t, uci_call_status(t, "order", ord_body, alloc), UCI_STATUS_PERMISSION_DENIED)

	// --- 授权写之后：darwin 没有写事务 → 8 ---
	_, gst := session_call(
		"grant",
		fmt.aprintf(
			`{{"ubus_rpc_session":"%s","scope":"uci","objects":[["*","write"]]}}`,
			sid,
			allocator = alloc,
		),
		alloc,
	)
	testing.expect_value(t, gst, SESSION_STATUS_OK)

	testing.expect_value(t, uci_call_status(t, "delete", del_body, alloc), UCI_STATUS_NOT_SUPPORTED)
	testing.expect_value(t, uci_call_status(t, "rename", ren_body, alloc), UCI_STATUS_NOT_SUPPORTED)
	testing.expect_value(t, uci_call_status(t, "order", ord_body, alloc), UCI_STATUS_NOT_SUPPORTED)

	// 清场
	_, dst := session_call("destroy", fmt.aprintf(`{{"ubus_rpc_session":"%s"}}`, sid, allocator = alloc), alloc)
	testing.expect_value(t, dst, SESSION_STATUS_OK)
}

@(test)
test_uci_apply_family_neutral_paths :: proc(t: ^testing.T) {
	alloc, ar := mk_arena()
	defer drop_arena(ar)

	// apply 缺 sid（内部调用）→ 2（HTTP 上总会注入哨兵 sid，所以这条只在内部调用出现）
	testing.expect_value(t, uci_call_status(t, "apply", `{}`, alloc), UCI_STATUS_INVALID_ARGUMENT)

	// 没有待确认的 apply 时：confirm / rollback 都是 5（NO_DATA）——
	// 注意 rollback 的顺序是「先判 pending（5）再判 sid 参数（2）」，与 confirm 相反
	testing.expect_value(t, uci_call_status(t, "confirm", `{"ubus_rpc_session":"x"}`, alloc), UCI_STATUS_NO_DATA)
	testing.expect_value(t, uci_call_status(t, "rollback", `{}`, alloc), UCI_STATUS_NO_DATA)
	testing.expect_value(t, uci_call_status(t, "rollback", `{"ubus_rpc_session":"x"}`, alloc), UCI_STATUS_NO_DATA)

	// apply 带了 sid：跳过参数校验后去列该会话的 delta 目录。darwin 上这个目录不存在
	// （写路径不实现，永远不会建），所以是 4 —— 与设备上「没有任何未提交改动」时一致。
	testing.expect_value(
		t,
		uci_call_status(t, "apply", `{"ubus_rpc_session":"00000000000000000000000000000000"}`, alloc),
		UCI_STATUS_NOT_FOUND,
	)

	// reload_config 要 fork/exec /sbin/reload_config：darwin 不做 → 8
	testing.expect_value(t, uci_call_status(t, "reload_config", `{}`, alloc), UCI_STATUS_NOT_SUPPORTED)
}
