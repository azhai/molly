//go:build darwin

package backend

// uci 对象的单元测试（对齐 Odin 版 src/backend/uci_object_test.odin 与 uci_write_test.odin
// 里 darwin 上可断言的部分）。
//
// 用例跑在 darwin 的假 config 上（uciProviderSections / uciProviderConfigs 就是 fakeUCI），
// 所以断言里的 network/system/lan/wan/wg0 都来自那份假数据。真实 libuci 的行为只有设备上
// 能验（见 docs/testing.md 的覆盖边界）。

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

// uciTestGet 从回复 JSON 里按路径取值并转成可比较的文本：
//
//	字符串原样；整数十进制；bool "true"/"false"；数组用逗号连接元素（非字符串元素跳过）
//
// 取不到时给一个显眼的哨兵，避免把「缺字段」误判成「空字符串」。
func uciTestGet(reply string, path ...string) string {
	var doc any
	if err := json.Unmarshal([]byte(reply), &doc); err != nil {
		return "<parse error>"
	}

	cur := doc
	for _, key := range path {
		obj, isObj := cur.(map[string]any)
		if !isObj {
			return "<not object>"
		}
		v, found := obj[key]
		if !found {
			return "<missing>"
		}
		cur = v
	}

	switch x := cur.(type) {
	case string:
		return x
	case bool:
		if x {
			return "true"
		}
		return "false"
	case float64:
		return strconv.FormatInt(int64(x), 10)
	case []any:
		parts := make([]string, 0, len(x))
		for _, e := range x {
			if s, isStr := e.(string); isStr {
				parts = append(parts, s)
			}
		}
		return strings.Join(parts, ",")
	}
	return "<other>"
}

// uciTestExpect 按 '/' 分隔的路径断言取值。分隔符用 '/'：`.name` 这类特殊键**以 '.' 开头**，
// 用 '.' 分会切出空段。匿名 section 的键是空串，写法就是路径里的前导 '/'（例：`/.anonymous`）。
func uciTestExpect(t *testing.T, reply, pathStr, want string) {
	t.Helper()
	got := uciTestGet(reply, strings.Split(pathStr, "/")...)
	if got != want {
		t.Errorf("取 %q 期望 %q，实际 %q", pathStr, want, got)
	}
}

// uciMatchFromJSON 把 match 表文本解析成 map（供 uciMatchSection 使用）。
func uciMatchFromJSON(t *testing.T, text string) map[string]json.RawMessage {
	t.Helper()
	var m map[string]json.RawMessage
	if err := json.Unmarshal([]byte(text), &m); err != nil {
		t.Fatalf("解析 match %q 失败: %v", text, err)
	}
	return m
}

func TestUCIVerify(t *testing.T) {
	cases := []struct {
		kind string // name | type | section
		text string
		want bool
	}{
		{"name", "lan", true},
		{"name", "lan_2", true},
		{"name", "_x", true},
		{"name", "", false},
		{"name", "lan-x", false}, // section 名不允许 '-'
		{"name", "a b", false},
		{"name", "lan[0]", false}, // 不以 '@' 开头 → 不按扩展形式解析
		{"type", "interface", true},
		{"type", "wifi-iface", true}, // 类型名允许 '-'
		{"type", "wifi-iface[0]", false},
		{"section", "lan", true},
		{"section", "@interface[0]", true},
		{"section", "@interface[12]", true},
		{"section", "@interface[]", false},
		{"section", "@interface[-1]", false},
		{"section", "@interface[0]x", false},
		{"section", "@[0]", true}, // C 只要求「至少一位数字 + ']' 收尾」，类型名可以为空
	}

	for _, c := range cases {
		var got bool
		switch c.kind {
		case "name":
			got = uciVerifyName(c.text)
		case "type":
			got = uciVerifyType(c.text)
		default:
			got = uciVerifySection(c.text)
		}
		if got != c.want {
			t.Errorf("verify_%s(%q) = %v，期望 %v", c.kind, c.text, got, c.want)
		}
	}
}

func TestUCIMatchOption(t *testing.T) {
	plain := UciOption{Name: "proto", Values: []string{"static"}}
	listed := UciOption{Name: "dns", IsList: true, Values: []string{"1.1.1.1", "8.8.8.8"}}
	multi := UciOption{Name: "ifname", Values: []string{"eth0  eth1\teth2"}}

	if !uciMatchOption(plain, "static") {
		t.Error("标量 static 应命中")
	}
	if uciMatchOption(plain, "dhcp") {
		t.Error("标量 dhcp 不应命中")
	}
	if !uciMatchOption(listed, "8.8.8.8") {
		t.Error("list 元素应命中")
	}
	if uciMatchOption(listed, "8.8") {
		t.Error("list 不做前缀匹配")
	}
	// 字符串型按空格/制表符切词（C 用 strtok(s, " \t")），整串不参与比较
	if !uciMatchOption(multi, "eth0") || !uciMatchOption(multi, "eth2") {
		t.Error("切词后的单词应命中")
	}
	if uciMatchOption(multi, "eth0 eth1") {
		t.Error("整串不应命中")
	}
}

func TestUCIMatchSection(t *testing.T) {
	sec := UciSection{
		Name:     "lan",
		TypeName: "interface",
		Options: []UciOption{
			{Name: "proto", Values: []string{"static"}},
			{Name: "ifname", Values: []string{"br-lan"}},
		},
	}

	// 空 match / 缺 match → 匹配
	if !uciMatchSection(sec, "", nil) {
		t.Error("nil match 应匹配")
	}
	if !uciMatchSection(sec, "", uciMatchFromJSON(t, `{}`)) {
		t.Error("空 match 应匹配")
	}
	// type 给了就必须相等
	if !uciMatchSection(sec, "interface", nil) {
		t.Error("type 相等应匹配")
	}
	if uciMatchSection(sec, "wifi-iface", nil) {
		t.Error("type 不等不应匹配")
	}

	if !uciMatchSection(sec, "", uciMatchFromJSON(t, `{"proto":"static"}`)) {
		t.Error("proto=static 应匹配")
	}
	if uciMatchSection(sec, "", uciMatchFromJSON(t, `{"proto":"dhcp"}`)) {
		t.Error("proto=dhcp 不应匹配")
	}
	// 键在 section 里不存在 → 不贡献命中，最终 false（C 的 empty||match）
	if uciMatchSection(sec, "", uciMatchFromJSON(t, `{"nope":"x"}`)) {
		t.Error("缺席键不应匹配")
	}
	// 一个键命中就够：缺席的键不否决（C 的 empty||match：proto 命中 → true）
	if !uciMatchSection(sec, "", uciMatchFromJSON(t, `{"proto":"static","nope":"x"}`)) {
		t.Error("一命中一缺席应匹配")
	}
	// 多个键都要命中
	if !uciMatchSection(sec, "", uciMatchFromJSON(t, `{"proto":"static","ifname":"br-lan"}`)) {
		t.Error("两键都命中应匹配")
	}
	if uciMatchSection(sec, "", uciMatchFromJSON(t, `{"proto":"static","ifname":"eth0"}`)) {
		t.Error("有一键不命中就不应匹配")
	}
	// 数字按十进制文本比较；浮点在 C 的 switch 里没有分支 → 整个键被跳过 → empty → true
	if uciMatchSection(sec, "", uciMatchFromJSON(t, `{"proto":1}`)) {
		t.Error("数字 1 与 static 不等，不应匹配")
	}
	if !uciMatchSection(sec, "", uciMatchFromJSON(t, `{"proto":1.5}`)) {
		t.Error("浮点被跳过 → empty → 应匹配")
	}
}

func TestUCIDumpShapes(t *testing.T) {
	sec := UciSection{
		Name:     "lan",
		TypeName: "interface",
		Options: []UciOption{
			{Name: "proto", Values: []string{"static"}},
			{Name: "dns", IsList: true, Values: []string{"1.1.1.1", "8.8.8.8"}},
		},
	}

	// section 级：三个特殊键 + 选项；**没有** .index
	one := marshalNoEscape(uciDumpSectionJSON(sec, -1))
	uciTestExpect(t, one, ".name", "lan")
	uciTestExpect(t, one, ".type", "interface")
	uciTestExpect(t, one, ".anonymous", "false")
	uciTestExpect(t, one, "proto", "static")
	uciTestExpect(t, one, "dns", "1.1.1.1,8.8.8.8")
	uciTestExpect(t, one, ".index", "<missing>")

	// package 级：带 .index（序号是整份配置里的位置，筛掉的 section 也占号）
	pkg := marshalNoEscape(uciDumpPackageJSON([]UciSection{sec}, "", nil))
	uciTestExpect(t, pkg, "lan/.index", "0")
	uciTestExpect(t, pkg, "lan/.name", "lan")
	uciTestExpect(t, pkg, "lan/proto", "static")

	// 匿名 section 的键是它的 section 名。真机上是 libuci 生成的 `cfgXXXXXX`
	// （darwin 的 fakeUCI 用空串，那是 fixtures 的既有约定，别在真机 golden 前依赖它）。
	anon := UciSection{Name: "cfg03f1", TypeName: "switch", Anonymous: true}
	apkg := marshalNoEscape(uciDumpPackageJSON([]UciSection{sec, anon}, "", nil))
	uciTestExpect(t, apkg, "cfg03f1/.anonymous", "true")
	uciTestExpect(t, apkg, "cfg03f1/.index", "1")
	uciTestExpect(t, apkg, "cfg03f1/.type", "switch")
}

func TestUCIFindSection(t *testing.T) {
	secs := []UciSection{
		{Name: "lan", TypeName: "interface"},
		{Name: "wan", TypeName: "interface"},
		{Name: "", TypeName: "switch", Anonymous: true},
	}

	s, ok := uciFindSection(secs, "wan")
	if !ok || s.Name != "wan" {
		t.Errorf("具名 wan 查找失败: %v %q", ok, s.Name)
	}

	s1, ok1 := uciFindSection(secs, "@interface[1]")
	if !ok1 || s1.Name != "wan" {
		t.Errorf("@interface[1] 应为 wan: %v %q", ok1, s1.Name)
	}

	s2, ok2 := uciFindSection(secs, "@switch[0]")
	if !ok2 || !s2.Anonymous {
		t.Errorf("@switch[0] 应为匿名 section: %v", ok2)
	}

	if _, ok3 := uciFindSection(secs, "@interface[2]"); ok3 {
		t.Error("@interface[2] 越界不应命中")
	}
	if _, ok4 := uciFindSection(secs, "nope"); ok4 {
		t.Error("不存在的名字不应命中")
	}
	if _, ok5 := uciFindSection(secs, "@interface["); ok5 {
		t.Error("残缺的扩展形式不应命中")
	}
}

func TestUCICallReadonly(t *testing.T) {
	// configs：uci.c:1382-1408，不做 ACL 检查
	reply, status := callUCI("configs", `{}`)
	if status != StatusOK {
		t.Fatalf("configs 状态 %d，期望 0", status)
	}
	if !strings.Contains(reply, `"network"`) || !strings.Contains(reply, `"system"`) {
		t.Errorf("configs 应含 network/system: %s", reply)
	}

	// get：package 级 → {"values": {…, ".index": N}}
	reply, status = callUCI("get", `{"config":"network"}`)
	if status != StatusOK {
		t.Fatalf("get network 状态 %d，期望 0", status)
	}
	uciTestExpect(t, reply, "values/lan/proto", "static")
	uciTestExpect(t, reply, "values/lan/.index", "0")
	uciTestExpect(t, reply, "values/wan/.index", "1")
	uciTestExpect(t, reply, "values/wg0/.index", "2")

	// get：section 级 → 不带 .index
	reply, status = callUCI("get", `{"config":"network","section":"lan"}`)
	if status != StatusOK {
		t.Fatalf("get section lan 状态 %d，期望 0", status)
	}
	uciTestExpect(t, reply, "values/.name", "lan")
	uciTestExpect(t, reply, "values/.index", "<missing>")

	// get：option 级 → 键是 "value"
	reply, status = callUCI("get", `{"config":"network","section":"lan","option":"proto"}`)
	if status != StatusOK {
		t.Fatalf("get option proto 状态 %d，期望 0", status)
	}
	uciTestExpect(t, reply, "value", "static")

	// get：扩展形式 @type[idx]
	reply, status = callUCI("get", `{"config":"network","section":"@interface[1]"}`)
	if status != StatusOK {
		t.Fatalf("get @interface[1] 状态 %d，期望 0", status)
	}
	uciTestExpect(t, reply, "values/.name", "wan")

	// get：type 筛选（匿名 switch section 被筛掉）
	reply, status = callUCI("get", `{"config":"network","type":"interface"}`)
	if status != StatusOK {
		t.Fatalf("get type=interface 状态 %d，期望 0", status)
	}
	uciTestExpect(t, reply, "values/wg0/proto", "wireguard")
	uciTestExpect(t, reply, "values/.name", "<missing>")

	// get：match 筛选
	reply, status = callUCI("get", `{"config":"network","match":{"proto":"dhcp"}}`)
	if status != StatusOK {
		t.Fatalf("get match proto=dhcp 状态 %d，期望 0", status)
	}
	uciTestExpect(t, reply, "values/wan/proto", "dhcp")
	uciTestExpect(t, reply, "values/lan/proto", "<missing>")

	// 错误分支
	check := func(method, params string, want int) {
		t.Helper()
		if _, st := callUCI(method, params); st != want {
			t.Errorf("callUCI(%q, %s) = %d，期望 %d", method, params, st, want)
		}
	}
	check("get", `{}`, StatusInvalidArgument)
	check("get", `{"config":"nope"}`, StatusNotFound)
	check("get", `{"config":"network","section":"nope"}`, StatusNotFound)
	check("get", `{"config":"network","section":"@interface[9]"}`, StatusNotFound)
	check("get", `{"config":42}`, StatusInvalidArgument)

	// darwin 上 provider 不实现的方法（savedir 模型 + 写事务）回 NOT_SUPPORTED(8)：
	// 这是**平台能力缺口**，不是「molly 还没写」——linux 上这三个都是真实现。
	// 注意：`changes`、五个写操作与 apply 系在 darwin 也能跑到底（参数校验/文件检查先于
	// 平台能力），不在这个集合里。
	for _, m := range []string{"state", "revert", "commit"} {
		if _, st := callUCI(m, `{"config":"network"}`); st != StatusNotSupported {
			t.Errorf("%s 应回 NOT_SUPPORTED，实际 %d", m, st)
		}
	}

	// 未知方法 → 3（真机上 libubus 在 handler 之前就回 3）
	check("frob", `{}`, StatusMethodNotFound)
}

func TestUCIDumpChange(t *testing.T) {
	// 完整形态：["set","lan","ipaddr","10.0.0.1"]（uci.c:1205-1219）
	full := uciChange{kind: uciChangeChange, section: "lan", name: "ipaddr", value: "10.0.0.1"}
	if got := marshalNoEscape(uciDumpChangeJSON(full)); got != `["set","lan","ipaddr","10.0.0.1"]` {
		t.Errorf("完整 delta = %s", got)
	}

	// 只有 section
	if got := marshalNoEscape(uciDumpChangeJSON(uciChange{kind: uciChangeAdd, section: "wg1"})); got != `["add","wg1"]` {
		t.Errorf("add = %s", got)
	}

	// 有 name 没有 value（remove 的形态）
	rm := uciChange{kind: uciChangeRemove, section: "wan", name: "proto"}
	if got := marshalNoEscape(uciDumpChangeJSON(rm)); got != `["remove","wan","proto"]` {
		t.Errorf("remove = %s", got)
	}

	// order 的 value 是**数字**（uci.c:1215-1216 用 blobmsg_add_u32）
	ord := uciChange{kind: uciChangeReorder, section: "lan", value: "3"}
	if got := marshalNoEscape(uciDumpChangeJSON(ord)); got != `["order","lan",3]` {
		t.Errorf("order = %s", got)
	}

	// 七种 kind → type 字符串
	kinds := []uciChange{
		{kind: uciChangeAdd, section: "s"},
		{kind: uciChangeRemove, section: "s"},
		{kind: uciChangeChange, section: "s"},
		{kind: uciChangeRename, section: "s"},
		{kind: uciChangeReorder, section: "s"},
		{kind: uciChangeListAdd, section: "s"},
		{kind: uciChangeListDel, section: "s"},
	}
	want := []string{"add", "remove", "set", "rename", "order", "list-add", "list-del"}
	for i, c := range kinds {
		text := marshalNoEscape(uciDumpChangeJSON(c))
		if !strings.Contains(text, `"`+want[i]+`"`) {
			t.Errorf("%d → %s，期望含 %s", c.kind, text, want[i])
		}
	}

	// section 为空的条目整条丢掉（uci.c:1202-1203）
	dropped := []uciChange{
		{kind: uciChangeChange, section: "lan", name: "ipaddr", value: "1"},
		{kind: uciChangeChange, name: "ignored"},
	}
	if got := marshalNoEscape(uciDumpChangesJSON(dropped)); got != `[["set","lan","ipaddr","1"]]` {
		t.Errorf("dropped = %s", got)
	}
}

func TestUCIChangesDarwinFixture(t *testing.T) {
	// 不带 config：{"changes": {<有 delta 的 config>: [ … ]}}
	reply, status := callUCI("changes", `{}`)
	if status != StatusOK {
		t.Fatalf("changes {} 状态 %d，期望 0", status)
	}

	var doc struct {
		Changes map[string][][]any `json:"changes"`
	}
	if err := json.Unmarshal([]byte(reply), &doc); err != nil {
		t.Fatalf("changes 回复解析失败: %v (%s)", err, reply)
	}
	// 只有 network 有假 delta（darwin 的 uciFakeDelta）
	if len(doc.Changes) != 1 {
		t.Fatalf("期望只有 1 个 config 有 delta，实际 %d", len(doc.Changes))
	}
	list, isList := doc.Changes["network"]
	if !isList {
		t.Fatalf("network 的 delta 应为数组: %s", reply)
	}
	// 6 条假 delta 里第 6 条 section 为空 → 只剩 5 条
	if len(list) != 5 {
		t.Fatalf("network 假 delta 期望 5 条，实际 %d", len(list))
	}

	first := list[0]
	if len(first) != 4 || first[0] != "set" || first[1] != "lan" || first[2] != "ipaddr" || first[3] != "10.0.0.1" {
		t.Errorf("第 1 条 delta 形状不对: %v", first)
	}

	// 第 4 条是 ["order","lan",3]：value 是数字
	ord := list[3]
	if len(ord) != 3 || ord[0] != "order" {
		t.Errorf("第 4 条应为 order: %v", ord)
	} else if _, isInt := ord[2].(float64); !isInt {
		t.Errorf("order 的 value 应为数字: %v", ord[2])
	}

	// 给了 config：直接是数组
	one, stOne := callUCI("changes", `{"config":"network"}`)
	if stOne != StatusOK {
		t.Fatalf("changes network 状态 %d，期望 0", stOne)
	}
	if got := uciTestGet(one, "changes"); got != "" {
		t.Errorf("数组形态的 changes 取成标量应为空串，实际 %q", got)
	}
	var d2 struct {
		Changes []any `json:"changes"`
	}
	if err := json.Unmarshal([]byte(one), &d2); err != nil {
		t.Fatalf("changes network 解析失败: %v", err)
	}
	if len(d2.Changes) != 5 {
		t.Errorf("changes network 期望 5 条，实际 %d", len(d2.Changes))
	}

	// 没有 delta 的 config → 空数组（不是错误）
	none, stNone := callUCI("changes", `{"config":"system"}`)
	if stNone != StatusOK {
		t.Fatalf("changes system 状态 %d，期望 0", stNone)
	}
	var d3 struct {
		Changes []any `json:"changes"`
	}
	if err := json.Unmarshal([]byte(none), &d3); err != nil {
		t.Fatalf("changes system 解析失败: %v", err)
	}
	if len(d3.Changes) != 0 {
		t.Errorf("changes system 应为空数组，实际 %d 条", len(d3.Changes))
	}

	// 不存在的 config → 4
	if _, stBad := callUCI("changes", `{"config":"nope"}`); stBad != StatusNotFound {
		t.Errorf("changes nope 应回 4，实际 %d", stBad)
	}
}

// uciNewSession 建一个干净会话（没有任何 ACL），返回 sid。
func uciNewSession(t *testing.T) string {
	t.Helper()
	reply, status := SessionCall("create", `{}`)
	if status != StatusOK {
		t.Fatalf("create 状态 %d，期望 0", status)
	}
	var doc struct {
		Sid string `json:"ubus_rpc_session"`
	}
	if err := json.Unmarshal([]byte(reply), &doc); err != nil {
		t.Fatalf("create 回复解析失败: %v (%s)", err, reply)
	}
	return doc.Sid
}

func TestUCIWritePathsPlatformAndACL(t *testing.T) {
	// 无 sid（内部调用，不做 ACL）：平台能力决定 —— darwin 上 state/commit/revert 都是 8
	for _, m := range []string{"state", "commit", "revert"} {
		if _, st := callUCI(m, `{"config":"network"}`); st != StatusNotSupported {
			t.Errorf("%s 在 darwin 应回 8，实际 %d", m, st)
		}
	}

	// 有 sid 但没有写权限 → 6：ACL 检查在平台能力**之前**（上游顺序，uci.c:1336-1341）
	sid := uciNewSession(t)
	commitParams := fmt.Sprintf(`{"ubus_rpc_session":%q,"config":"network"}`, sid)
	if _, st := callUCI("commit", commitParams); st != StatusPermissionDenied {
		t.Errorf("commit 无权限应回 6，实际 %d", st)
	}
	if _, st := callUCI("revert", commitParams); st != StatusPermissionDenied {
		t.Errorf("revert 无权限应回 6，实际 %d", st)
	}
	// state 要的是**读**权限，同样没有 → 6
	if _, st := callUCI("state", commitParams); st != StatusPermissionDenied {
		t.Errorf("state 无权限应回 6，实际 %d", st)
	}

	// 缺 config → 2（ACL 之后、平台能力之前）
	if _, st := callUCI("commit", `{}`); st != StatusInvalidArgument {
		t.Errorf("commit 缺 config 应回 2，实际 %d", st)
	}

	// 清掉这个会话，免得留着影响别的用例
	if _, st := SessionCall("destroy", fmt.Sprintf(`{"ubus_rpc_session":%q}`, sid)); st != StatusOK {
		t.Errorf("destroy 状态 %d，期望 0", st)
	}
}

func TestUCIWriteMethodValidation(t *testing.T) {
	check := func(method, params string, want int) {
		t.Helper()
		if _, st := callUCI(method, params); st != want {
			t.Errorf("callUCI(%q, %s) = %d，期望 %d", method, params, st, want)
		}
	}

	// --- 参数校验在 ACL 之前（无 sid 也能测出 2）---
	check("set", `{}`, StatusInvalidArgument)
	// 既没 section 也没 type/match
	check("set", `{"config":"network","values":{"proto":"static"}}`, StatusInvalidArgument)
	// values 不是表
	check("set", `{"config":"network","values":[],"section":"lan"}`, StatusInvalidArgument)
	// section 不是合法 id（扩展形式必须以 @ 开头）
	check("set", `{"config":"network","values":{"a":"b"},"section":"lan[0]"}`, StatusInvalidArgument)
	check("add", `{"config":"network"}`, StatusInvalidArgument)
	// type 不是合法类型名
	check("add", `{"config":"network","type":"wifi-iface[0]"}`, StatusInvalidArgument)
	// section 名不允许 '-'
	check("add", `{"config":"network","type":"interface","name":"lan-x"}`, StatusInvalidArgument)

	// --- 有 sid 但没写权限 → 6 ---
	sid := uciNewSession(t)
	setBody := fmt.Sprintf(`{"ubus_rpc_session":%q,"config":"network","values":{"proto":"static"},"section":"lan"}`, sid)
	check("set", setBody, StatusPermissionDenied)
	addBody := fmt.Sprintf(`{"ubus_rpc_session":%q,"config":"network","type":"interface","name":"molly0"}`, sid)
	check("add", addBody, StatusPermissionDenied)

	// --- 授权写之后：darwin 没有写事务 → 8 ---
	if _, st := SessionCall(
		"grant",
		fmt.Sprintf(`{"ubus_rpc_session":%q,"scope":"uci","objects":[["*","write"]]}`, sid),
	); st != StatusOK {
		t.Fatalf("grant 状态 %d，期望 0", st)
	}
	check("set", setBody, StatusNotSupported)
	check("add", addBody, StatusNotSupported)

	// 清场
	if _, st := SessionCall("destroy", fmt.Sprintf(`{"ubus_rpc_session":%q}`, sid)); st != StatusOK {
		t.Errorf("destroy 状态 %d，期望 0", st)
	}
}

func TestUCIDeleteRenameOrderValidation(t *testing.T) {
	check := func(method, params string, want int) {
		t.Helper()
		if _, st := callUCI(method, params); st != want {
			t.Errorf("callUCI(%q, %s) = %d，期望 %d", method, params, st, want)
		}
	}

	// --- 必需参数缺失（在 ACL 之前：无 sid 也能测出 2）---
	check("delete", `{}`, StatusInvalidArgument)
	// 既没 section 也没 type/match
	check("delete", `{"config":"network"}`, StatusInvalidArgument)
	check("rename", `{}`, StatusInvalidArgument)
	// 缺 name
	check("rename", `{"config":"network","section":"lan"}`, StatusInvalidArgument)
	check("order", `{}`, StatusInvalidArgument)
	// sections 不是数组
	check("order", `{"config":"network","sections":"lan"}`, StatusInvalidArgument)

	// --- 无 sid（内部调用）→ 语法校验：type/section/name ---
	check("delete", `{"config":"network","type":"wifi-iface[0]"}`, StatusInvalidArgument)
	check("delete", `{"config":"network","section":"lan[0]"}`, StatusInvalidArgument)
	// name 不允许 '-'
	check("rename", `{"config":"network","section":"lan","name":"lan-x"}`, StatusInvalidArgument)

	// --- 有 sid 但没写权限 → 6；注意**语法校验在 ACL 之后**（与上游一致）---
	sid := uciNewSession(t)
	delBody := fmt.Sprintf(`{"ubus_rpc_session":%q,"config":"network","section":"lan","options":["dns"]}`, sid)
	check("delete", delBody, StatusPermissionDenied)
	// 同一个请求把 section 写成非法值，仍然是 6（ACL 先于语法）
	check("delete", fmt.Sprintf(`{"ubus_rpc_session":%q,"config":"network","section":"lan[0]"}`, sid), StatusPermissionDenied)
	renBody := fmt.Sprintf(`{"ubus_rpc_session":%q,"config":"network","section":"lan","name":"lan2"}`, sid)
	check("rename", renBody, StatusPermissionDenied)
	check("rename", fmt.Sprintf(`{"ubus_rpc_session":%q,"config":"network","section":"lan","name":"lan-x"}`, sid), StatusPermissionDenied)
	ordBody := fmt.Sprintf(`{"ubus_rpc_session":%q,"config":"network","sections":["wan","lan"]}`, sid)
	check("order", ordBody, StatusPermissionDenied)

	// --- 授权写之后：darwin 没有写事务 → 8 ---
	if _, st := SessionCall(
		"grant",
		fmt.Sprintf(`{"ubus_rpc_session":%q,"scope":"uci","objects":[["*","write"]]}`, sid),
	); st != StatusOK {
		t.Fatalf("grant 状态 %d，期望 0", st)
	}
	check("delete", delBody, StatusNotSupported)
	check("rename", renBody, StatusNotSupported)
	check("order", ordBody, StatusNotSupported)

	// 清场
	if _, st := SessionCall("destroy", fmt.Sprintf(`{"ubus_rpc_session":%q}`, sid)); st != StatusOK {
		t.Errorf("destroy 状态 %d，期望 0", st)
	}
}

func TestUCIApplyFamilyNeutralPaths(t *testing.T) {
	check := func(method, params string, want int) {
		t.Helper()
		if _, st := callUCI(method, params); st != want {
			t.Errorf("callUCI(%q, %s) = %d，期望 %d", method, params, st, want)
		}
	}

	// apply 缺 sid（内部调用）→ 2（HTTP 上总会注入哨兵 sid，所以这条只在内部调用出现）
	check("apply", `{}`, StatusInvalidArgument)

	// 没有待确认的 apply 时：confirm / rollback 都是 5（NO_DATA）——
	// 注意 rollback 的顺序是「先判 pending（5）再判 sid 参数（2）」，与 confirm 相反
	check("confirm", `{"ubus_rpc_session":"x"}`, StatusNoData)
	check("rollback", `{}`, StatusNoData)
	check("rollback", `{"ubus_rpc_session":"x"}`, StatusNoData)

	// apply 带了 sid：跳过参数校验后去列该会话的 delta 目录。darwin 上这个目录不存在
	// （写路径不实现，永远不会建），所以是 4 —— 与设备上「没有任何未提交改动」时一致。
	check("apply", fmt.Sprintf(`{"ubus_rpc_session":%q}`, SessionDefaultID), StatusNotFound)

	// reload_config 要 fork/exec /sbin/reload_config：darwin 不做 → 8
	check("reload_config", `{}`, StatusNotSupported)
}

func TestUCIPurgeDir(t *testing.T) {
	base := filepath.Join(os.TempDir(), fmt.Sprintf("molly-uci-purge-%d", time.Now().UnixNano()))
	sub := filepath.Join(base, "sub")
	f1 := filepath.Join(base, "a.conf")
	f2 := filepath.Join(base, "b.conf")

	if err := os.Mkdir(base, 0o755); err != nil {
		t.Fatalf("建目录失败: %v", err)
	}
	if err := os.Mkdir(sub, 0o755); err != nil {
		t.Fatalf("建子目录失败: %v", err)
	}
	for _, f := range []string{f1, f2} {
		if err := os.WriteFile(f, nil, 0o644); err != nil {
			t.Fatalf("建文件失败: %v", err)
		}
	}

	uciPurgeDir(base)

	// 普通文件被删
	if _, err := os.Stat(f1); err == nil {
		t.Error("普通文件 a.conf 应被删除")
	}
	if _, err := os.Stat(f2); err == nil {
		t.Error("普通文件 b.conf 应被删除")
	}
	// 子目录被跳过（上游也是 continue），所以 rmdir 因为「目录非空」失败 —— 目录还在
	if _, err := os.Stat(base); err != nil {
		t.Error("含子目录的 base 应仍在")
	}
	if _, err := os.Stat(sub); err != nil {
		t.Error("子目录应仍在")
	}

	// 清场（别在 /tmp 留垃圾）
	_ = os.Remove(sub)
	_ = os.Remove(base)
}
