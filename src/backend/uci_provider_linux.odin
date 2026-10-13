package backend

// uci_provider_linux —— uci 对象的真设备（linux）平台实现（对齐 internal/backend/uci_linux.go）。
//
// 经 src/backend/bindings 的 foreign 声明调 src/native/shim.c 里的真 libuci
// （uci_load / uci_set / uci_commit …）与 /sbin/reload_config 的 fork/exec。C 侧统一把结果
// 打包成 malloc 的 JSON 文本 + 整数状态码交回，本层用 core:encoding/json 解析成 Uci_Section /
// Uci_Change，再把 C 缓冲 molly_free 掉。
//
// 文件名后缀 _linux 让 Odin 只在 linux 目标编本文件：这样 bindings 的
// `foreign import shim "system:shim"`（会拉进 -lshim）不进 darwin 测试二进制的链接图；宿主
// （darwin）那份假数据实现见 uci_provider_darwin.odin，两份**同名同签名**，靠平台文件名互斥。
//
// 锁：libuci 非线程安全，写事务又是多步操作（中间不能让别的请求插进来）。HTTP 线程与 ubus 服务
// 线程都可能进来，所以一把包级 uciMu 串行化**所有** uci 调用；写事务的锁由 write_begin 拿到、
// write_end 释放（与 Go 的 uciMu 同义）。读路径/commit/revert/apply 各自 begin…defer unlock。
//
// 内存：C 入参用 strings.clone_to_cstring（落 context.allocator，随请求 arena 回收，不单独 free）；
// C 出参先 clone 进 arena 再 molly_free 原缓冲。解析出的 sections/changes 落 arena，随请求回收，
// 与 Go 版「一次调用内堆分配、调用结束即弃」等价。

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:sync"
import "core:encoding/json"

import "bindings"

uciMu: sync.Mutex

// uci_state_savedir —— `state` 读「已提交态」时的 delta 目录（uci.c:619-620）。
uci_state_savedir :: "/var/state"

// uci_savedir_of —— 会话 savedir：空 sid 回 ""（让 shim 用默认 /tmp/.uci），否则前缀 + sid。
uci_savedir_of :: proc(sid: string) -> string {
	if sid == "" {
		return ""
	}
	return fmt.tprintf("%s%s", uci_savedir_prefix, sid)
}

// ---------------------------------------------------------------------------
// C 边界小工具
// ---------------------------------------------------------------------------

// uci_cstr —— 必填入参：Odin string → NUL 结尾副本（空串也造，得 ""）。
uci_cstr :: proc(s: string) -> cstring {
	return strings.clone_to_cstring(s)
}

// uci_copt —— 可空入参：空串给 nil（shim 把 NULL 当作「用默认」）。
uci_copt :: proc(s: string) -> cstring {
	if s == "" {
		return nil
	}
	return strings.clone_to_cstring(s)
}

// uci_take —— 把 shim 的 char* 出参（malloc）拷进 arena、释放原缓冲，返回 Odin string。nil → ""。
uci_take :: proc(cs: cstring) -> string {
	if cs == nil {
		return ""
	}
	s := strings.clone_from_cstring(cs)
	bindings.molly_free(transmute(rawptr)(cs))
	return s
}

// uci_jstr / uci_jint —— 从 JSON 对象取字符串 / 整数（缺字段给零值）。Integer 底层是 i64。
uci_jstr :: proc(o: json.Object, key: string) -> string {
	v, found := o[key]
	if !found {
		return ""
	}
	if s, ok := v.(json.String); ok {
		return string(s)
	}
	return ""
}

uci_jint :: proc(o: json.Object, key: string) -> i64 {
	v, found := o[key]
	if !found {
		return 0
	}
	if n, ok := v.(json.Integer); ok {
		return i64(n)
	}
	return 0
}

// ---------------------------------------------------------------------------
// cbind 的 JSON 形态 → Uci_Section / Uci_Change
// ---------------------------------------------------------------------------

// uci_decode_sections —— shim 的 molly_uci_sections 输出（数组 of {name,type,anonymous:int,
// options:[{name,list:int,values:[]}]}）。anonymous/list 是 u32 计数（0/1），不是 JSON bool。
// 标量型若无值 → 补 1 个空串（对齐 Odin：v.string 为 NULL 时是空串）。
uci_decode_sections :: proc(js: string, alloc: mem.Allocator) -> (secs: []Uci_Section, ok: bool) {
	if js == "" {
		return nil, false
	}
	v, err := json.parse_string(js, .JSON, true, alloc)
	if err != nil {
		return nil, false
	}
	arr, is_arr := v.(json.Array)
	if !is_arr {
		return nil, false
	}
	out := make([dynamic]Uci_Section, alloc)
	for item in arr {
		o, is_obj := item.(json.Object)
		if !is_obj {
			continue
		}
		sec := Uci_Section{
			name      = uci_jstr(o, "name"),
			type_name = uci_jstr(o, "type"),
			anonymous = uci_jint(o, "anonymous") != 0,
		}
		if ov, has_opts := o["options"]; has_opts {
			opts_arr, is_oa := ov.(json.Array)
			if is_oa {
				opts := make([dynamic]Uci_Option, alloc)
				for oi in opts_arr {
					oo, is_oo := oi.(json.Object)
					if !is_oo {
						continue
					}
					op := Uci_Option{
						name    = uci_jstr(oo, "name"),
						is_list = uci_jint(oo, "list") != 0,
					}
					if vv, has_vals := oo["values"]; has_vals {
						va, is_va := vv.(json.Array)
						if is_va {
							vals := make([dynamic]string, alloc)
							for vs in va {
								if s, is_s := vs.(json.String); is_s {
									append(&vals, string(s))
								}
							}
							op.values = vals[:]
						}
					}
					if !op.is_list && len(op.values) == 0 {
						one := make([]string, 1, alloc)
						one[0] = ""
						op.values = one
					}
					append(&opts, op)
				}
				sec.options = opts[:]
			}
		}
		append(&out, sec)
	}
	return out[:], true
}

// uci_decode_delta —— shim 的 molly_uci_delta 输出（数组 of {cmd:int,section,name,value}）。
// cmd 是 enum uci_command，与 Uci_Change_Kind 同序（0..6）。
uci_decode_delta :: proc(js: string) -> (changes: []Uci_Change, status: i32) {
	if js == "" {
		return nil, Status_Unknown_Error
	}
	v, err := json.parse_string(js, .JSON, true, context.allocator)
	if err != nil {
		return nil, Status_Unknown_Error
	}
	arr, is_arr := v.(json.Array)
	if !is_arr {
		return nil, Status_Unknown_Error
	}
	out: [dynamic]Uci_Change
	for item in arr {
		o, is_obj := item.(json.Object)
		if !is_obj {
			continue
		}
		append(&out, Uci_Change{
			kind    = cast(Uci_Change_Kind)(uci_jint(o, "cmd")),
			section = uci_jstr(o, "section"),
			name    = uci_jstr(o, "name"),
			value   = uci_jstr(o, "value"),
		})
	}
	return out[:], Status_OK
}

// ---------------------------------------------------------------------------
// 读路径（各自持锁）
// ---------------------------------------------------------------------------

// uci_provider_configs —— /etc/config/* 的字母序列表（uci.c:1390）。
uci_provider_configs :: proc() -> (names: []string, ok: bool) {
	sync.mutex_lock(&uciMu)
	defer sync.mutex_unlock(&uciMu)

	out_c: cstring
	if bindings.molly_uci_list_configs(&out_c) != 0 {
		return nil, false
	}
	js := uci_take(out_c)
	if js == "" {
		return nil, false
	}
	v, err := json.parse_string(js, .JSON, true, context.allocator)
	if err != nil {
		return nil, false
	}
	arr, is_arr := v.(json.Array)
	if !is_arr {
		return nil, false
	}
	out: [dynamic]string
	for item in arr {
		if s, is_s := item.(json.String); is_s {
			append(&out, string(s))
		}
	}
	return out[:], true
}

// uci_read_sections_alloc —— uci_load + 遍历（默认 delta 目录，savedir 传 nil），解析结果落 alloc。
// 这是 session / 菜单 的 uci 数据源（hook_uci_sections）与 provider 读路径共用的核心。
uci_read_sections_alloc :: proc(config: string, alloc: mem.Allocator) -> (secs: []Uci_Section, ok: bool) {
	sync.mutex_lock(&uciMu)
	defer sync.mutex_unlock(&uciMu)

	out_c: cstring
	if bindings.molly_uci_sections(uci_cstr(config), nil, &out_c) != 0 {
		return nil, false
	}
	return uci_decode_sections(uci_take(out_c), alloc)
}

// uci_provider_sections —— uci 对象读路径（落请求 arena）。
uci_provider_sections :: proc(config: string) -> (secs: []Uci_Section, ok: bool) {
	return uci_read_sections_alloc(config, context.allocator)
}

// uci_provider_state_sections —— savedir 换成 /var/state 后 uci_load（读已提交态）。
uci_provider_state_sections :: proc(config: string) -> (sections: []Uci_Section, status: i32) {
	sync.mutex_lock(&uciMu)
	defer sync.mutex_unlock(&uciMu)

	out_c: cstring
	ret := bindings.molly_uci_sections(uci_cstr(config), uci_cstr(uci_state_savedir), &out_c)
	if ret != 0 {
		if ret == Status_Not_Found {
			return nil, Status_Not_Found
		}
		return nil, Status_Unknown_Error
	}
	secs, ok := uci_decode_sections(uci_take(out_c), context.allocator)
	if !ok {
		return nil, Status_Unknown_Error
	}
	return secs, Status_OK
}

// uci_provider_savedir —— savedir 由每个操作按 sid 建短命 context 承载，这里只报告「能切」。
uci_provider_savedir :: proc(sid: string) -> bool {
	_ = sid
	return true
}

// uci_provider_delta —— 枚举该 config 的 saved_delta（uci.c:1250-1251、:1285-1286）。
uci_provider_delta :: proc(sid, config: string) -> (changes: []Uci_Change, status: i32) {
	sync.mutex_lock(&uciMu)
	defer sync.mutex_unlock(&uciMu)

	out_c: cstring
	ret := bindings.molly_uci_delta(uci_copt(sid), uci_cstr(config), &out_c)
	if ret != 0 {
		return nil, ret
	}
	return uci_decode_delta(uci_take(out_c))
}

// ---------------------------------------------------------------------------
// 写事务（begin 持锁、end 释放；中间各步**不再重复加锁**，同线程复用 begin 的锁）
// ---------------------------------------------------------------------------

// Uci_Write_Txn 是一次写事务（uci_load → 改 → save）的句柄；h 是 shim 的 struct molly_uci_txn *。
Uci_Write_Txn :: struct {
	h: rawptr,
}

// uci_provider_write_begin —— uci_load（配置 + 该会话 delta）。成功时一直持有 uciMu，
// 由 uci_provider_write_end 释放。
uci_provider_write_begin :: proc(sid, config: string) -> (^Uci_Write_Txn, i32) {
	sync.mutex_lock(&uciMu)

	status: i32
	p := bindings.molly_uci_txn_begin(uci_cstr(config), uci_copt(uci_savedir_of(sid)), &status)
	if p == nil || status != 0 {
		sync.mutex_unlock(&uciMu)
		st := status
		if st == 0 {
			st = Status_Unknown_Error
		}
		return nil, st
	}
	t := new(Uci_Write_Txn)
	t.h = p
	return t, Status_OK
}

uci_provider_write_end :: proc(txn: ^Uci_Write_Txn) {
	if txn == nil {
		// begin 失败时方法层不会调到这里；防御性返回（不能重复解锁）。
		return
	}
	if txn.h != nil {
		bindings.molly_uci_txn_end(txn.h)
	}
	sync.mutex_unlock(&uciMu)
}

uci_provider_write_sections :: proc(txn: ^Uci_Write_Txn) -> (secs: []Uci_Section, status: i32) {
	if txn == nil || txn.h == nil {
		return nil, Status_Not_Supported
	}
	sections, ok := uci_decode_sections(uci_take(bindings.molly_uci_txn_sections(txn.h)), context.allocator)
	if !ok {
		return nil, Status_Unknown_Error
	}
	return sections, Status_OK
}

uci_provider_write_add_section :: proc(txn: ^Uci_Write_Txn, type_name, name: string) -> (string, i32) {
	if txn == nil || txn.h == nil {
		return "", Status_Not_Supported
	}
	out_c: cstring
	ret := bindings.molly_uci_txn_add_section(txn.h, uci_cstr(type_name), uci_copt(name), &out_c)
	if ret != 0 {
		return "", ret
	}
	return uci_take(out_c), Status_OK
}

uci_provider_write_merge_set :: proc(txn: ^Uci_Write_Txn, section, option: string, value: json.Value) -> i32 {
	if txn == nil || txn.h == nil {
		return Status_Not_Supported
	}
	if !uci_verify_name(option) {
		return Status_Invalid_Argument
	}
	if bindings.molly_uci_txn_section_exists(txn.h, uci_cstr(section)) == 0 {
		return Status_Not_Found
	}
	c_exists: i32
	c_is_list: i32
	c_value: cstring
	bindings.molly_uci_txn_option_state(txn.h, uci_cstr(section), uci_cstr(option), &c_exists, &c_is_list, &c_value)
	state := Uci_Option_State{
		exists  = c_exists != 0,
		is_list = c_is_list != 0,
		value   = uci_take(c_value),
	}
	return uci_run_plan(txn, section, option, uci_plan_merge_set(value, state))
}

uci_provider_write_add_value :: proc(txn: ^Uci_Write_Txn, section, option: string, value: json.Value) -> i32 {
	if txn == nil || txn.h == nil {
		return Status_Not_Supported
	}
	if !uci_verify_name(option) {
		return Status_Invalid_Argument
	}
	if bindings.molly_uci_txn_section_exists(txn.h, uci_cstr(section)) == 0 {
		return Status_Not_Found
	}
	return uci_run_plan(txn, section, option, uci_plan_add_value(value))
}

// uci_run_plan —— 按计划层给的 ops 依次执行。每条 op 都重新 lookup（delete/set 会改变元素
// 状态，缓存反而容易踩到已释放的 uci_section——上游也每次重查）。
uci_run_plan :: proc(txn: ^Uci_Write_Txn, section, option: string, plan: Uci_Merge_Plan) -> i32 {
	if plan.status != 0 {
		return plan.status
	}
	for item in plan.ops {
		rc: i32 = Status_OK
		switch item.op {
		case .Delete_Option:
			rc = bindings.molly_uci_txn_delete(txn.h, uci_cstr(section), uci_cstr(option))
		case .Set_Option:
			rc = bindings.molly_uci_txn_set(txn.h, uci_cstr(section), uci_cstr(option), uci_cstr(item.value))
		case .Add_List:
			rc = bindings.molly_uci_txn_add_list(txn.h, uci_cstr(section), uci_cstr(option), uci_cstr(item.value))
		}
		if rc != 0 {
			return rc
		}
	}
	return Status_OK
}

uci_provider_write_save :: proc(txn: ^Uci_Write_Txn) -> i32 {
	if txn == nil || txn.h == nil {
		return Status_Not_Supported
	}
	return bindings.molly_uci_txn_save(txn.h)
}

uci_provider_write_delete :: proc(txn: ^Uci_Write_Txn, section: string, form: Uci_Delete_Form, names: []string) -> i32 {
	if txn == nil || txn.h == nil {
		return Status_Not_Supported
	}
	switch form {
	case .Section:
		// 删整个 section（上游收到 NULL 的 opt）
		return bindings.molly_uci_txn_delete(txn.h, uci_cstr(section), nil)
	case .Option:
		if len(names) == 0 {
			return Status_Not_Found
		}
		return bindings.molly_uci_txn_delete(txn.h, uci_cstr(section), uci_cstr(names[0]))
	case .Options:
		found := false
		for name in names {
			if bindings.molly_uci_txn_delete(txn.h, uci_cstr(section), uci_cstr(name)) == Status_OK {
				found = true
			}
		}
		// 一个都没删到 → 4（uci.c:973-991 的聚合）
		if found {
			return Status_OK
		}
		return Status_Not_Found
	}
	return Status_Unknown_Error
}

uci_provider_write_rename :: proc(txn: ^Uci_Write_Txn, section, option, new_name: string) -> i32 {
	if txn == nil || txn.h == nil {
		return Status_Not_Supported
	}
	return bindings.molly_uci_txn_rename(txn.h, uci_cstr(section), uci_copt(option), uci_cstr(new_name))
}

// uci_provider_write_reorder 返回「找到了吗」；调用方据此把状态码聚合成 4。
uci_provider_write_reorder :: proc(txn: ^Uci_Write_Txn, section: string, pos: int) -> bool {
	if txn == nil || txn.h == nil {
		return false
	}
	return bindings.molly_uci_txn_reorder(txn.h, uci_cstr(section), i32(pos)) != 0
}

// ---------------------------------------------------------------------------
// apply 系
// ---------------------------------------------------------------------------

// uci_provider_apply_config —— load → commit → unload → 事件；no_delta 时提交看不见任何 delta。
uci_provider_apply_config :: proc(config: string, no_delta: bool) -> i32 {
	sync.mutex_lock(&uciMu)
	defer sync.mutex_unlock(&uciMu)

	nd: i32 = 0
	if no_delta {
		nd = 1
	}
	return bindings.molly_uci_apply_config(uci_cstr(config), nd)
}

// uci_provider_reload_config —— fork/exec /sbin/reload_config（父进程立刻返回）。
uci_provider_reload_config :: proc() -> i32 {
	return bindings.molly_reload_config()
}

// uci_provider_commit —— uci.c:1344-1351。
uci_provider_commit :: proc(sid, config: string) -> i32 {
	sync.mutex_lock(&uciMu)
	defer sync.mutex_unlock(&uciMu)

	return bindings.molly_uci_commit(uci_copt(sid), uci_cstr(config))
}

// uci_provider_revert —— uci.c:1353-1360。
uci_provider_revert :: proc(sid, config: string) -> i32 {
	sync.mutex_lock(&uciMu)
	defer sync.mutex_unlock(&uciMu)

	return bindings.molly_uci_revert(uci_copt(sid), uci_cstr(config))
}

// ---------------------------------------------------------------------------
// 平台钩子安装（session / 菜单的 uci 数据源）
//
// hook_uci_sections 的签名是 (config, alloc) -> ([]Uci_Section, bool)：session 登录时读
// /etc/config/rpcd 的 login section、菜单 depends.uci 读各 config，都要把解析结果落进
// session 传入的 store_alloc（会话生命周期），而非请求 arena。uci_read_sections_alloc 正是
// 该核心。@(init) 早于 main 执行，把包级钩子指过来；darwin 上本文件被平台文件名排除，
// session_ensure_store 的 nil 守卫会退化成 host_uci_sections（假数据），两条路径互不干扰。
// ---------------------------------------------------------------------------

@(init)
install_linux_uci_hook :: proc "contextless" () {
	hook_uci_sections = uci_read_sections_alloc
}
