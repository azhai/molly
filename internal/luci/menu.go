// Package luci —— LuCI 的 dispatcher：menu.d 建树、depends 求值、ACL 裁树、渲染。
//
// 复刻上游 `modules/luci-base/ucode/dispatcher.uc`（luci 提交 d6167ea）的
// build_pagetree / check_depends / resolve_page / resolve_firstchild / apply_tree_acls
// 五段语义，与 Odin 版 src/luci/menu.odin 逐条对应。
//
// depends.acl 参与裁树：缺组的节点对本会话不可见（路径解析不到 → 404），只有 read
// 的会话把节点标成只读。树跨请求缓存，所以判定**每请求现算**（Deps.SessionACLLevel），
// 节点上不写会话相关状态。
package luci

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"

	"github.com/azhai/molly/internal/backend"
)

// Deps 是 dispatcher 需要的 backend 能力，比 backend.Backend 窄，便于单测替身。
type Deps interface {
	// UciConfigSections 是菜单 depends.uci 的数据源。
	UciConfigSections(config string) ([]backend.UciSection, bool)
	// SessionACLLevel 给出 sid 对 depends.acl 列出的组的权限档位。
	SessionACLLevel(sid string, groups []string) backend.ACLLevel
}

// ---------------------------------------------------------------------------
// 节点
// ---------------------------------------------------------------------------

// Node 是菜单树上的一个节点。字段与 Odin 版 Node 一一对应。
type Node struct {
	// Title 是 spec.title 的原文（未翻译；menu.d 里本来就是英文）。
	Title string

	// Action 的 {type, path}。type 取值：view / firstchild / alias / cbi / form / template / function …
	ActionType string
	ActionPath string

	// 通配节点的 action：上游单独存 node.wildcardaction，只有**有剩余段**时才改用它。
	// 必须与 Action* 分开存：`wv` 与 `wv/*` 落在同一个节点上，合成一个字段时
	// 后处理的文件会把 base action 覆盖掉。
	WildcardActionType string
	WildcardActionPath string
	HasWildcardAction  bool

	// Order = spec.order ?? 9999
	Order int

	// DependsJSON 是 depends 的原文 JSON（排序后），只用于展示。
	DependsJSON string
	HasDepends  bool

	// Wildcard：路径里出现过以 '*' 开头的段（上游 node.wildcard）。
	Wildcard bool

	// FirstchildIneligible = spec.firstchild_ineligible：不参与 firstchild 竞选
	FirstchildIneligible bool

	// Satisfied 是 depends 判定结果，只算 fs / uci（上游 check_depends 不看 acl）。
	Satisfied bool

	// ACLGroups 是 depends.acl 列出的组名。空 = 本节点没有 acl 要求。
	ACLGroups []string

	// Auth：molly 只用 login 那一半。HasAuth 必须单独记——上游只在 ctx.auth 非空时
	// 才走登录流程，而真实 menu.d 里的 `auth: {}` 等于没有。
	HasAuth   bool
	AuthLogin bool

	// Children 的键是路径段，用 map 做 O(1) 下降；需要顺序的地方显式定序。
	Children map[string]*Node
}

// Resolved 是 resolve 的结果。
type Resolved struct {
	Node  *Node
	Args  []string
	Found bool
	// 沿途（含通配层）所有节点的 depends.acl 组名并集（上游 ctx.acls）。
	ACLGroups []string
	// 沿途的 auth 状态（上游 ctx.auth）。
	Auth AuthState
}

// AuthState 是「最后一个带 auth 的节点」的 login 标志 + firstchild 竞选的 login 放行模式。
//
// 上游的两条语义必须分开，混起来会判错：
//   - 最后者胜：`ctx.auth = node.auth || ctx.auth`——更深的 auth 覆盖前面的；
//   - 粘滞：`login = !session && (login_allowed || child.auth?.login)`——一旦进入
//     login 模式，后代即便 ACL 缺组也放行。
type AuthState struct {
	HasAuth   bool // ctx.auth 非空
	AuthLogin bool // ...且最后那个节点标了 login
	LoginMode bool // 粘滞：出现过 login 节点
}

// loginRequired 对齐上游 :927-930：无会话 且 ctx.auth 非空且标了 login → 进登录流程。
func loginRequired(state AuthState, sid string) bool {
	return len(sid) == 0 && state.HasAuth && state.AuthLogin
}

// authAbsorb 把节点并进 auth 状态（只有节点自己带 auth 才覆盖），同时更新粘滞的 LoginMode。
func authAbsorb(state AuthState, n *Node) AuthState {
	if !n.HasAuth {
		return state
	}
	out := state
	out.HasAuth = true
	out.AuthLogin = n.AuthLogin
	out.LoginMode = out.LoginMode || n.AuthLogin
	return out
}

// ---------------------------------------------------------------------------
// 进程内缓存（mtime 失效）
//
// 上游把索引写进 /tmp/luci-indexcache；molly 明确不写那个文件（免得与真 LuCI 的
// 缓存格式打架）。这里退化成进程内缓存：目录里 *.json 的「个数 + 最新修改时间」
// 一变就整棵重建。树不含会话状态，所以可以跨请求共享。
// ---------------------------------------------------------------------------

var (
	cacheMu     sync.Mutex
	cacheDir    string
	cacheCount  int
	cacheNewest int64
	cacheTree   *Node
	cacheInited bool
)

// LoadTree 读目录 → 必要时重建树，返回树的根。
// ok == false 表示菜单目录读不到（不存在 / 无权限），调用方应当把 /cgi-bin/luci 全部当 404。
// 失败不进缓存：下次请求会重新尝试。
//
// deps 只用于建树时求值 depends（Odin 版由包级 backend 单例提供，Go 侧显式传入）。
// 进程内只有一个 backend 实例，所以缓存键不含 deps。
func LoadTree(dir string, deps Deps) (tree *Node, ok bool) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		fmt.Fprintln(os.Stderr, "[molly] 读不到菜单目录:", dir, "-", err)
		return EmptyTree(), false
	}

	count := 0
	var newest int64
	var names []string
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".json") {
			continue
		}
		count++
		if info, err := e.Info(); err == nil {
			if t := info.ModTime().UnixNano(); t > newest {
				newest = t
			}
		}
		names = append(names, e.Name())
	}
	// 文件名排序：同一路径被多个文件定义时「谁最后生效」必须是确定的。
	sort.Strings(names)

	cacheMu.Lock()
	defer cacheMu.Unlock()
	if cacheInited && cacheDir == dir && cacheCount == count && cacheNewest == newest {
		return cacheTree, true
	}
	cacheDir = dir
	cacheCount = count
	cacheNewest = newest
	cacheTree = buildTree(dir, names, deps)
	cacheInited = true
	return cacheTree, true
}

// EmptyTree 是目录不可读时的兜底：只有 root，且没有子节点 → 所有 /cgi-bin/luci/* 都是 404。
func EmptyTree() *Node {
	return &Node{ActionType: "firstchild", Satisfied: true, Children: map[string]*Node{}}
}

// ---------------------------------------------------------------------------
// 建树
// ---------------------------------------------------------------------------

func buildTree(dir string, names []string, deps Deps) *Node {
	root := EmptyTree()
	for _, name := range names {
		full := filepath.Join(dir, name)
		data, err := os.ReadFile(full)
		if err != nil {
			fmt.Fprintln(os.Stderr, "[molly] 读不到菜单文件:", full)
			continue
		}
		mergeMenuFile(root, data, deps)
	}
	return root
}

func mergeMenuFile(root *Node, data []byte, deps Deps) {
	obj, ok := decodeJSONObject(data)
	if !ok {
		fmt.Fprintln(os.Stderr, "[molly] 菜单文件 JSON 解析失败，整份跳过")
		return
	}
	// JSON 对象是 map，遍历顺序不确定；排一下让「同文件内多个 spec 落到同一节点」
	// 这种罕见情况也可复现。
	paths := make([]string, 0, len(obj))
	for path := range obj {
		paths = append(paths, path)
	}
	sort.Strings(paths)

	for _, path := range paths {
		spec, ok := obj[path].(map[string]any)
		if !ok {
			continue
		}
		applySpec(root, path, spec, deps)
	}
}

// applySpec：一条 menu.d 规格 → 树上的一个节点。逐键判定：
//   - schema 之外的键、类型不符的键 → 只忽略这个键，不丢弃整条规格；
//   - 只覆盖 spec 里出现的键，没出现的键保留前一份定义（同路径多文件时按文件名序）；
//   - 路径里有 '*' 段时 action 进 WildcardAction*，否则进 Action*。
func applySpec(root *Node, path string, spec map[string]any, deps Deps) {
	node, hitWildcard := descend(root, path)

	// 上游 :405 `if (node !== tree)`：落到根上的规格整条不生效
	if node == root {
		return
	}
	node.Wildcard = hitWildcard

	for key, val := range spec {
		switch key {
		case "action":
			obj, ok := val.(map[string]any)
			if !ok {
				continue
			}
			if hitWildcard {
				node.WildcardActionType = jsonStrField(obj, "type")
				node.WildcardActionPath = jsonStrField(obj, "path")
				node.HasWildcardAction = true
			} else {
				node.ActionType = jsonStrField(obj, "type")
				node.ActionPath = jsonStrField(obj, "path")
			}
		case "depends":
			if _, ok := val.(map[string]any); !ok {
				continue
			}
			text, err := marshalSorted(val)
			if err != nil {
				continue
			}
			node.DependsJSON = text
			node.HasDepends = true
		case "wildcard":
			b, ok := val.(bool)
			if !ok {
				continue
			}
			// 上游先按路径里的 '*' 把 wildcard 置 true（:395），随后 schema 拷贝
			// 可能用 spec.wildcard 覆盖它——顺序与之一致。
			node.Wildcard = b
		case "firstchild_ineligible":
			b, ok := val.(bool)
			if !ok {
				continue
			}
			node.FirstchildIneligible = b
		case "order":
			n, ok := jsonInt(val)
			if !ok {
				continue
			}
			node.Order = n
		case "title":
			s, ok := val.(string)
			if !ok {
				continue
			}
			node.Title = s
		case "auth":
			// 上下游 schema 只拷**类型匹配**的键：auth 不是对象就整键忽略；
			// 且缺 auth 的 spec 不清空前一份。
			obj, ok := val.(map[string]any)
			if !ok {
				continue
			}
			node.HasAuth = true
			node.AuthLogin = false
			if lv, has := obj["login"]; has {
				if lb, isBool := lv.(bool); isBool {
					node.AuthLogin = lb
				}
			}
		case "cors", "css", "setgroup", "setuser":
			// schema 里存在（css 是 molly 的扩展键），但树不用它们
			continue
		default:
			// schema 之外的键：忽略
			continue
		}
	}

	// depends.acl 与 satisfied 一样**后一份规格覆盖前一份**：没有 depends 就清空。
	node.ACLGroups = nil
	if dep, has := spec["depends"]; has {
		if depObj, ok := dep.(map[string]any); ok {
			if acl, hasACL := depObj["acl"]; hasACL {
				node.ACLGroups = parseACLGroups(acl)
			}
		}
	}

	// 上游 :416 无条件重算：没有 depends（或 depends 不是 object）时 checkDepends 返回 true。
	node.Satisfied = checkDepends(spec["depends"], deps)
}

// descend 按 '/' 切段下降，沿途缺节点就现建。
// 段首为 '*' 表示通配：停在这一层并把 wildcard 标在父节点上。
func descend(root *Node, path string) (node *Node, wildcard bool) {
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
		if i := strings.IndexByte(rest, '/'); i >= 0 {
			seg, rest = rest[:i], rest[i:]
		} else {
			rest = ""
		}
		if seg[0] == '*' {
			return node, true
		}
		if node.Children == nil {
			node.Children = map[string]*Node{}
		}
		child, has := node.Children[seg]
		if !has {
			child = &Node{Order: 9999, Satisfied: true}
			node.Children[seg] = child
		}
		node = child
	}
	return node, false
}

func jsonStrField(obj map[string]any, key string) string {
	val, has := obj[key]
	if !has {
		return ""
	}
	s, ok := val.(string)
	if !ok {
		return ""
	}
	return s
}

// ---------------------------------------------------------------------------
// depends 判定
//
// 复刻上游 check_depends 家族：
//   check_depends             :278-310  fs / uci 两组都成立才 satisfied
//   check_fs_depends          :171-196  条目 = {路径: 要求类型}，全部条目都要成立
//   check_uci_depends         :258-276  config → true / {section: options}
//   check_uci_depends_section :229-256  section 键可为具名或 '@type'（任一该类型的）
//   check_uci_depends_options :198-227  options 可为 string / true / {option: 值}
//
// 三处共同规则：
//   - 取值不是 array / object → 整项忽略（上游 for..in 拿不到东西 ⇒ 恒成立）；
//   - array = 任一备选成立；object = 单个备选（其内部条目全部成立）；
//   - 认不出的形态 → 忽略。
//
// depends.acl 不在 checkDepends 里：它留给 nodeVisible 每请求现算。
// ---------------------------------------------------------------------------

// parseACLGroups 取 depends.acl 的组名列表。上游 `for (let group in require_groups)`
// 取的是**键**，所以对象形态（`{ "luci-base": ["status"] }`，真机就有）与数组形态
// （`["luci-base"]`）都要认；裸字符串也收一格（宽松一档，上游只吃数组/对象）。
func parseACLGroups(val any) []string {
	switch v := val.(type) {
	case []any:
		out := make([]string, 0, len(v))
		for _, el := range v {
			if s, ok := el.(string); ok {
				out = append(out, s)
			}
		}
		return out
	case map[string]any:
		out := make([]string, 0, len(v))
		for name := range v {
			out = append(out, name)
		}
		sort.Strings(out)
		return out
	case string:
		return []string{v}
	}
	return nil
}

func checkDepends(depends any, deps Deps) bool {
	table, ok := depends.(map[string]any)
	if !ok {
		return true
	}
	if val, has := table["fs"]; has && !checkFSDepends(val) {
		return false
	}
	// 上游 :389 在满足时把 tree 的 uci 缓存重置；molly 不缓存 uci，无对应动作。
	if val, has := table["uci"]; has && !checkUCIDepends(val, deps) {
		return false
	}
	return true
}

// 备选形态：array → 任一备选成立；object → 单个备选；其它取值 → 整项忽略（返回 true）。
func checkFSDepends(val any) bool {
	switch v := val.(type) {
	case []any:
		for _, alt := range v {
			if fsEntrySatisfied(alt) {
				return true
			}
		}
		return false
	case map[string]any:
		return fsEntrySatisfied(val)
	}
	return true
}

func checkUCIDepends(val any, deps Deps) bool {
	switch v := val.(type) {
	case []any:
		for _, alt := range v {
			if uciEntrySatisfied(alt, deps) {
				return true
			}
		}
		return false
	case map[string]any:
		return uciEntrySatisfied(val, deps)
	}
	return true
}

// 一个 fs 备选：{路径: 要求类型}，每个条目都要成立。要求类型只有四种，认不出的一律忽略；
// 备选本身不是 object（真实样本 0 例，例如裸字符串）同样视为成立。
func fsEntrySatisfied(entry any) bool {
	obj, ok := entry.(map[string]any)
	if !ok {
		return true
	}
	for path, kindVal := range obj {
		kind, ok := kindVal.(string)
		if !ok {
			continue
		}
		switch kind {
		case "directory":
			// 上游：`if (!length(lsdir(path))) return false` —— 目录要存在且非空
			if !directoryNonEmpty(path) {
				return false
			}
		case "executable":
			// 上游：`stat().type == 'file' && user_exec`
			if !regularFile(path, true) {
				return false
			}
		case "file":
			if !regularFile(path, false) {
				return false
			}
		case "absent":
			// 上游：`if (stat(path) != null) return false`
			if _, err := os.Stat(path); err == nil {
				return false
			}
		default:
			// 未知要求类型：忽略这个条目
		}
	}
	return true
}

// 一个 uci 备选：{config: true | {section: options}}，每个 config 条目都要成立。
func uciEntrySatisfied(entry any, deps Deps) bool {
	obj, ok := entry.(map[string]any)
	if !ok {
		return true
	}
	for config, values := range obj {
		if b, isBool := values.(bool); isBool {
			// `true`：config 至少有 1 个 section
			if b && !configHasSection(config, deps) {
				return false
			}
			continue
		}
		if sect, isSect := values.(map[string]any); isSect {
			if !uciSectionsSatisfied(config, sect, deps) {
				return false
			}
		}
		// 其它取值（字符串 / 数字 / null）：上游两个分支都不进 → 忽略
	}
	return true
}

func configHasSection(config string, deps Deps) bool {
	if deps == nil {
		return false
	}
	sections, ok := deps.UciConfigSections(config)
	return ok && len(sections) > 0
}

// 一个 uci 备选里的 section 表：键是 `@<type>` 时「任一该类型 section 满足 options」即可，
// 否则必须存在同名 section。
func uciSectionsSatisfied(config string, sect map[string]any, deps Deps) bool {
	var sections []backend.UciSection
	if deps != nil {
		sections, _ = deps.UciConfigSections(config)
	}

	keys := make([]string, 0, len(sect))
	for k := range sect {
		keys = append(keys, k)
	}
	sort.Strings(keys)

	for _, key := range keys {
		options := sect[key]
		if typeName, isType := atSectionType(key); isType {
			found := false
			for i := range sections {
				if sections[i].TypeName != typeName {
					continue
				}
				if uciOptionsSatisfied(sections[i], options) {
					found = true
					break
				}
			}
			if !found {
				return false
			}
			continue
		}

		var target *backend.UciSection
		for i := range sections {
			if sections[i].Name == key {
				target = &sections[i]
				break
			}
		}
		if target == nil || !uciOptionsSatisfied(*target, options) {
			return false
		}
	}
	return true
}

// atSectionType 判定 `@<type>` 形态（上游 :231 的 `/^@([A-Za-z0-9_-]+)$/`）。
func atSectionType(key string) (string, bool) {
	if len(key) < 2 || key[0] != '@' {
		return "", false
	}
	for i := 1; i < len(key); i++ {
		c := key[i]
		switch {
		case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z', c >= '0' && c <= '9', c == '_', c == '-':
		default:
			return "", false
		}
	}
	return key[1:], true
}

// section 的 options 判定（上游 :198-227）。
func uciOptionsSatisfied(s backend.UciSection, opts any) bool {
	// options 为字符串 → 比对 section 的 .type
	if want, ok := opts.(string); ok {
		return s.TypeName == want
	}
	// options 为 true → section 至少有一个 option
	if b, ok := opts.(bool); ok {
		return b && len(s.Options) > 0
	}

	obj, ok := opts.(map[string]any)
	if !ok {
		return true
	}

	names := make([]string, 0, len(obj))
	for name := range obj {
		names = append(names, name)
	}
	sort.Strings(names)

	for _, name := range names {
		want := obj[name]
		got, has := uciOptionByName(s, name)
		isArray := has && got.IsList

		if isArray {
			// 上游：`if (!(value in sval)) return false`
			if !valueIn(got.Values, want) {
				return false
			}
			continue
		}
		if b, isBool := want.(bool); isBool && b {
			// 上游：`value === true` → 只要 sval != null
			if !has {
				return false
			}
			continue
		}
		// 上游：`sval != value`
		if !has || len(got.Values) == 0 {
			return false
		}
		wantStr, comparable := jsonScalar(want)
		if !comparable || got.Values[0] != wantStr {
			return false
		}
	}
	return true
}

func uciOptionByName(s backend.UciSection, name string) (backend.UciOption, bool) {
	for _, o := range s.Options {
		if o.Name == name {
			return o, true
		}
	}
	return backend.UciOption{}, false
}

func valueIn(values []string, want any) bool {
	wantStr, comparable := jsonScalar(want)
	if !comparable {
		return false
	}
	for _, v := range values {
		if v == wantStr {
			return true
		}
	}
	return false
}

// jsonScalar：JSON 标量 → 可与 uci option 字符串比较的文本。object / array / null 没法比较。
func jsonScalar(v any) (string, bool) {
	switch x := v.(type) {
	case string:
		return x, true
	case bool:
		if x {
			return "true", true
		}
		return "false", true
	case json.Number:
		return x.String(), true
	}
	return "", false
}

// regularFile 对齐上游 :171-196 的 stat()：跟随符号链接。
func regularFile(path string, requireExec bool) bool {
	info, err := os.Stat(path)
	if err != nil || !info.Mode().IsRegular() {
		return false
	}
	if requireExec && info.Mode().Perm()&0o100 == 0 {
		return false
	}
	return true
}

// directoryNonEmpty 对齐上游的 `length(lsdir(path))`：目录存在且**非空**。
func directoryNonEmpty(path string) bool {
	entries, err := os.ReadDir(path)
	if err != nil {
		return false
	}
	return len(entries) > 0
}

// ---------------------------------------------------------------------------
// 路径解析
// ---------------------------------------------------------------------------

// nodeVisible：节点在本会话下是否可见。depends（fs/uci）成立，且 depends.acl 要求的组
// 没有缺的。login = 无会话时的 login 放行模式：只豁免 acl 缺组那半，satisfied 照旧要过。
func nodeVisible(n *Node, sid string, login bool, deps Deps) bool {
	if !n.Satisfied {
		return false
	}
	if login {
		return true
	}
	return !nodeACLMissing(n, sid, deps)
}

// nodeACLMissing：depends.acl 缺失（上游 check_acl_depends 返回 null）→ 本会话看不到该节点。
// 没有 acl 要求的节点恒为可见（SessionACLLevel 对空列表回 ACLWritable）。
func nodeACLMissing(n *Node, sid string, deps Deps) bool {
	if len(n.ACLGroups) == 0 {
		return false
	}
	if deps == nil {
		return true
	}
	return deps.SessionACLLevel(sid, n.ACLGroups) == backend.ACLMissing
}

// Resolve 对齐上游 resolve_page（dispatcher.uc:503-553）：逐段下降；子节点不存在或
// !visible 就停在上一层并报未命中。唯一的例外是「当前节点是通配层且下一段没有可用的
// 实子节点」——这时把剩下的段全部当参数收下，算作命中。
func Resolve(tree *Node, path, sid string, deps Deps) Resolved {
	segs := splitSegments(path)
	node := tree
	var groups []string
	auth := authAbsorb(AuthState{}, tree)

	for i := 0; i < len(segs); i++ {
		next, has := childOf(node, segs[i])
		if node.Wildcard && (!has || !nodeVisible(next, sid, false, deps)) {
			return Resolved{Node: node, Args: segs[i:], Found: true, ACLGroups: groups, Auth: auth}
		}
		if !has || !nodeVisible(next, sid, false, deps) {
			// 下降失败也把沿途的 auth 带回去：无会话时「被 ACL 截断」正是要判 403 + 登录提示
			// 的那种形态。
			return Resolved{Node: node, ACLGroups: groups, Auth: auth}
		}
		groups = append(groups, next.ACLGroups...)
		auth = authAbsorb(auth, next)
		node = next
	}
	return Resolved{Node: node, Found: true, ACLGroups: groups, Auth: auth}
}

// Action 是 effectiveAction 的结果。
type Action struct {
	Type string
	Path string
}

// effectiveAction 对齐上游 :1006-1011：先用 node.action；**有剩余段**且存在
// wildcardaction 时改用它。
func effectiveAction(node *Node, args []string) Action {
	if len(args) > 0 && node.HasWildcardAction {
		return Action{Type: node.WildcardActionType, Path: node.WildcardActionPath}
	}
	return Action{Type: node.ActionType, Path: node.ActionPath}
}

// FirstChild 对齐上游 resolve_firstchild（dispatcher.uc:582-624）：在所有 satisfied、
// 有 title、action 是对象的子节点里挑权重最小的一个。子节点自己也是 firstchild 时
// 递归下降，且它必须有可当选的后代才有资格当选。
//
// 权重相同（menu.d 里 order 相等很常见）时按段名字典序取小——上游吃的是 ucode 对象的
// 插入序，这里换成显式规则，保证多次运行结果一致。
//
// groups / auth 是「当选支路」要并回 ctx 的东西：在候选自己的副本上累积，赢了才写回。
func FirstChild(node *Node, sid string, groups *[]string, auth *AuthState, loginAllowed bool, deps Deps) *Node {
	if node.Children == nil {
		return nil
	}
	var best *Node
	bestWeight := 0
	bestName := ""
	var bestGroups []string

	baseAuth := AuthState{}
	if auth != nil {
		baseAuth = *auth
	}
	bestAuth := baseAuth

	names := make([]string, 0, len(node.Children))
	for name := range node.Children {
		names = append(names, name)
	}
	sort.Strings(names)

	for _, name := range names {
		child := node.Children[name]
		// 无会话时的 login 放行模式（上游 :593）——命中就让 ACL 缺组的节点也进竞选，
		// 否则无会话用户在真实 menu.d 上只会看到一片 404（上游是要把他导到登录页的）。
		childLogin := len(sid) == 0 && (loginAllowed || child.AuthLogin)
		// 另外三个条件对应上游 :586（satisfied）、:596（有 title 且 action 是对象）、
		// :607（firstchild_ineligible 不参与竞选）
		if len(child.Title) == 0 ||
			child.FirstchildIneligible ||
			!nodeVisible(child, sid, childLogin, deps) {
			continue
		}

		// 这条支路自己的 depends.acl 与 auth 也要算进 ctx：只有**当选**的那条才并回去。
		candGroups := append([]string{}, child.ACLGroups...)
		candAuth := authAbsorb(baseAuth, child)

		candidate := child
		if child.ActionType == "firstchild" {
			candidate = FirstChild(child, sid, &candGroups, &candAuth, childLogin, deps)
			if candidate == nil {
				continue // 没有可当选的后代 → 本节点不能当选
			}
		} else if len(child.ActionType) == 0 {
			continue // action 不是对象
		}

		w := nodeWeight(child)
		if best == nil || w < bestWeight || (w == bestWeight && name < bestName) {
			best, bestWeight, bestName = candidate, w, name
			bestGroups = candGroups
			bestAuth = candAuth
		}
	}

	if best != nil {
		if groups != nil {
			*groups = append(*groups, bestGroups...)
		}
		if auth != nil {
			*auth = bestAuth
		}
	}
	return best
}

// nodeWeight 对齐上游 node_weight：order 夹到 9999；auth/login 再加 10000 压到菜单末尾。
func nodeWeight(n *Node) int {
	w := n.Order
	if w > 9999 {
		w = 9999
	}
	if n.ActionPath == "auth/login" || n.ActionPath == "auth.login" {
		w += 10000
	}
	return w
}

func childOf(n *Node, seg string) (*Node, bool) {
	if n.Children == nil {
		return nil, false
	}
	c, has := n.Children[seg]
	return c, has
}

// splitSegments："/admin/status/overview" → {"admin","status","overview"}；空串 → 空切片。
// 输入已过 httpx.NormalizePath，所以这里不需要再处理 "." 与 ".."。
func splitSegments(path string) []string {
	var out []string
	rest := path
	for {
		for len(rest) > 0 && rest[0] == '/' {
			rest = rest[1:]
		}
		if len(rest) == 0 {
			break
		}
		if i := strings.IndexByte(rest, '/'); i >= 0 {
			out = append(out, rest[:i])
			rest = rest[i:]
		} else {
			out = append(out, rest)
			rest = ""
		}
	}
	return out
}

// ---------------------------------------------------------------------------
// JSON 小工具
// ---------------------------------------------------------------------------

// decodeJSONObject 用 UseNumber 解码：order 只接受整数形态（与上游 json.Integer
// 一致，`"5"` 与 `5.0` 都被忽略）。
func decodeJSONObject(data []byte) (map[string]any, bool) {
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.UseNumber()
	var v any
	if err := dec.Decode(&v); err != nil {
		return nil, false
	}
	obj, ok := v.(map[string]any)
	return obj, ok
}

func jsonInt(v any) (int, bool) {
	n, ok := v.(json.Number)
	if !ok {
		return 0, false
	}
	i, err := n.Int64()
	if err != nil {
		return 0, false
	}
	return int(i), true
}

// marshalSorted：Go 的 json.Marshal 对 map 按键排序，等价于上游的 sort_maps_by_key。
func marshalSorted(v any) (string, error) {
	b, err := json.Marshal(v)
	if err != nil {
		return "", err
	}
	return string(b), nil
}
