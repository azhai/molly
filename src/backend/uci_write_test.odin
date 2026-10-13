package backend

import "core:testing"
import "core:mem"
import "core:encoding/json"

// pv —— 从 JSON 文本解析出一个 json.Value（测试用）。
pv :: proc(alloc: mem.Allocator, text: string) -> json.Value {
	v, err := json.parse_string(text, .JSON, true, alloc)
	assert(err == nil, text)
	return v
}

@(test)
test_uci_write_plan :: proc(t: ^testing.T) {
	backing: [262144]u8
	ar: mem.Arena
	mem.arena_init(&ar, backing[:])
	old := context.allocator
	context.allocator = mem.arena_allocator(&ar)
	defer context.allocator = old
	alloc := context.allocator

	// ---- merge_set：新标量 → 一条 set ----
	p := uci_plan_merge_set(pv(alloc, `"static"`), Uci_Option_State{})
	testing.expect_value(t, p.status, Status_OK)
	testing.expect_value(t, len(p.ops), 1)
	testing.expect(t, p.ops[0].op == .Set_Option && p.ops[0].value == "static", "新标量应 emit set")

	// ---- merge_set：现有值相同 → 不 emit ----
	p = uci_plan_merge_set(pv(alloc, `"static"`), Uci_Option_State{exists = true, is_list = false, value = "static"})
	testing.expect_value(t, p.status, Status_OK)
	testing.expect_value(t, len(p.ops), 0)

	// ---- merge_set：现有是 list、写入标量 → 先删再 set ----
	p = uci_plan_merge_set(pv(alloc, `"x"`), Uci_Option_State{exists = true, is_list = true, value = ""})
	testing.expect_value(t, p.status, Status_OK)
	testing.expect_value(t, len(p.ops), 2)
	testing.expect(t, p.ops[0].op == .Delete_Option, "list→标量先删")
	testing.expect(t, p.ops[1].op == .Set_Option && p.ops[1].value == "x", "list→标量后 set")

	// ---- merge_set：数组、无现有 → 逐元素 add_list（bool→"1"/"0"，整数→十进制）----
	p = uci_plan_merge_set(pv(alloc, `["a", true, 5]`), Uci_Option_State{})
	testing.expect_value(t, p.status, Status_OK)
	testing.expect_value(t, len(p.ops), 3)
	testing.expect(t, p.ops[0].op == .Add_List && p.ops[0].value == "a", "数组首元素 add_list a")
	testing.expect(t, p.ops[1].value == "1", "bool true→1")
	testing.expect(t, p.ops[2].value == "5", "整数 5→\"5\"")

	// ---- merge_set：数组、有现有 → 先删再 add_list ----
	p = uci_plan_merge_set(pv(alloc, `["b"]`), Uci_Option_State{exists = true})
	testing.expect_value(t, len(p.ops), 2)
	testing.expect(t, p.ops[0].op == .Delete_Option && p.ops[1].op == .Add_List, "数组先删再 add_list")

	// ---- merge_set：数组全是不支持类型（浮点）→ 2 ----
	p = uci_plan_merge_set(pv(alloc, `[1.5]`), Uci_Option_State{})
	testing.expect_value(t, p.status, Status_Invalid_Argument)

	// ---- merge_set：不支持的标量（浮点）→ 2 ----
	p = uci_plan_merge_set(pv(alloc, `2.5`), Uci_Option_State{})
	testing.expect_value(t, p.status, Status_Invalid_Argument)

	// ---- add_value：标量 → 直接 set（不比旧值）----
	p = uci_plan_add_value(pv(alloc, `"y"`))
	testing.expect_value(t, p.status, Status_OK)
	testing.expect(t, len(p.ops) == 1 && p.ops[0].op == .Set_Option && p.ops[0].value == "y", "add 标量 set")

	// ---- add_value：数组 → 逐个 add_list（不删旧值）----
	p = uci_plan_add_value(pv(alloc, `["p", "q"]`))
	testing.expect_value(t, p.status, Status_OK)
	testing.expect_value(t, len(p.ops), 2)
	testing.expect(t, p.ops[0].op == .Add_List && p.ops[1].op == .Add_List, "add 数组不删旧值")

	// ---- add_value：数组里任一不支持 → 整体 2（与 merge_set 的「至少一个」相反）----
	p = uci_plan_add_value(pv(alloc, `["ok", 3.5]`))
	testing.expect_value(t, p.status, Status_Invalid_Argument)
}
