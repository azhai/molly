package backend

// uci 写路径的「计划层」（对齐 Odin 版 src/backend/uci_write.odin）。
//
// 这一层把「入站 JSON 值 + 现有 option 状态」映射成对 libuci 的**原子操作序列**，
// 不碰任何平台 API，所以能在 macOS 上单测。真正执行（uci_set / uci_add_list /
// uci_delete / uci_save）在 linux provider（uci_linux.go）里；darwin 永远回 8。
//
// 契约：
//
//	uci.c:806-872  rpc_uci_merge_set    （`set` 的每个 values 键）
//	uci.c:757-787  rpc_uci_add_value    （`add` 的每个 values 键）
//
// 关于「错误时不执行操作」：上游在出错分支里可能**已经**调过 uci_delete，但因为
// `set` 只在 `!err` 时才 uci_save，那些内存里的改动不会落盘。这里做法更直接：
// status != 0 时根本不执行 ops——可观测行为一致（什么都没写），且不留半执行现场。

import "encoding/json"

// uciOptionState 是现有 option 的状态。provider 查不到 option 时 exists = false。
type uciOptionState struct {
	exists bool
	isList bool
	// 标量型的值（list 型不用它；C 只在 uci.c:867 拿它做「值没变就不 set」的比较）
	value string
}

type uciMergeOp int

const (
	uciMergeDeleteOption uciMergeOp = iota // uci_delete：删掉现有 option（标量或 list 都删）
	uciMergeSetOption                      // uci_set（值取 item.value）
	uciMergeAddList                        // uci_add_list（值取 item.value）
)

type uciMergeOpItem struct {
	op    uciMergeOp
	value string
}

type uciMergePlan struct {
	// 非 0：直接把这个状态码回给调用方，ops 不执行
	status int
	// status == 0 时按顺序执行
	ops []uciMergeOpItem
}

// uciPlanMergeSet 对应 uci.c:806-872 rpc_uci_merge_set 的决策部分。
//
//  1. 值是数组：先删掉现有 option（如果存在），再为每个**能格式化**的元素 add_list；
//     一个都格式化不了 → 2（数组全是不支持的类型）。
//  2. 值不是数组、但现有 option 是 list：删掉 list，再 set（list → 标量）。
//  3. 其它：现有值**相同**就什么都不做（上游 uci.c:867-868 的优化，避免产生无意义的 delta），
//     否则 set；格式化失败 → 2。
func uciPlanMergeSet(raw json.RawMessage, existing uciOptionState) uciMergePlan {
	if firstNonSpace(raw) == '[' {
		var arr []json.RawMessage
		if err := json.Unmarshal(raw, &arr); err != nil {
			return uciMergePlan{status: StatusInvalidArgument}
		}

		ops := make([]uciMergeOpItem, 0, len(arr)+1)
		if existing.exists {
			ops = append(ops, uciMergeOpItem{op: uciMergeDeleteOption})
		}

		// 上游初值是 INVALID_ARGUMENT，靠「至少格式化成功一个元素」把它清成 0
		status := StatusInvalidArgument
		for _, elem := range arr {
			v, ok := uciFormatBlob(elem)
			if !ok {
				continue
			}
			ops = append(ops, uciMergeOpItem{op: uciMergeAddList, value: v})
			status = StatusOK
		}

		if status != StatusOK {
			return uciMergePlan{status: status}
		}
		return uciMergePlan{ops: ops}
	}

	v, ok := uciFormatBlob(raw)
	if !ok {
		return uciMergePlan{status: StatusInvalidArgument}
	}

	if existing.exists && existing.isList {
		// list → 标量：先删 list 再 set
		return uciMergePlan{ops: []uciMergeOpItem{
			{op: uciMergeDeleteOption},
			{op: uciMergeSetOption, value: v},
		}}
	}

	if existing.exists && !existing.isList && existing.value == v {
		// 值没变：上游不 emit set（否则每次 set 都会造出一条 delta）
		return uciMergePlan{}
	}

	return uciMergePlan{ops: []uciMergeOpItem{{op: uciMergeSetOption, value: v}}}
}

// uciPlanAddValue 对应 uci.c:757-787 rpc_uci_add_value。与 merge_set **不一样**：
//
//	merge_set：数组 → 先删旧 option 再逐个 add_list；标量 → 仅当值变化才 set
//	add      ：数组 → 直接逐个 add_list（**不删**旧值）；标量 → 直接 set（**不比**旧值）
//
// 并且数组里**任何一个**元素不能格式化 → 整体 2（与 merge_set 的「至少一个成功
// 就算成功」相反）。
func uciPlanAddValue(raw json.RawMessage) uciMergePlan {
	if firstNonSpace(raw) == '[' {
		var arr []json.RawMessage
		if err := json.Unmarshal(raw, &arr); err != nil {
			return uciMergePlan{status: StatusInvalidArgument}
		}

		ops := make([]uciMergeOpItem, 0, len(arr))
		status := StatusOK
		for _, elem := range arr {
			v, ok := uciFormatBlob(elem)
			if !ok {
				status = StatusInvalidArgument
				continue
			}
			ops = append(ops, uciMergeOpItem{op: uciMergeAddList, value: v})
		}
		if status != StatusOK {
			return uciMergePlan{status: status}
		}
		return uciMergePlan{ops: ops}
	}

	v, ok := uciFormatBlob(raw)
	if !ok {
		return uciMergePlan{status: StatusInvalidArgument}
	}

	return uciMergePlan{ops: []uciMergeOpItem{{op: uciMergeSetOption, value: v}}}
}
