package backend

// uci_write —— uci 写路径的「计划层」（逐段对齐 internal/backend/uci_write_plan.go）。
//
// 这一层把「入站 JSON 值 + 现有 option 状态」映射成对 libuci 的原子操作序列，不碰任何
// 平台 API，所以在 macOS 上就能端到端单测。真正执行（uci_set / uci_add_list / uci_delete /
// uci_save）在 linux provider（阶段 3h）里；宿主 provider 一律回 8、根本不会走到 ops 执行。
//
// 契约：
//
//	uci.c:806-872  rpc_uci_merge_set    （`set` 的每个 values 键）
//	uci.c:757-787  rpc_uci_add_value    （`add` 的每个 values 键）
//
// 关于「错误时不执行操作」：status != 0 时调用方根本不执行 ops——可观测行为与上游一致
// （什么都没写），且不留半执行现场。

import "core:fmt"
import "core:mem"
import "core:encoding/json"

// Uci_Option_State 是现有 option 的状态。provider 查不到 option 时 exists = false。
Uci_Option_State :: struct {
	exists:  bool,
	is_list: bool,
	value:   string, // 标量型的值（list 型不用它）
}

Uci_Merge_Op_Kind :: enum {
	Delete_Option, // uci_delete：删掉现有 option（标量或 list 都删）
	Set_Option,    // uci_set（值取 item.value）
	Add_List,      // uci_add_list（值取 item.value）
}

Uci_Merge_Op_Item :: struct {
	op:    Uci_Merge_Op_Kind,
	value: string,
}

// Uci_Merge_Plan：status != 0 时直接把这个状态码回给调用方，ops 不执行；
// status == 0 时按顺序执行 ops。
Uci_Merge_Plan :: struct {
	status: i32,
	ops:    []Uci_Merge_Op_Item,
}

// uci_format_blob 对应 uci.c:344-381 rpc_uci_format_blob。只认 string / 整数 / bool 三种
// ——C 的 switch 里没有 DOUBLE，浮点（及数组/对象/null）一律「不支持」。
// 与 C 的差异：负数在 C 里按无符号打印（%u），这里按原值打印。
uci_format_blob :: proc(v: json.Value) -> (string, bool) {
	if s, ok := v.(json.String); ok {
		return string(s), true
	}
	if b, ok := v.(json.Boolean); ok {
		return b ? "1" : "0", true
	}
	if n, ok := v.(json.Integer); ok {
		return fmt.tprintf("%d", i64(n)), true
	}
	return "", false
}

// uci_value_is_array —— 判定入站值是否为数组（对应 Go 的 firstNonSpace(raw)=='['）。
uci_value_is_array :: proc(v: json.Value) -> bool {
	_, ok := v.(json.Array)
	return ok
}

// uci_plan_merge_set 对应 uci.c:806-872 rpc_uci_merge_set 的决策部分。
//
//  1. 值是数组：先删掉现有 option（如果存在），再为每个**能格式化**的元素 add_list；
//     一个都格式化不了 → 2（数组全是不支持的类型）。
//  2. 值不是数组、但现有 option 是 list：删掉 list，再 set（list → 标量）。
//  3. 其它：现有值**相同**就什么都不做（避免产生无意义的 delta），否则 set；格式化失败 → 2。
uci_plan_merge_set :: proc(raw: json.Value, existing: Uci_Option_State) -> Uci_Merge_Plan {
	if arr, is_arr := raw.(json.Array); is_arr {
		ops: [dynamic]Uci_Merge_Op_Item
		if existing.exists {
			append(&ops, Uci_Merge_Op_Item{op = .Delete_Option})
		}
		// 上游初值是 INVALID_ARGUMENT，靠「至少格式化成功一个元素」把它清成 0
		status: i32 = Status_Invalid_Argument
		for elem in arr {
			v, ok := uci_format_blob(elem)
			if !ok {
				continue
			}
			append(&ops, Uci_Merge_Op_Item{op = .Add_List, value = v})
			status = Status_OK
		}
		if status != Status_OK {
			delete(ops)
			return Uci_Merge_Plan{status = status}
		}
		// ops 的 backing 落在 context.allocator（请求/测试 arena），返回视图即可，随 arena 回收。
		return Uci_Merge_Plan{ops = ops[:]}
	}

	v, ok := uci_format_blob(raw)
	if !ok {
		return Uci_Merge_Plan{status = Status_Invalid_Argument}
	}

	if existing.exists && existing.is_list {
		// list → 标量：先删 list 再 set
		ops := make([]Uci_Merge_Op_Item, 2, context.allocator)
		ops[0] = Uci_Merge_Op_Item{op = .Delete_Option}
		ops[1] = Uci_Merge_Op_Item{op = .Set_Option, value = v}
		return Uci_Merge_Plan{ops = ops}
	}

	if existing.exists && !existing.is_list && existing.value == v {
		// 值没变：上游不 emit set
		return Uci_Merge_Plan{}
	}

	ops := make([]Uci_Merge_Op_Item, 1, context.allocator)
	ops[0] = Uci_Merge_Op_Item{op = .Set_Option, value = v}
	return Uci_Merge_Plan{ops = ops}
}

// uci_plan_add_value 对应 uci.c:757-787 rpc_uci_add_value。与 merge_set **不一样**：
//
//	merge_set：数组 → 先删旧 option 再逐个 add_list；标量 → 仅当值变化才 set
//	add      ：数组 → 直接逐个 add_list（**不删**旧值）；标量 → 直接 set（**不比**旧值）
//
// 并且数组里**任何一个**元素不能格式化 → 整体 2（与 merge_set 的「至少一个成功」相反）。
uci_plan_add_value :: proc(raw: json.Value) -> Uci_Merge_Plan {
	if arr, is_arr := raw.(json.Array); is_arr {
		ops: [dynamic]Uci_Merge_Op_Item
		status: i32 = Status_OK
		for elem in arr {
			v, ok := uci_format_blob(elem)
			if !ok {
				status = Status_Invalid_Argument
				continue
			}
			append(&ops, Uci_Merge_Op_Item{op = .Add_List, value = v})
		}
		if status != Status_OK {
			delete(ops)
			return Uci_Merge_Plan{status = status}
		}
		return Uci_Merge_Plan{ops = ops[:]}
	}

	v, ok := uci_format_blob(raw)
	if !ok {
		return Uci_Merge_Plan{status = Status_Invalid_Argument}
	}

	ops := make([]Uci_Merge_Op_Item, 1, context.allocator)
	ops[0] = Uci_Merge_Op_Item{op = .Set_Option, value = v}
	return Uci_Merge_Plan{ops = ops}
}
