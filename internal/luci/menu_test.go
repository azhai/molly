package luci

import (
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"

	"github.com/azhai/molly/internal/backend"
)

// fakeDeps 是 Deps 的测试替身：uci 数据与 ACL 档位都由用例直接给。
type fakeDeps struct {
	sections map[string][]backend.UciSection
	// level 是对任何非空 groups 的回答；sid 为空（无会话）恒回 Missing。
	level backend.ACLLevel
}

func (f fakeDeps) UciConfigSections(config string) ([]backend.UciSection, bool) {
	s, ok := f.sections[config]
	return s, ok
}

func (f fakeDeps) SessionACLLevel(sid string, groups []string) backend.ACLLevel {
	if len(groups) == 0 {
		return backend.ACLWritable
	}
	if sid == "" {
		return backend.ACLMissing
	}
	return f.level
}

// netDeps 是 fixture 的 depends.uci 需要的假配置（对齐 Odin darwin.odin 的 FAKE_UCI）。
func netDeps(level backend.ACLLevel) fakeDeps {
	return fakeDeps{
		sections: map[string][]backend.UciSection{
			"network": {
				{Name: "lan", TypeName: "interface", Options: []backend.UciOption{
					{Name: "proto", Values: []string{"static"}},
				}},
				{Name: "", TypeName: "switch", Anonymous: true, Options: []backend.UciOption{
					{Name: "name", Values: []string{"switch0"}},
				}},
			},
			"empty-config": {},
		},
		level: level,
	}
}

// treeFromJSON：把若干段 menu.d JSON 依次并入一棵空树（等价于按文件名序合并）。
func treeFromJSON(t *testing.T, deps Deps, docs ...string) *Node {
	t.Helper()
	root := EmptyTree()
	for _, doc := range docs {
		mergeMenuFile(root, []byte(doc), deps)
	}
	return root
}

// fixtureTree：用仓库里的真实 menu.d fixture 建树（luci-base.json 先于 luci-probe.json）。
func fixtureTree(t *testing.T, deps Deps) *Node {
	t.Helper()
	dir := filepath.Join("..", "..", "tests", "fixtures", "menu.d")
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatalf("读 fixture 目录 %s: %v", dir, err)
	}
	var names []string
	for _, e := range entries {
		if !e.IsDir() && filepath.Ext(e.Name()) == ".json" {
			names = append(names, e.Name())
		}
	}
	sort.Strings(names)
	return buildTree(dir, names, deps)
}

func kindName(k Kind) string {
	switch k {
	case KindPage:
		return "page"
	case KindNotFound:
		return "notfound"
	case KindNotImplemented:
		return "notimpl"
	case KindLoginRequired:
		return "login"
	}
	return "?"
}

// ---------------------------------------------------------------------------
// 建树：schema 白名单 / 逐键合并 / 通配 action
// ---------------------------------------------------------------------------

func TestApplySpecKeepsValidKeysAndIgnoresBadOnes(t *testing.T) {
	tree := treeFromJSON(t, netDeps(backend.ACLWritable), `{
		"badfield": {"title": "Bad field kept", "order": "250", "nonsense": true,
		             "action": {"type": "view", "path": "bad"}}
	}`)
	n, ok := childOf(tree, "badfield")
	if !ok {
		t.Fatal("badfield 节点没建出来")
	}
	if n.Title != "Bad field kept" {
		t.Errorf("title = %q", n.Title)
	}
	if n.Order != 9999 {
		t.Errorf("order 应当被忽略回默认 9999，实际 %d", n.Order)
	}
	if n.ActionPath != "bad" {
		t.Errorf("action.path = %q", n.ActionPath)
	}
}

func TestSamePathMergesKeyByKey(t *testing.T) {
	tree := treeFromJSON(t, netDeps(backend.ACLWritable),
		`{"admin/system/reboot": {"title": "Reboot", "order": 10,
		   "action": {"type": "cbi", "path": "system/reboot"}}}`,
		`{"admin/system/reboot": {"action": {"type": "view", "path": "system/reboot"}}}`)
	n, _ := nodeAt(t, tree, "admin", "system", "reboot")
	if n == nil {
		t.Fatal("节点没建出来")
	}
	// 只覆盖 spec 里出现的键：title/order 保留前一份，action 用后一份
	if n.Title != "Reboot" || n.Order != 10 {
		t.Errorf("未出现的键没保留：title=%q order=%d", n.Title, n.Order)
	}
	if n.ActionType != "view" {
		t.Errorf("action.type = %q，期望 view", n.ActionType)
	}
}

func TestWildcardActionStoredSeparately(t *testing.T) {
	tree := treeFromJSON(t, netDeps(backend.ACLWritable),
		`{"admin/status/logs": {"title": "Logs", "order": 50,
		   "action": {"type": "view", "path": "status/logs-base"}}}`,
		`{"admin/status/logs/*": {"title": "Logs (wildcard)", "order": 50,
		   "action": {"type": "view", "path": "status/logs-arg"}}}`)
	n, _ := nodeAt(t, tree, "admin", "status", "logs")
	if n == nil {
		t.Fatal("节点没建出来")
	}
	if !n.Wildcard {
		t.Error("节点没被标成通配层")
	}
	if n.ActionPath != "status/logs-base" {
		t.Errorf("base action 被覆盖了：%q", n.ActionPath)
	}
	if !n.HasWildcardAction || n.WildcardActionPath != "status/logs-arg" {
		t.Errorf("wildcardaction 缺失：%+v", n)
	}
}

// ---------------------------------------------------------------------------
// depends：fs / uci 各形态
// ---------------------------------------------------------------------------

func TestDependsFSForms(t *testing.T) {
	deps := netDeps(backend.ACLWritable)
	tree := treeFromJSON(t, deps, `{
		"present":   {"title":"p","action":{"type":"view","path":"p"},
		              "depends":{"fs":{"/etc/hosts":"file"}}},
		"hidden":    {"title":"h","action":{"type":"view","path":"h"},
		              "depends":{"fs":{"/nonexistent-molly-menu-probe":"file"}}},
		"fsabsent":  {"title":"a","action":{"type":"view","path":"a"},
		              "depends":{"fs":{"/nonexistent-molly-menu-probe":"absent"}}},
		"fsand":     {"title":"and","action":{"type":"view","path":"and"},
		              "depends":{"fs":{"/etc/hosts":"file","/nonexistent-molly-menu-probe":"file"}}},
		"fsarray":   {"title":"arr","action":{"type":"view","path":"arr"},
		              "depends":{"fs":[{"/nonexistent-molly-menu-probe":"file"},{"/etc/hosts":"file"}]}},
		"fsdir":     {"title":"dir","action":{"type":"view","path":"dir"},
		              "depends":{"fs":{"/etc":"directory"}}},
		"fskind":    {"title":"kind","action":{"type":"view","path":"kind"},
		              "depends":{"fs":{"/etc/hosts":"directory"}}},
		"fsexec":    {"title":"exe","action":{"type":"view","path":"exe"},
		              "depends":{"fs":{"/bin/sh":"executable"}}},
		"fsexecmiss":{"title":"nomiss","action":{"type":"view","path":"nomiss"},
		              "depends":{"fs":{"/etc/hosts":"executable"}}},
		"fsstrform": {"title":"str","action":{"type":"view","path":"str"},
		              "depends":{"fs":["/etc/hosts"]}}
	}`)
	want := map[string]bool{
		"present": true, "hidden": false, "fsabsent": true, "fsand": false,
		"fsarray": true, "fsdir": true, "fskind": false, "fsexec": true,
		"fsexecmiss": false, "fsstrform": true,
	}
	for name, wantSatisfied := range want {
		n, ok := childOf(tree, name)
		if !ok {
			t.Fatalf("%s 节点没建出来", name)
		}
		if n.Satisfied != wantSatisfied {
			t.Errorf("%s satisfied = %v，期望 %v", name, n.Satisfied, wantSatisfied)
		}
	}
}

func TestDependsUCIForms(t *testing.T) {
	deps := netDeps(backend.ACLWritable)
	tree := treeFromJSON(t, deps, `{
		"ucipage":     {"title":"a","action":{"type":"view","path":"a"},
		                "depends":{"uci":{"network":{"lan":true}}}},
		"ucimissing":  {"title":"b","action":{"type":"view","path":"b"},
		                "depends":{"uci":{"network":{"nope":true}}}},
		"ucitrue":     {"title":"c","action":{"type":"view","path":"c"},
		                "depends":{"uci":{"network":true}}},
		"uciemptycfg": {"title":"d","action":{"type":"view","path":"d"},
		                "depends":{"uci":{"empty-config":true}}},
		"ucicfgmiss":  {"title":"e","action":{"type":"view","path":"e"},
		                "depends":{"uci":{"no-such-config":true}}},
		"uciaftype":   {"title":"f","action":{"type":"view","path":"f"},
		                "depends":{"uci":{"network":{"@switch":true}}}},
		"uciopt":      {"title":"g","action":{"type":"view","path":"g"},
		                "depends":{"uci":{"network":{"lan":{"proto":"static"}}}}},
		"ucioptmiss":  {"title":"h","action":{"type":"view","path":"h"},
		                "depends":{"uci":{"network":{"lan":{"proto":"dhcp"}}}}},
		"uciand":      {"title":"i","action":{"type":"view","path":"i"},
		                "depends":{"uci":{"network":true,"no-such-config":true}}},
		"ucistrform":  {"title":"j","action":{"type":"view","path":"j"},
		                "depends":{"uci":["network.lan"]}}
	}`)
	want := map[string]bool{
		"ucipage": true, "ucimissing": false, "ucitrue": true,
		"uciemptycfg": false, "ucicfgmiss": false, "uciaftype": true,
		"uciopt": true, "ucioptmiss": false, "uciand": false, "ucistrform": true,
	}
	for name, wantSatisfied := range want {
		n, ok := childOf(tree, name)
		if !ok {
			t.Fatalf("%s 节点没建出来", name)
		}
		if n.Satisfied != wantSatisfied {
			t.Errorf("%s satisfied = %v，期望 %v", name, n.Satisfied, wantSatisfied)
		}
	}
}

// ---------------------------------------------------------------------------
// resolve / dispatch（用真实 fixture）
// ---------------------------------------------------------------------------

func TestDispatchFixture(t *testing.T) {
	tree := fixtureTree(t, netDeps(backend.ACLWritable))
	sid := "sess-ok" // 有会话、有 write

	cases := []struct {
		name     string
		path     string
		sid      string
		wantKind Kind
		wantIn   string // body 里必须出现的子串（空 = 不检查）
	}{
		{"裸前缀走 root firstchild", "", sid, KindPage, "<h1>Overview</h1>"},
		{"指定路径命中", "/admin/status/overview", sid, KindPage, "<h1>Overview</h1>"},
		{"/admin/status 走 firstchild", "/admin/status", sid, KindPage, "<h1>Overview</h1>"},
		{"/admin/system 走 firstchild", "/admin/system", sid, KindPage, "<h1>Reboot</h1>"},
		{"cbi → 501", "/admin/status/routes", sid, KindNotImplemented,
			"not implemented: action.type=cbi view=status/routes menu=/admin/status/routes"},
		{"通配段收下剩余段", "/admin/status/logs/syslog", sid, KindPage, "status/logs-arg"},
		{"通配节点无剩余段用 base action", "/admin/status/logs", sid, KindPage, "status/logs-base"},
		{"depends.fs 命中", "/present", "", KindPage, "<h1>Present via depends.fs</h1>"},
		{"depends.fs 未命中", "/hidden", "", KindNotFound, ""},
		{"depends.uci 命中", "/ucipage", "", KindPage, ""},
		{"depends.uci 未命中", "/ucimissing", "", KindNotFound, ""},
		{"未命中路径", "/nope", sid, KindNotFound, ""},
		{"无会话落在 auth.login 子树", "/admin/status/overview", "", KindLoginRequired,
			"<h1>Login required</h1>"},
		{"无会话未知路径也先判登录", "/admin/nope", "", KindLoginRequired, ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			page := Dispatch(tree, c.path, c.sid, netDeps(backend.ACLWritable))
			if page.Kind != c.wantKind {
				t.Fatalf("kind = %s，期望 %s（body=%q）", kindName(page.Kind), kindName(c.wantKind), page.Body)
			}
			if c.wantIn != "" && !contains(page.Body, c.wantIn) {
				t.Errorf("body 缺 %q：%q", c.wantIn, page.Body)
			}
		})
	}
}

func TestDispatchACLThreeStates(t *testing.T) {
	tree := fixtureTree(t, fakeDeps{level: backend.ACLReadOnly})

	// 无会话：路径上有 auth.login → 403 登录提示，不是 404
	page := Dispatch(tree, "/admin/status/overview", "", fakeDeps{level: backend.ACLReadOnly})
	if page.Kind != KindLoginRequired {
		t.Fatalf("无会话应当要登录，实际 %s", kindName(page.Kind))
	}
	if !contains(page.Body, "<dt>path</dt><dd>/admin/status/overview</dd>") {
		t.Errorf("登录提示页没列出请求路径：%q", page.Body)
	}

	// 有会话但缺组（哨兵会话对 luci-base 无权限）→ 404
	sentinel := fakeDeps{level: backend.ACLMissing}
	page = Dispatch(tree, "/admin/status/overview", "00000000000000000000000000000000", sentinel)
	if page.Kind != KindNotFound {
		t.Fatalf("缺组会话应当 404，实际 %s", kindName(page.Kind))
	}
	// firstchild 要跳过被裁掉的 overview，落到 logs（title 被 probe 覆盖）
	page = Dispatch(tree, "/admin/status", "00000000000000000000000000000000", sentinel)
	if page.Kind != KindPage || !contains(page.Body, "<h1>Logs (wildcard)</h1>") {
		t.Fatalf("firstchild 没跳过门控节点：%s %q", kindName(page.Kind), page.Body)
	}

	// 只读会话：可见但标 readonly
	ro := fakeDeps{level: backend.ACLReadOnly}
	page = Dispatch(tree, "/admin/status/overview", "sess-ro", ro)
	if page.Kind != KindPage {
		t.Fatalf("只读会话应当可见，实际 %s", kindName(page.Kind))
	}
	if !contains(page.Body, "<dt>readonly</dt><dd>yes</dd>") {
		t.Errorf("只读会话没标 readonly：%q", page.Body)
	}
	// 有 write 就不是只读
	page = Dispatch(tree, "/admin/status/overview", "sess-ok", fakeDeps{level: backend.ACLWritable})
	if !contains(page.Body, "<dt>readonly</dt><dd>no</dd>") {
		t.Errorf("有 write 的会话被判成只读了：%q", page.Body)
	}
}

func TestRequestArgsEscaped(t *testing.T) {
	tree := treeFromJSON(t, netDeps(backend.ACLWritable), `{
		"logs/*": {"title":"L","action":{"type":"view","path":"logs-arg"}}
	}`)
	page := Dispatch(tree, "/logs/a<b>&c", "sid", netDeps(backend.ACLWritable))
	if page.Kind != KindPage {
		t.Fatalf("kind = %s", kindName(page.Kind))
	}
	if !contains(page.Body, "a&lt;b&gt;&amp;c") {
		t.Errorf("request_args 没被转义（信任边界）：%q", page.Body)
	}
}

// ---------------------------------------------------------------------------
// 小工具
// ---------------------------------------------------------------------------

func nodeAt(t *testing.T, n *Node, segs ...string) (*Node, bool) {
	t.Helper()
	cur := n
	for _, s := range segs {
		next, ok := cur.Children[s]
		if !ok {
			return nil, false
		}
		cur = next
	}
	return cur, true
}

func contains(haystack, needle string) bool {
	return strings.Contains(haystack, needle)
}
