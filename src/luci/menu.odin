package luci

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"

import "molly:backend"

// 菜单树：`/usr/share/luci/menu.d/*.json` → 节点树 → 请求路径解析。
// 复刻上游 `modules/luci-base/ucode/dispatcher.uc` 的 build_pagetree /
// check_depends / resolve_page / resolve_firstchild 四段语义。
//
// P3-6 起 `depends.acl` **参与裁树**（上游 apply_tree_acls，dispatcher.uc:435-445）：缺组的
// 节点对本会话不可见（路径解析不到 → 404），只有 read 的会话把节点标成只读。判定靠
// `backend.session_acl_level`，**每请求现算**——树是跨请求缓存的，节点上不能写会话状态。
// 认证（登录/会话本身）与模板渲染仍不在这里：前者是 `/ubus` 一侧的事，后者仍由占位页代替。
//
// 内存：树与节点字符串全部放在 g_cache.arena 里（进程生命周期），所以这里的
// proc 拿到的 alloc 参数有两个用途——一是「本次目录扫描的临时分配」（工作 arena，
// 每请求回收），二是树本身的 arena。build_* 系列只用后者。

// ---------------------------------------------------------------------------
// 节点
// ---------------------------------------------------------------------------

Node :: struct {
	// spec.title 的原文（未翻译；menu.d 里本来就是英文）
	title: string,

	// spec.action 的 {type, path}。缺省都是 ""。
	// type 取值：view / firstchild / alias / cbi / form / template / function …
	action_type: string,
	action_path: string,

	// 通配节点的 action：上游单独存 node.wildcardaction（dispatcher.uc:410-414），
	// 只有**有剩余段**时才改用它（:1010-1011），否则仍用 action_*。
	// 必须与 action_* 分开存：`wv` 与 `wv/*` 落在同一个节点上，合成一个字段时
	// 后处理的文件会把 base action 覆盖掉（真实样本 19 条通配路径）。
	wildcard_action_type: string,
	wildcard_action_path: string,
	has_wildcard_action:  bool,

	// spec.order ?? 9999
	order: int,

	// depends 的原文 JSON（排序后），只用于展示。
	depends_json: string,
	has_depends:  bool,

	// 路径里出现过以 '*' 开头的段（上游 node.wildcard）：
	// 命中的那层节点收下剩余段，作为 request_args。
	wildcard: bool,

	// spec.firstchild_ineligible：不参与 firstchild 竞选
	firstchild_ineligible: bool,

	// depends 判定结果。只算 fs / uci（上游 check_depends 不看 acl）。
	// acl 那半是**每请求现算**的（见 acl_groups）：树跨请求缓存，节点上不能写会话相关状态。
	satisfied: bool,

	// depends.acl 列出的组名（P3-6）。空 = 本节点没有 acl 要求。
	// 解析在树 arena 里，判定在请求里（backend.session_acl_level）。
	acl_groups: []string,

	// 子节点。键是路径段，用 map 做 O(1) 下降；遍历顺序不确定，
	// 需要顺序的地方（firstchild 竞选）用 (weight, 段名) 显式定序。
	children: map[string]^Node,
}

// dispatch resolve 的结果。
Resolved :: struct {
	node:  ^Node,
	args:  []string,
	found: bool,

	// 沿途（含通配层）所有节点的 depends.acl 组名并集——上游 ctx.acls（dispatcher.uc:460-461）。
	// 最终判权用并集：其中**任一**组是 write 就不算只读（上游 check_acl_depends 返回 writable）。
	acl_groups: []string,
}

// ---------------------------------------------------------------------------
// 进程内缓存（mtime 失效）
//
// 上游把索引写进 /tmp/luci-indexcache；P2 明确**不写**那个文件（决策 6），
// 免得与真 LuCI 的缓存格式打架。这里退化成进程内缓存：目录里 *.json 的
// 「个数 + 最新修改时间」一变就整棵重建。
//
// 树放在随缓存一起生死动态 arena 里：重建时整个销毁，不需要递归释放节点，
// 也不会在长连接下越住越大（风险 R6）。
// ---------------------------------------------------------------------------

@(private)
Cache :: struct {
	dir:    string,
	count:  int,
	newest: i64, // 目录内 *.json 的最新 mtime（unix 纳秒）
	arena:  mem.Dynamic_Arena,
	inited: bool,
	tree:   ^Node,
}

@(private)
g_cache: Cache

// 读目录 → 必要时重建树。work 是本次扫描用的临时分配器（handler 传每请求 arena）。
//
// 返回值 ok == false 表示菜单目录读不到（不存在 / 无权限），调用方应当把
// /cgi-bin/luci 全部当 404。失败不进缓存：下次请求会重新尝试。
load_tree :: proc(dir: string, work: mem.Allocator) -> (tree: ^Node, ok: bool) {
	entries, err := os.read_directory_by_path(dir, -1, work)
	if err != nil {
		fmt.eprintln("[molly] 读不到菜单目录:", dir, "-", err)
		return empty_tree(work), false
	}

	count := 0
	newest: i64 = 0
	for e in entries {
		if e.type == .Directory || !strings.has_suffix(e.name, ".json") {
			continue
		}
		count += 1
		if t := time.to_unix_nanoseconds(e.modification_time); t > newest {
			newest = t
		}
	}

	if g_cache.inited && g_cache.dir == dir && g_cache.count == count && g_cache.newest == newest {
		return g_cache.tree, true
	}

	if g_cache.inited {
		mem.dynamic_arena_destroy(&g_cache.arena)
	}
	mem.dynamic_arena_init(&g_cache.arena)
	a := mem.dynamic_arena_allocator(&g_cache.arena)

	g_cache.dir = strings.clone(dir, a)
	g_cache.count = count
	g_cache.newest = newest
	g_cache.tree = build_tree(dir, entries, a)
	g_cache.inited = true

	return g_cache.tree, true
}

// 目录不可读时的兜底：只有 root，且没有子节点 → 所有 /cgi-bin/luci/* 都是 404。
@(private)
empty_tree :: proc(alloc: mem.Allocator) -> ^Node {
	root := new(Node, alloc)
	root.action_type = "firstchild"
	root.satisfied = true
	root.children = make(map[string]^Node, 0, alloc)
	return root
}

// ---------------------------------------------------------------------------
// 建树
// ---------------------------------------------------------------------------

@(private)
build_tree :: proc(dir: string, entries: []os.File_Info, alloc: mem.Allocator) -> ^Node {
	root := empty_tree(alloc)

	names := make([dynamic]string, 0, len(entries), alloc)
	for e in entries {
		if e.type == .Directory || !strings.has_suffix(e.name, ".json") {
			continue
		}
		append(&names, e.name)
	}
	// 文件名排序：同一路径被多个文件定义时「谁最后生效」必须是确定的，
	// 否则 firstchild 的结果会随 readdir 顺序漂移。
	slice.sort(names[:])

	for name in names {
		full := strings.concatenate({dir, "/", name}, alloc)
		data, read_err := os.read_entire_file(full, alloc)
		if read_err != nil {
			fmt.eprintln("[molly] 读不到菜单文件:", full)
			continue
		}
		merge_menu_file(root, data, alloc)
	}
	return root
}

@(private)
merge_menu_file :: proc(root: ^Node, data: []byte, alloc: mem.Allocator) {
	doc: json.Value
	if json.unmarshal(data, &doc, .JSON, alloc) != nil {
		fmt.eprintln("[molly] 菜单文件 JSON 解析失败，整份跳过")
		return
	}
	obj, is_obj := doc.(json.Object)
	if !is_obj {
		return
	}

	// JSON 对象是 map，遍历顺序不确定；排一下让「同文件内多个 spec 落到同一节点」
	// 这种罕见情况也可复现。
	paths := make([dynamic]string, 0, len(obj), alloc)
	for path in obj {
		append(&paths, path)
	}
	slice.sort(paths[:])

	for path in paths {
		spec, is_spec := obj[path].(json.Object)
		if !is_spec {
			continue
		}
		apply_spec(root, path, spec, alloc)
	}
}

// 一条 menu.d 规格 → 树上的一个节点。上游 build_pagetree 的 schema 处理
// （dispatcher.uc:349-360 的 schema 表、:405-416 的拷贝）逐键判定：
//   - schema 之外的键、类型不符的键 → **只忽略这个键**，不丢弃整条规格；
//   - 只覆盖 spec 里出现的键，没出现的键保留前一份定义（同路径多文件时按文件名序）；
//   - 路径里有 '*' 段时 action 进 wildcard_action_*，否则进 action_*。
// 未建模的 schema 键（auth / cors / setgroup / setuser）在 P2 不进树：认证与 ACL
// 是 P3 的范围（决策 6）；css 是 molly 自己的扩展键，同样不进树。
@(private)
apply_spec :: proc(root: ^Node, path: string, spec: json.Object, alloc: mem.Allocator) {
	node, hit_wildcard := descend(root, path, alloc)

	// 上游 :405 `if (node !== tree)`：落到根上的规格整条不生效
	if node == root {
		return
	}

	// 上游 :395：路径里出现 '*' 段就把这一层标成通配层（后面的 `wildcard` 键可覆盖它）
	node.wildcard = hit_wildcard

	for key, val in spec {
		switch key {
		case "action":
			obj, is_obj := val.(json.Object)
			if !is_obj {
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
			obj, is_obj := val.(json.Object)
			if !is_obj {
				continue
			}
			text, err := json.unparse(val, {spec = .JSON, sort_maps_by_key = true}, alloc)
			if err != nil {
				continue
			}
			node.depends_json = text
			node.has_depends = true
		case "wildcard":
			b, is_bool := val.(json.Boolean)
			if !is_bool {
				continue
			}
			// 上游先按路径里的 '*' 把 wildcard 置 true（:395），随后 schema 拷贝
			// 可能用 spec.wildcard 覆盖它——这里的顺序与之一致。
			node.wildcard = bool(b)
		case "firstchild_ineligible":
			b, is_bool := val.(json.Boolean)
			if !is_bool {
				continue
			}
			node.firstchild_ineligible = bool(b)
		case "order":
			n, is_int := val.(json.Integer)
			if !is_int {
				continue
			}
			node.order = int(n)
		case "title":
			s, is_str := val.(json.String)
			if !is_str {
				continue
			}
			node.title = string(s)
		case "auth", "cors", "css", "setgroup", "setuser":
			// schema 里存在（css 是扩展），但 P2 的树不用它们
			continue
		case:
			// schema 之外的键：忽略
			continue
		}
	}

	// depends.acl 与 satisfied 一样**后一份规格覆盖前一份**：没有 depends 就清空。
	// acl 只解析存档（组名列表），判定留给每请求（见 Node.acl_groups 的注释）。
	node.acl_groups = nil
	if dep, has_dep := spec["depends"]; has_dep {
		if dep_obj, dep_ok := dep.(json.Object); dep_ok {
			if acl, has_acl := dep_obj["acl"]; has_acl {
				node.acl_groups = parse_acl_groups(acl, alloc)
			}
		}
	}

	// 上游 :416 无条件重算：没有 depends（或 depends 不是 object）时 check_depends
	// 返回 true，所以后一份规格会把 satisfied 重置回 true。
	node.satisfied = check_depends(spec["depends"], alloc)
}

// 按 '/' 切段下降，沿途缺节点就现建。
//
// 段首为 '*' 表示通配：**停在这一层**并把 wildcard 标在父节点上（上游行为），
// 于是 `admin/status/logs/*` 把 `admin/status/logs` 变成通配层。
@(private)
descend :: proc(root: ^Node, path: string, alloc: mem.Allocator) -> (node: ^Node, wildcard: bool) {
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
			seg = rest[:i]
			rest = rest[i:]
		} else {
			rest = ""
		}
		if seg[0] == '*' {
			return node, true
		}
		if node.children == nil {
			node.children = make(map[string]^Node, 0, alloc)
		}
		child, has := node.children[seg]
		if !has {
			child = new(Node, alloc)
			child.order = 9999
			// menu.d 里没显式声明的中间层：没有 depends，也就没有理由拦它。
			// （真 LuCI 的 menu.d 会给中间层写 {title, action:{type:firstchild}}，
			// 这里只是别把「只写了叶子」的菜单变成整棵 404。）
			child.satisfied = true
			node.children[strings.clone(seg, alloc)] = child
		}
		node = child
	}
	return node, false
}

@(private)
json_str_field :: proc(obj: json.Object, key: string) -> string {
	val, has := obj[key]
	if !has {
		return ""
	}
	s, is_str := val.(json.String)
	if !is_str {
		return ""
	}
	return string(s)
}

// ---------------------------------------------------------------------------
// depends 判定
//
// 复刻上游 check_depends 家族（dispatcher.uc，同一提交 d6167ea）：
//   check_depends             :278-310  fs / uci 两组都成立才 satisfied
//   check_fs_depends          :171-196  条目 = {路径: 要求类型}，全部条目都要成立
//   check_uci_depends         :258-276  config → true / {section: options}
//   check_uci_depends_section :229-256  section 键可为具名或 '@type'（任一该类型的）
//   check_uci_depends_options :198-227  options 可为 string / true / {option: 值}
//
// 三处共同规则（第 6b 步纠正的正是这里）：
//   - 取值不是 array / object → 整项**忽略**（上游 for..in 拿不到东西 ⇒ 恒成立），
//     不能当成「空集合 ⇒ 不满足」；
//   - array = 任一备选成立；object = 单个备选（其内部条目**全部**成立）；
//   - 认不出的形态（要求类型不是四种之一、config 取值不是 true/object）→ 忽略。
//
// **depends.acl 不在 check_depends 里**：上游把它留给 apply_tree_acls（dispatcher.uc:435-445）。
// molly 的树跨请求缓存，所以不学上游把结果写回节点，而是每请求现算（见 node_visible）。
// ---------------------------------------------------------------------------

// depends.acl 的组名列表。上游 `for (let group in require_groups)` 取的是**键**，所以
// 对象形态（`{ "luci-base": ["status"] }`——真机 menu.d 里就有这种写法）与数组形态
// （`["luci-base"]`）都要认；裸字符串也收一格（宽松一档，上游只吃数组/对象）。
@(private)
parse_acl_groups :: proc(val: json.Value, alloc: mem.Allocator) -> []string {
	#partial switch v in val {
	case json.Array:
		out := make([dynamic]string, 0, len(v), alloc)
		for el in v {
			if s, is_str := el.(json.String); is_str {
				append(&out, string(s))
			}
		}
		return out[:]
	case json.Object:
		out := make([dynamic]string, 0, len(v), alloc)
		for name, _ in v {
			append(&out, name)
		}
		return out[:]
	case json.String:
		out := make([]string, 1, alloc)
		out[0] = string(v)
		return out
	}
	return nil
}

@(private)
check_depends :: proc(depends: json.Value, alloc: mem.Allocator) -> bool {
	table, is_table := depends.(json.Object)
	if !is_table {
		return true
	}

	if val, has := table["fs"]; has && !check_fs_depends(val, alloc) {
		return false
	}
	if val, has := table["uci"]; has && !check_uci_depends(val, alloc) {
		return false
	}
	return true
}

// 备选形态（上游 :279-292 与 :294-307 是同一套形状判断）：array → 任一备选成立；
// object → 单个备选；其它取值 → 整项忽略（返回 true）。
@(private)
check_fs_depends :: proc(val: json.Value, alloc: mem.Allocator) -> bool {
	#partial switch v in val {
	case json.Array:
		for alt in v {
			if fs_entry_satisfied(alt, alloc) {
				return true
			}
		}
		return false
	case json.Object:
		return fs_entry_satisfied(val, alloc)
	}
	return true
}

@(private)
check_uci_depends :: proc(val: json.Value, alloc: mem.Allocator) -> bool {
	#partial switch v in val {
	case json.Array:
		for alt in v {
			if uci_entry_satisfied(alt, alloc) {
				return true
			}
		}
		return false
	case json.Object:
		return uci_entry_satisfied(val, alloc)
	}
	return true
}

// 一个 fs 备选：{路径: 要求类型}，**每个条目**都要成立（上游 :171-196 的
// check_fs_depends）。要求类型只有四种，认不出的一律忽略（上游没有 else 分支）；
// 备选本身不是 object（真实样本 0 例，例如裸字符串）同样视为成立。
@(private)
fs_entry_satisfied :: proc(entry: json.Value, alloc: mem.Allocator) -> bool {
	obj, is_obj := entry.(json.Object)
	if !is_obj {
		return true
	}

	for path, kind_val in obj {
		kind, is_str := kind_val.(json.String)
		if !is_str {
			continue
		}
		switch string(kind) {
		case "directory":
			// 上游：`if (!length(lsdir(path))) return false` —— 目录要存在且非空
			if !directory_non_empty(path, alloc) {
				return false
			}
		case "executable":
			// 上游：`stat().type == 'file' && user_exec` —— 普通文件且属主可执行位
			if !regular_file(path, alloc, require_exec = true) {
				return false
			}
		case "file":
			if !regular_file(path, alloc) {
				return false
			}
		case "absent":
			// 上游：`if (stat(path) != null) return false` —— 必须不存在
			if os.exists(path) {
				return false
			}
		case:
			// 未知要求类型：忽略这个条目
		}
	}
	return true
}

// 一个 uci 备选：{config: true | {section: options}}，**每个 config 条目**都要成立
// （上游 :258-276 的 check_uci_depends）。取值不是 true / object 的 config 被忽略。
@(private)
uci_entry_satisfied :: proc(entry: json.Value, alloc: mem.Allocator) -> bool {
	obj, is_obj := entry.(json.Object)
	if !is_obj {
		return true
	}

	for config, values in obj {
		if b, is_bool := values.(json.Boolean); is_bool {
			// `true`：config 至少有 1 个 section（上游 uci.load + uci.foreach）
			if bool(b) && !config_has_section(config, alloc) {
				return false
			}
			continue
		}
		if sect, is_sect := values.(json.Object); is_sect {
			if !uci_sections_satisfied(config, sect, alloc) {
				return false
			}
		}
		// 其它取值（字符串 / 数字 / null）：上游两个分支都不进 → 忽略
	}
	return true
}

@(private)
config_has_section :: proc(config: string, alloc: mem.Allocator) -> bool {
	sections, ok := backend.uci_config_sections(config, alloc)
	return ok && len(sections) > 0
}

// 一个 uci 备选里的 section 表（上游 :229-256 check_uci_depends_section）：
// 键是 `@<type>` 时「任一该类型 section 满足 options」即可，否则必须存在同名 section。
@(private)
uci_sections_satisfied :: proc(config: string, sect: json.Object, alloc: mem.Allocator) -> bool {
	sections, _ := backend.uci_config_sections(config, alloc)

	for key, options in sect {
		if type_name, is_type := at_section_type(key); is_type {
			found := false
			for s in sections {
				if s.type_name != type_name {
					continue
				}
				if uci_options_satisfied(s, options, alloc) {
					found = true
					break
				}
			}
			if !found {
				return false
			}
			continue
		}

		target: backend.Uci_Section
		has_target := false
		for s in sections {
			if s.name == key {
				target = s
				has_target = true
				break
			}
		}
		if !has_target || !uci_options_satisfied(target, options, alloc) {
			return false
		}
	}
	return true
}

// `@<type>` 形态（上游 :231 的 `/^@([A-Za-z0-9_-]+)$/`）。Odin 没有正则，手写等价判定。
@(private)
at_section_type :: proc(key: string) -> (type_name: string, ok: bool) {
	if len(key) < 2 || key[0] != '@' {
		return "", false
	}
	for i in 1 ..< len(key) {
		c := key[i]
		switch {
		case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z', c >= '0' && c <= '9', c == '_', c == '-':
		case:
			return "", false
		}
	}
	return key[1:], true
}

// section 的 options 判定（上游 :198-227 check_uci_depends_options）。
//
// ponytail: 上游按 ucode 的动态类型比较（`sval != value`），这里只在「option 是
// list」与「期望值是 true/字符串」两路上逐字对齐；期望值是数字/对象/null 时用
// 字符串化后的精确比较代替（25.12.2 的 138 个 menu.d 里这类用例为 0，将来真用到
// 再按 ucode 的 `!=` 语义细分）。
@(private)
uci_options_satisfied :: proc(s: backend.Uci_Section, opts: json.Value, alloc: mem.Allocator) -> bool {
	// options 为字符串 → 比对 section 的 .type（上游 :199-201）
	if want, is_str := opts.(json.String); is_str {
		return s.type_name == string(want)
	}
	// options 为 true → section 至少有一个 option（上游 :202-206，跳过 '.' 开头的元数据键；
	// molly 的 Uci_Section.options 本来就不含元数据）
	if b, is_bool := opts.(json.Boolean); is_bool {
		return bool(b) && len(s.options) > 0
	}

	obj, is_obj := opts.(json.Object)
	if !is_obj {
		return true
	}

	for name, want in obj {
		got, has := uci_option_by_name(s, name)
		is_array := has && got.is_list

		if is_array {
			// 上游：`if (!(value in sval)) return false`
			if !value_in(got.values, want, alloc) {
				return false
			}
			continue
		}
		if b, is_bool := want.(json.Boolean); is_bool && bool(b) {
			// 上游：`value === true` → 只要 sval != null
			if !has {
				return false
			}
			continue
		}
		// 上游：`sval != value`
		if !has {
			return false
		}
		if len(got.values) == 0 {
			return false
		}
		want_str, comparable := json_scalar(want, alloc)
		if !comparable || got.values[0] != want_str {
			return false
		}
	}
	return true
}

@(private)
uci_option_by_name :: proc(s: backend.Uci_Section, name: string) -> (opt: backend.Uci_Option, has: bool) {
	for o in s.options {
		if o.name == name {
			return o, true
		}
	}
	return {}, false
}

@(private)
value_in :: proc(values: []string, want: json.Value, alloc: mem.Allocator) -> bool {
	want_str, comparable := json_scalar(want, alloc)
	if !comparable {
		return false
	}
	for v in values {
		if v == want_str {
			return true
		}
	}
	return false
}

// JSON 标量 → 可与 uci option 字符串比较的文本。object / array / null 没法比较。
@(private)
json_scalar :: proc(v: json.Value, alloc: mem.Allocator) -> (out: string, ok: bool) {
	#partial switch x in v {
	case json.String:
		return string(x), true
	case json.Boolean:
		return bool(x) ? "true" : "false", true
	case json.Integer:
		return fmt.aprintf("%d", i64(x), allocator = alloc), true
	case json.Float:
		return fmt.aprintf("%v", f64(x), allocator = alloc), true
	}
	return "", false
}

// 上游 :171-196 的 stat()：跟随符号链接（与原厂 uhttpd 的静态文件判定一致）。
@(private)
regular_file :: proc(path: string, alloc: mem.Allocator, require_exec := false) -> bool {
	info, err := os.stat(path, alloc)
	if err != nil || info.type != .Regular {
		return false
	}
	if require_exec && .Execute_User not_in info.mode {
		return false
	}
	return true
}

// 上游的 `length(lsdir(path))`：目录存在且**非空**（缺失 / 空目录都算不成立）。
@(private)
directory_non_empty :: proc(path: string, alloc: mem.Allocator) -> bool {
	entries, err := os.read_directory_by_path(path, -1, alloc)
	if err != nil {
		return false
	}
	return len(entries) > 0
}

// ---------------------------------------------------------------------------
// 路径解析
// ---------------------------------------------------------------------------

// 上游 resolve_page（dispatcher.uc:503-553）。
//
// 逐段下降；子节点不存在或 !satisfied 就停在上一层并报未命中。唯一的例外是
// 「当前节点是通配层且下一段没有可用的实子节点」——这时把剩下的段全部当参数
// 收下，算作命中。
// 节点在**本会话**下是否可见：depends（fs/uci）成立，且 depends.acl 要求的组没有缺的。
// 上游把这两件事都折进 node.satisfied（apply_tree_acls 把缺组的节点标 satisfied=false）——
// molly 的树是跨请求缓存的，节点上写会话相关状态会串会话，所以 acl 那半每请求现算（P3-6）。
@(private)
node_visible :: proc(n: ^Node, sid: string) -> bool {
	if !n.satisfied {
		return false
	}
	return !node_acl_missing(n, sid)
}

// depends.acl 缺失（上游 check_acl_depends 返回 null）→ 本会话看不到该节点。
// 没有 acl 要求的节点恒为可见（session_acl_level 对空列表回 Writable）。
@(private)
node_acl_missing :: proc(n: ^Node, sid: string) -> bool {
	if len(n.acl_groups) == 0 {
		return false
	}
	return backend.session_acl_level(sid, n.acl_groups) == .Missing
}

resolve :: proc(tree: ^Node, path: string, sid: string, alloc: mem.Allocator) -> Resolved {
	segs := split_segments(path, alloc)
	node := tree
	groups := make([dynamic]string, 0, 4, alloc)

	for i := 0; i < len(segs); i += 1 {
		next, has := child_of(node, segs[i])
		if node.wildcard && (!has || !node_visible(next, sid)) {
			// 通配层自己已经在 groups 里（下降时收过），剩余段当 args
			return {node = node, args = segs[i:], found = true, acl_groups = groups[:]}
		}
		if !has || !node_visible(next, sid) {
			return {node = node, found = false, acl_groups = groups[:]}
		}
		for g in next.acl_groups {
			append(&groups, g)
		}
		node = next
	}
	return {node = node, found = true, acl_groups = groups[:]}
}

// 上游 :1006-1011：先用 node.action；**有剩余段**且存在 wildcardaction 时改用它。
// 「有剩余段」= 通配层收下的 request_args 非空，正是 resolve 返回的 args。
Action :: struct {
	type: string,
	path: string,
}

effective_action :: proc(node: ^Node, args: []string) -> Action {
	if len(args) > 0 && node.has_wildcard_action {
		return {type = node.wildcard_action_type, path = node.wildcard_action_path}
	}
	return {type = node.action_type, path = node.action_path}
}

// 上游 resolve_firstchild（dispatcher.uc:467-502）：在所有 satisfied、有 title、
// action 是对象的子节点里挑权重最小的一个。子节点自己也是 firstchild 时递归下降，
// 且它必须有可当选的后代才有资格当选。
//
// 权重相同（menu.d 里 order 相等很常见）时按段名字典序取小——上游吃的是 ucode
// 对象的插入序，我们这里换成显式规则，保证多次运行结果一致。
first_child :: proc(node: ^Node, sid: string, groups: ^[dynamic]string, alloc: mem.Allocator) -> ^Node {
	if node.children == nil {
		return nil
	}
	best: ^Node = nil
	best_weight := 0
	best_name := ""
	best_groups: [dynamic]string

	for name, child in node.children {
		// 缺 depends.acl 的组 → 不参与竞选（上游 apply_tree_acls 已把它标 satisfied=false）
		if !node_visible(child, sid) || len(child.title) == 0 || child.firstchild_ineligible {
			continue
		}

		// 这条支路自己的 depends.acl 也要算进 ctx.acls（上游 resolve_firstchild 的 ctx_append）：
		// 只有**当选**的那条支路才并进 groups，所以先收在候选自己的数组里。
		cand_groups := make([dynamic]string, 0, 2, alloc)
		for g in child.acl_groups {
			append(&cand_groups, g)
		}

		candidate := child
		if child.action_type == "firstchild" {
			candidate = first_child(child, sid, &cand_groups, alloc)
			if candidate == nil {
				continue // 没有可当选的后代 → 本节点不能当选
			}
		} else if len(child.action_type) == 0 {
			continue // action 不是对象
		}

		w := node_weight(child)
		if best == nil || w < best_weight || (w == best_weight && name < best_name) {
			best, best_weight, best_name = candidate, w, name
			best_groups = cand_groups
		}
	}

	if best != nil && groups != nil {
		for g in best_groups {
			append(groups, g)
		}
	}
	return best
}

// 上游 node_weight：order 夹到 9999；auth/login 再加 10000 压到菜单末尾。
@(private)
node_weight :: proc(n: ^Node) -> int {
	w := min(n.order, 9999)
	if n.action_path == "auth/login" || n.action_path == "auth.login" {
		w += 10000
	}
	return w
}

@(private)
child_of :: proc(n: ^Node, seg: string) -> (^Node, bool) {
	if n.children == nil {
		return nil, false
	}
	c, has := n.children[seg]
	return c, has
}

// "/admin/status/overview" → {"admin","status","overview"}；空串 → 空切片。
// 输入已过 http.normalize_path，所以这里不需要再处理 "." 与 ".."。
@(private)
split_segments :: proc(path: string, alloc: mem.Allocator) -> []string {
	out := make([dynamic]string, 0, 8, alloc)
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