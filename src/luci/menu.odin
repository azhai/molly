package luci

// luci/menu —— 专家版 dispatcher 的「建树 + 解析」半边（对齐 internal/luci/menu.go，
// 逐条复刻上游 dispatcher.uc 的 build_pagetree / check_depends / resolve_page /
// resolve_firstchild / apply_tree_acls）。
//
// depends.acl 参与裁树：缺组的节点对本会话不可见（解析不到 → 404），只有 read 的会话把
// 节点标成只读。树跨请求缓存，所以会话相关的判定**每请求现算**（走 Deps.acl_level），
// 节点上不写会话状态——这点与 Go 一致，也是把 Deps 设计成「proc 字段结构体」而非直接调
// backend 的理由：建树/解析的纯逻辑能在 host 用假 deps 单测（见 menu_test.odin）。

import "core:strings"
import "core:fmt"
import "core:os"
import "core:mem"
import "core:sync"
import "core:sort"
import "base:runtime"
import "core:time"
import "core:encoding/json"
import "molly:backend"

// ---------------------------------------------------------------------------
// 依赖接缝
// ---------------------------------------------------------------------------

// Deps 是 dispatcher 需要的 backend 能力，比直接调 backend 窄，便于单测替身（对齐 Go 的 Deps 接口）。
//   uci_sections：菜单 depends.uci 的数据源（落调用方 alloc）。
//   acl_level：sid 对 depends.acl 列出的组的权限档位。
Deps :: struct {
	uci_sections: proc(config: string, alloc: mem.Allocator) -> ([]backend.Uci_Section, bool),
	acl_level:    proc(sid: string, groups: []string) -> backend.ACL_Level,
}

// Backend_Deps —— 生产用的 Deps：接到 backend 的窄接口（§6 的 Uci_Config_Sections +
// Session_ACL_Level）。handler 用它，测试用假 Deps。
Backend_Deps :: proc() -> Deps {
	return Deps{
		uci_sections = backend.Uci_Config_Sections,
		acl_level    = backend.Session_ACL_Level,
	}
}

// uci_of / acl_of —— 对两个可空 proc 字段的取值兜底（proc 未装时：uci 读不到 / acl 视为缺组）。
uci_of :: proc(deps: Deps, config: string) -> ([]backend.Uci_Section, bool) {
	if deps.uci_sections == nil {
		return nil, false
	}
	return deps.uci_sections(config, context.allocator)
}

acl_level_of :: proc(deps: Deps, sid: string, groups: []string) -> backend.ACL_Level {
	if deps.acl_level == nil {
		return .Missing
	}
	return deps.acl_level(sid, groups)
}

// ---------------------------------------------------------------------------
// 节点
// ---------------------------------------------------------------------------

Node :: struct {
	title: string,

	action_type: string,
	action_path: string,

	// 通配节点的 action 与 base action 分开存：`wv` 与 `wv/*` 落同一节点，合成一个字段会被后处理的文件覆盖。
	wildcard_action_type: string,
	wildcard_action_path: string,
	has_wildcard_action:  bool,

	order: int, // spec.order ?? 9999

	depends_json: string, // depends 原文 JSON（排序后），仅展示用
	has_depends:  bool,

	wildcard: bool, // 路径里出现过以 '*' 开头的段

	firstchild_ineligible: bool, // spec.firstchild_ineligible：不参与 firstchild 竞选

	satisfied: bool, // depends 判定（只算 fs/uci，acl 每请求现算）

	acl_groups: []string, // depends.acl 列出的组名；空 = 无 acl 要求

	has_auth:   bool, // 节点带 auth 对象（真实 menu.d 里 `auth:{}` 也算带）
	auth_login: bool, // ...且标了 login

	children: map[string]^Node,
}

// Resolved 是 resolve 的结果。
Resolved :: struct {
	node:       ^Node,
	args:       []string,
	found:      bool,
	acl_groups: []string, // 沿途（含通配层）depends.acl 组名并集（上游 ctx.acls）
	auth:       AuthState,
}

// AuthState —— 「最后者胜」的 auth + firstchild 竞选的「login 粘滞模式」，两条语义必须分开。
AuthState :: struct {
	has_auth:   bool, // ctx.auth 非空
	auth_login: bool, // ...且最后那个带 auth 的节点标了 login
	login_mode: bool, // 粘滞：出现过 login 节点
}

// login_required 对齐上游 :927-930：无会话 且 ctx.auth 非空且标了 login → 进登录流程。
login_required :: proc(state: AuthState, sid: string) -> bool {
	return len(sid) == 0 && state.has_auth && state.auth_login
}

// auth_absorb 把节点并进 auth 状态（只有节点自己带 auth 才覆盖 HasAuth/AuthLogin），
// 同时更新粘滞的 login_mode。
auth_absorb :: proc(state: AuthState, n: ^Node) -> AuthState {
	if ! n.has_auth {
		return state
	}
	out := state
	out.has_auth = true
	out.auth_login = n.auth_login
	out.login_mode = out.login_mode || n.auth_login
	return out
}

// ---------------------------------------------------------------------------
// 建树
// ---------------------------------------------------------------------------

// empty_tree —— root：action=firstchild、satisfied、无子节点。目录读不到时也回它（全部 404）。
empty_tree :: proc() -> ^Node {
	root := new(Node)
	root^ = Node{action_type = "firstchild", satisfied = true, children = make(map[string]^Node)}
	return root
}

new_node :: proc() -> ^Node {
	n := new(Node)
	n^ = Node{order = 9999, satisfied = true, children = make(map[string]^Node)}
	return n
}

// Build_Tree —— 按 names（已排序）逐个读文件并入 root。落在 context.allocator 上。
// ok=false 仅当 root==nil 之外的语义由调用方决定；这里失败（读不到某文件）就跳过该文件（对齐 Go）。
Build_Tree :: proc(dir: string, names: []string, deps: Deps) -> ^Node {
	root := empty_tree()
	for name in names {
		full := fmt.tprintf("%s/%s", dir, name)
		data, err := os.read_entire_file(full, context.allocator)
		if err != nil {
			continue
		}
		merge_menu_file(root, data, deps)
	}
	return root
}

// Empty_Tree —— 导出给 handler 的兜底（菜单目录读不到时用）。
Empty_Tree :: proc() -> ^Node { return empty_tree() }

merge_menu_file :: proc(root: ^Node, data: []u8, deps: Deps) {
	v, err := json.parse_string(string(data), .JSON, true, context.allocator)
	if err != nil {
		return
	}
	obj, is_obj := v.(json.Object)
	if ! is_obj {
		return
	}
	// JSON 对象遍历顺序不确定；排一下让「同文件内多个 spec 落到同一节点」也可复现。
	paths := [dynamic]string{}
	defer delete(paths)
	for path, _ in obj {
		append(&paths, path)
	}
	sort.heap_sort(paths[:])
	for path in paths {
		spec, is_spec := obj[path].(json.Object)
		if ! is_spec {
			continue
		}
		apply_spec(root, path, spec, deps)
	}
}

// apply_spec —— 一条 menu.d 规格 → 树上的一个节点。逐键判定：类型不符的键只忽略该键、不丢整条；
// 只覆盖 spec 里出现的键，没出现的保留前一份（同路径多文件按文件名序）。
apply_spec :: proc(root: ^Node, path: string, spec: json.Object, deps: Deps) {
	node, hit_wildcard := descend(root, path)
	// 上游 :405 `if (node !== tree)`：落到根上的规格整条不生效。
	if node == root {
		return
	}
	node.wildcard = hit_wildcard

	for key, val in spec {
		switch key {
		case "action":
			obj, is_obj := val.(json.Object)
			if ! is_obj {
				continue
			}
			if hit_wildcard {
				node.wildcard_action_type = json_str_field(obj, "type")
				node.wildcard_action_path = json_str_field(obj, "path")
				node.has_wildcard_action = true
			} else {
				node.action_type = json_str_field(obj, "type")
				node.action_path = json_str_field(obj, "path")
			}
		case "depends":
			if _, is_obj := val.(json.Object); ! is_obj {
				continue
			}
			node.depends_json = json_unparse(val)
			node.has_depends = true
		case "wildcard":
			b, is_b := val.(json.Boolean)
			if ! is_b {
				continue
			}
			node.wildcard = bool(b)
		case "firstchild_ineligible":
			b, is_b := val.(json.Boolean)
			if ! is_b {
				continue
			}
			node.firstchild_ineligible = bool(b)
		case "order":
			// 只接受整数形态（"250" 与 5.0 都忽略，对齐上游 json.Integer）。
			if i, is_i := val.(json.Integer); is_i {
				node.order = int(i)
			}
		case "title":
			if s, is_s := val.(json.String); is_s {
				node.title = string(s)
			}
		case "auth":
			obj, is_obj := val.(json.Object)
			if ! is_obj {
				continue
			}
			node.has_auth = true
			node.auth_login = false
			if lv, has := obj["login"]; has {
				if lb, is_b := lv.(json.Boolean); is_b {
					node.auth_login = bool(lb)
				}
			}
		case "cors", "css", "setgroup", "setuser":
			continue // schema 里存在但树不用（其余未知键：忽略）
		}
	}

	// depends.acl 与 satisfied：后一份规格覆盖前一份——没 depends 就清空/恒真。
	node.acl_groups = nil
	if dep, has := spec["depends"]; has {
		if dep_obj, is_obj := dep.(json.Object); is_obj {
			if acl, has_acl := dep_obj["acl"]; has_acl {
				node.acl_groups = parse_acl_groups(acl)
			}
		}
	}
	// 上游 :416 无条件重算：没有 depends（或非 object）时 check_depends 返回 true。
	depv, _ := spec["depends"]
	node.satisfied = check_depends(depv, deps)
}

// descend —— 按 '/' 切段下降，缺节点就现建。段首为 '*' → 停在这一层并把 wildcard 标在父节点上。
descend :: proc(root: ^Node, path: string) -> (node: ^Node, wildcard: bool) {
	node = root
	rest := path
	for {
		for len(rest) > 0 && rest[0] == '/' {
			rest = rest[1:]
		}
		if len(rest) == 0 {
			break
		}
		seg := rest
		if i := strings.index_byte(rest, '/'); i >= 0 {
			seg, rest = rest[:i], rest[i:]
		} else {
			rest = ""
		}
		if seg[0] == '*' {
			return node, true
		}
		if node.children == nil {
			node.children = make(map[string]^Node)
		}
		child, has := node.children[seg]
		if ! has {
			child = new_node()
			node.children[seg] = child
		}
		node = child
	}
	return node, false
}

json_str_field :: proc(obj: json.Object, key: string) -> string {
	if v, has := obj[key]; has {
		if s, is_s := v.(json.String); is_s {
			return string(s)
		}
	}
	return ""
}

// ---------------------------------------------------------------------------
// JSON 小工具
// ---------------------------------------------------------------------------

as_obj :: proc(v: json.Value) -> (json.Object, bool) { o, ok := v.(json.Object); return o, ok }
as_arr :: proc(v: json.Value) -> (json.Array, bool) { a, ok := v.(json.Array); return a, ok }
as_str :: proc(v: json.Value) -> (string, bool) { s, ok := v.(json.String); return string(s), ok }
as_bool :: proc(v: json.Value) -> (bool, bool) { b, ok := v.(json.Boolean); return bool(b), ok }

json_opts : json.Marshal_Options = {spec = .JSON, sort_maps_by_key = true}
json_unparse :: proc(v: json.Value) -> string {
	s, err := json.unparse(v, json_opts, context.allocator)
	if err != nil {
		return "null"
	}
	return s
}

// ---------------------------------------------------------------------------
// depends：fs / uci 判定（对齐上游 check_depends 家族）
//
// 三处共同规则：取值不是 array/object → 整项忽略（上游 for..in 拿不到东西 ⇒ 恒成立）；
// array = 任一备选成立；object = 单个备选（其内部条目全部成立）。depends.acl 不在这里：留给每请求。
// ---------------------------------------------------------------------------

// parse_acl_groups —— 取 depends.acl 的组名列表。对象形态取键（真机形态）、数组形态取元素、
// 裸字符串收一格（宽松一档）。
parse_acl_groups :: proc(val: json.Value) -> []string {
	if a, is_a := val.(json.Array); is_a {
		out := [dynamic]string{}
		for el in a {
			if s, is_s := el.(json.String); is_s {
				append(&out, string(s))
			}
		}
		if len(out) == 0 {
			delete(out)
			return nil
		}
		sort.heap_sort(out[:])
		return out[:]
	}
	if o, is_o := val.(json.Object); is_o {
		out := [dynamic]string{}
		for name, _ in o {
			append(&out, name)
		}
		if len(out) == 0 {
			delete(out)
			return nil
		}
		sort.heap_sort(out[:])
		return out[:]
	}
	if s, is_s := val.(json.String); is_s {
		out := [dynamic]string{}
		append(&out, string(s))
		return out[:]
	}
	return nil
}

check_depends :: proc(depends: json.Value, deps: Deps) -> bool {
	table, is_obj := depends.(json.Object)
	if ! is_obj {
		return true
	}
	if fs, has := table["fs"]; has && ! check_fs_depends(fs, deps) {
		return false
	}
	if uci, has := table["uci"]; has && ! check_uci_depends(uci, deps) {
		return false
	}
	return true
}

check_fs_depends :: proc(val: json.Value, deps: Deps) -> bool {
	_ = deps
	if a, is_a := val.(json.Array); is_a {
		for alt in a {
			if fs_entry_satisfied(alt) {
				return true
			}
		}
		return false
	}
	if _, is_obj := val.(json.Object); is_obj {
		return fs_entry_satisfied(val)
	}
	return true // 其它形态：整项忽略
}

check_uci_depends :: proc(val: json.Value, deps: Deps) -> bool {
	if a, is_a := val.(json.Array); is_a {
		for alt in a {
			if uci_entry_satisfied(alt, deps) {
				return true
			}
		}
		return false
	}
	if _, is_obj := val.(json.Object); is_obj {
		return uci_entry_satisfied(val, deps)
	}
	return true
}

// 一个 fs 备选：{路径: 要求类型}，每个条目都要成立。要求类型四种，认不出的忽略；
// 备选本身不是 object（例如裸字符串）视为成立。
fs_entry_satisfied :: proc(entry: json.Value) -> bool {
	obj, is_obj := entry.(json.Object)
	if ! is_obj {
		return true
	}
	for path, kind_val in obj {
		kind, is_str := kind_val.(json.String)
		if ! is_str {
			continue
		}
		switch string(kind) {
		case "directory":
			if ! directory_non_empty(path) {
				return false
			}
		case "executable":
			if ! regular_file(path, true) {
				return false
			}
		case "file":
			if ! regular_file(path, false) {
				return false
			}
		case "absent":
			if _, err := os.stat(path, context.allocator); err == nil {
				return false
			}
		}
	}
	return true
}

// 一个 uci 备选：{config: true | {section: options}}，每个 config 条目都要成立。
uci_entry_satisfied :: proc(entry: json.Value, deps: Deps) -> bool {
	obj, is_obj := entry.(json.Object)
	if ! is_obj {
		return true
	}
	for config, values in obj {
		if b, is_b := values.(json.Boolean); is_b {
			if bool(b) && ! config_has_section(config, deps) {
				return false
			}
			continue
		}
		if sect, is_sect := values.(json.Object); is_sect {
			if ! uci_sections_satisfied(config, sect, deps) {
				return false
			}
		}
		// 其它取值（字符串/数字/null）：上游两分支都不进 → 忽略
	}
	return true
}

config_has_section :: proc(config: string, deps: Deps) -> bool {
	sections, ok := uci_of(deps, config)
	return ok && len(sections) > 0
}

// uci_sections_satisfied —— section 表：键是 `@<type>` 时「任一该类型 section 满足 options」即可，
// 否则必须存在同名 section。
uci_sections_satisfied :: proc(config: string, sect: json.Object, deps: Deps) -> bool {
	sections, _ := uci_of(deps, config)

	keys := [dynamic]string{}
	defer delete(keys)
	for k, _ in sect {
		append(&keys, k)
	}
	sort.heap_sort(keys[:])

	for key in keys {
		options := sect[key]
		if type_name, is_type := at_section_type(key); is_type {
			found := false
			for i := 0; i < len(sections); i += 1 {
				if sections[i].type_name != type_name {
					continue
				}
				if uci_options_satisfied(sections[i], options) {
					found = true
					break
				}
			}
			if ! found {
				return false
			}
			continue
		}

		target: ^backend.Uci_Section = nil
		for i := 0; i < len(sections); i += 1 {
			if sections[i].name == key {
				target = &sections[i]
				break
			}
		}
		if target == nil || ! uci_options_satisfied(target^, options) {
			return false
		}
	}
	return true
}

// at_section_type —— `@<type>` 形态（上游 :231 的 /^@([A-Za-z0-9_-]+)$/）。
at_section_type :: proc(key: string) -> (string, bool) {
	if len(key) < 2 || key[0] != '@' {
		return "", false
	}
	for i := 1; i < len(key); i += 1 {
		c := key[i]
		ok := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '-'
		if ! ok {
			return "", false
		}
	}
	return key[1:], true
}

// uci_options_satisfied —— section 的 options 判定（上游 :198-227）。
uci_options_satisfied :: proc(s: backend.Uci_Section, opts: json.Value) -> bool {
	// options 为字符串 → 比对 section 的 .type
	if want, is_s := opts.(json.String); is_s {
		return s.type_name == string(want)
	}
	// options 为 true → section 至少有一个 option
	if b, is_b := opts.(json.Boolean); is_b {
		return bool(b) && len(s.options) > 0
	}

	obj, is_obj := opts.(json.Object)
	if ! is_obj {
		return true
	}

	names := [dynamic]string{}
	defer delete(names)
	for name, _ in obj {
		append(&names, name)
	}
	sort.heap_sort(names[:])

	for name in names {
		want := obj[name]
		got, has := uci_option_by_name(s, name)
		is_array := has && got.is_list

		if is_array {
			// 上游：`if (!(value in sval)) return false`
			if ! value_in(got.values, want) {
				return false
			}
			continue
		}
		if wb, is_b := want.(json.Boolean); is_b && bool(wb) {
			// 上游：`value === true` → 只要 sval != null
			if ! has {
				return false
			}
			continue
		}
		// 上游：`sval != value`
		if ! has || len(got.values) == 0 {
			return false
		}
		want_str, comparable := json_scalar(want)
		if ! comparable || got.values[0] != want_str {
			return false
		}
	}
	return true
}

uci_option_by_name :: proc(s: backend.Uci_Section, name: string) -> (backend.Uci_Option, bool) {
	for o in s.options {
		if o.name == name {
			return o, true
		}
	}
	return backend.Uci_Option{}, false
}

value_in :: proc(values: []string, want: json.Value) -> bool {
	want_str, comparable := json_scalar(want)
	if ! comparable {
		return false
	}
	for v in values {
		if v == want_str {
			return true
		}
	}
	return false
}

// json_scalar —— JSON 标量 → 可与 uci option 字符串比较的文本。object/array/null 没法比较。
json_scalar :: proc(v: json.Value) -> (string, bool) {
	if s, is_s := v.(json.String); is_s {
		return string(s), true
	}
	if b, is_b := v.(json.Boolean); is_b {
		if bool(b) {
			return "true", true
		}
		return "false", true
	}
	if i, is_i := v.(json.Integer); is_i {
		return fmt.tprintf("%d", i), true
	}
	if f, is_f := v.(json.Float); is_f {
		return fmt.tprintf("%g", f), true
	}
	return "", false
}

// regular_file —— 对齐上游 stat()：跟随符号链接（os.stat 就是跟随的）。
regular_file :: proc(path: string, require_exec: bool) -> bool {
	info, err := os.stat(path, context.allocator)
	if err != nil || info.type != .Regular {
		return false
	}
	if require_exec && ! (.Execute_User in info.mode) {
		return false
	}
	return true
}

// directory_non_empty —— 对齐上游 `length(lsdir(path))`：目录存在且非空。
directory_non_empty :: proc(path: string) -> bool {
	entries, err := os.read_all_directory_by_path(path, context.allocator)
	if err != nil {
		return false
	}
	return len(entries) > 0
}

// ---------------------------------------------------------------------------
// 路径解析
// ---------------------------------------------------------------------------

// node_visible —— 节点在本会话下是否可见。satisfied 要过；login（无会话的放行模式）豁免 acl 缺组那半。
node_visible :: proc(n: ^Node, sid: string, login: bool, deps: Deps) -> bool {
	if ! n.satisfied {
		return false
	}
	if login {
		return true
	}
	return ! node_acl_missing(n, sid, deps)
}

node_acl_missing :: proc(n: ^Node, sid: string, deps: Deps) -> bool {
	if len(n.acl_groups) == 0 {
		return false
	}
	return acl_level_of(deps, sid, n.acl_groups) == .Missing
}

// Resolve —— 对齐上游 resolve_page（:503-553）：逐段下降；子节点不存在或 !visible 就停上一层报未命中。
// 唯一例外：当前节点是通配层且下一段没有可用实子节点 → 把剩下的段全当参数收下，算命中。
Resolve :: proc(tree: ^Node, path, sid: string, deps: Deps) -> Resolved {
	segs := split_segments(path)
	node := tree
	// acl 组并集要跨出本函数（进 Resolved），故用 [dynamic] 但不 defer delete（随 arena 存活）。
	groups := [dynamic]string{}
	auth := auth_absorb(AuthState{}, tree)

	for i := 0; i < len(segs); i += 1 {
		next, has := child_of(node, segs[i])
		wvisible := has && node_visible(next, sid, false, deps)
		if node.wildcard && ! wvisible {
			args := clone_segments(segs[i:])
			return Resolved{node = node, args = args, found = true, acl_groups = groups[:], auth = auth}
		}
		if ! wvisible {
			// 下降失败也把沿途 auth 带回去：无会话时「被 ACL 截断」正是要判 403 + 登录提示的形态。
			return Resolved{node = node, acl_groups = groups[:], auth = auth}
		}
		append_all(&groups, next.acl_groups)
		auth = auth_absorb(auth, next)
		node = next
	}
	return Resolved{node = node, found = true, acl_groups = groups[:], auth = auth}
}

// Action 是 effective_action 的结果。
Action :: struct {
	atype: string,
	path:  string,
}

// effective_action —— 对齐上游 :1006-1011：先用 node.action；有剩余段且存在 wildcardaction 时改用它。
effective_action :: proc(node: ^Node, args: []string) -> Action {
	if len(args) > 0 && node.has_wildcard_action {
		return Action{atype = node.wildcard_action_type, path = node.wildcard_action_path}
	}
	return Action{atype = node.action_type, path = node.action_path}
}

// First_Child —— 对齐上游 resolve_firstchild（:582-624）：在 satisfied、有 title、action 是对象的子节点里
// 挑权重最小者；子节点自己也是 firstchild 时递归下降，且它必须有可当选的后代才有资格当选。
// 权重相同按段名字典序取小（换成显式规则，保证多次运行一致）。groups/auth 在候选副本上累积，赢了才并回。
First_Child :: proc(node: ^Node, sid: string, groups: ^[dynamic]string, auth: ^AuthState, login_allowed: bool, deps: Deps) -> ^Node {
	if node.children == nil || len(node.children) == 0 {
		return nil
	}
	names := [dynamic]string{}
	defer delete(names)
	for name, _ in node.children {
		append(&names, name)
	}
	sort.heap_sort(names[:])

	best: ^Node = nil
	best_weight := 0
	best_name := ""
	best_groups := [dynamic]string{}
	defer delete(best_groups)

	base_auth := AuthState{}
	if auth != nil {
		base_auth = auth^
	}
	best_auth := base_auth

	for name in names {
		child := node.children[name]
		// 无会话时的 login 放行模式（:593）——命中就让 ACL 缺组的子节点也进竞选。
		child_login := len(sid) == 0 && (login_allowed || child.auth_login)
		if len(child.title) == 0 || child.firstchild_ineligible ||
			! node_visible(child, sid, child_login, deps) {
			continue
		}

		// 这条支路自己的 depends.acl 与 auth 也在候选副本上累积：只有当选的那条才并回 ctx。
		cand_groups := [dynamic]string{}
		append_all(&cand_groups, child.acl_groups)
		cand_auth := auth_absorb(base_auth, child)

		candidate := child
		if child.action_type == "firstchild" {
			candidate = First_Child(child, sid, &cand_groups, &cand_auth, child_login, deps)
			if candidate == nil {
				delete(cand_groups)
				continue // 没有可当选的后代 → 本节点不能当选
			}
		} else if len(child.action_type) == 0 {
			delete(cand_groups)
			continue // action 不是对象
		}

		w := node_weight(child)
		if best == nil || w < best_weight || (w == best_weight && name < best_name) {
			best, best_weight, best_name = candidate, w, name
			clear(&best_groups)
			append_all(&best_groups, cand_groups[:])
			best_auth = cand_auth
		}
		delete(cand_groups)
	}

	if best != nil {
		if groups != nil {
			append_all(groups, best_groups[:])
		}
		if auth != nil {
			auth^ = best_auth
		}
	}
	return best
}

// node_weight —— order 夹到 9999；auth/login 再加 10000 压到菜单末尾。
node_weight :: proc(n: ^Node) -> int {
	w := n.order
	if w > 9999 {
		w = 9999
	}
	if n.action_path == "auth/login" || n.action_path == "auth.login" {
		w += 10000
	}
	return w
}

child_of :: proc(n: ^Node, seg: string) -> (^Node, bool) {
	if n.children == nil {
		return nil, false
	}
	c, has := n.children[seg]
	return c, has
}

// split_segments —— "/admin/status/overview" → {admin,status,overview}；空串 → 空切片。
split_segments :: proc(path: string) -> []string {
	out := [dynamic]string{}
	rest := path
	for {
		for len(rest) > 0 && rest[0] == '/' {
			rest = rest[1:]
		}
		if len(rest) == 0 {
			break
		}
		if i := strings.index_byte(rest, '/'); i >= 0 {
			append(&out, rest[:i])
			rest = rest[i:]
		} else {
			append(&out, rest)
			rest = ""
		}
	}
	return out[:]
}

// append_all —— 把一个 []string 的元素逐个并进目标（Odin 的 append 不吃 splat）。
append_all :: proc(dst: ^[dynamic]string, src: []string) {
	for s in src {
		append(dst, s)
	}
}

clone_segments :: proc(segs: []string) -> []string {
	res := [dynamic]string{}
	append_all(&res, segs)
	return res[:]
}

// ---------------------------------------------------------------------------
// 进程内缓存（mtime 失效）：目录 *.json 的「个数 + 最新 mtime」一变就整棵重建。
// 树不含会话状态 → 可跨请求共享。树的数据全部落在 cache_arena（长生命周期分配器），
// **绝不**用请求 arena——所以重建时把 context.allocator 临时指向 cache_arena。
// ---------------------------------------------------------------------------

cache_lock: sync.Mutex
cache_dir: string
cache_count: int
cache_newest: i64
cache_backing: []u8
cache_arena: mem.Arena
cache_tree: ^Node
cache_inited: bool

// Load_Tree —— 读目录 → 必要时重建树，返回根。ok==false 表示菜单目录读不到（不存在/无权限），
// 调用方把整个专家版前缀当 404。失败不进缓存（下次请求重试）。
Load_Tree :: proc(dir: string, deps: Deps) -> (tree: ^Node, ok: bool) {
	// 先扫一遍目录拿 count / newest / names（这些字符串只在本次比较用，落请求 arena 即可）。
	infos, err := os.read_all_directory_by_path(dir, context.allocator)
	if err != nil {
		fmt.eprintln("[molly] 读不到菜单目录:", dir)
		return empty_tree(), false
	}
	names := [dynamic]string{}
	defer delete(names)
	newest: i64 = 0
	for fi in infos {
		if fi.type == .Directory || ! strings.has_suffix(fi.name, ".json") {
			continue
		}
		append(&names, fi.name)
		t := time.to_unix_nanoseconds(fi.modification_time)
		if t > newest {
			newest = t
		}
	}
	sort.heap_sort(names[:])
	count := len(names)

	sync.mutex_lock(&cache_lock)
	defer sync.mutex_unlock(&cache_lock)
	if cache_inited && cache_dir == dir && cache_count == count && cache_newest == newest {
		return cache_tree, true
	}

	// 重建：backing 只在首次分配（长生命周期），每次重建用同一块 arena（arena_init 把游标归零，
	// 同时作废上一棵树的全部分配——旧树已被替换，无人引用）。把 context.allocator 指向 arena 后建树。
	if len(cache_backing) == 0 {
		cache_backing = make([]u8, 1<<22, runtime.default_allocator())
	}
	mem.arena_init(&cache_arena, cache_backing)

	old := context.allocator
	context.allocator = mem.arena_allocator(&cache_arena)
	tree = Build_Tree(dir, names[:], deps)
	context.allocator = old

	cache_dir = strings.clone(dir, runtime.default_allocator())
	cache_count = count
	cache_newest = newest
	cache_tree = tree
	cache_inited = true
	return tree, true
}
