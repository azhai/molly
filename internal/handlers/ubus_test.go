package handlers

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"

	"github.com/azhai/molly/internal/backend"
)

// TestMain 把 ACL 目录指向仓库 fixture：darwin provider 的默认相对路径是**包工作
// 目录**下的 tests/fixtures/acl.d（在 internal/handlers 下不存在），必须显式覆盖，
// 否则前置 ACL 校验 fail-closed，登录也会被判 -32002。
func TestMain(m *testing.M) {
	os.Setenv("GOMOLLY_ACL_DIR", filepath.Join("..", "..", "tests", "fixtures", "acl.d"))
	os.Exit(m.Run())
}

// doUbus 打一次 /ubus，返回状态码与正文。path 直接传给 ServeUbus（等价于
// NormalizePath 之后的产物）。后端用 darwin 假数据。
func doUbus(t *testing.T, method, path, body string, hdr map[string]string) (int, string) {
	t.Helper()
	var r *http.Request
	if body == "" {
		r = httptest.NewRequest(method, path, nil)
	} else {
		r = httptest.NewRequest(method, path, strings.NewReader(body))
	}
	for k, v := range hdr {
		r.Header.Set(k, v)
	}
	w := httptest.NewRecorder()
	ServeUbus(w, r, path, backend.New())
	return w.Code, w.Body.String()
}

// at 在响应 JSON 上按对象键逐层取值；取不到就 Fatal。
func at(t *testing.T, body string, keys ...string) any {
	t.Helper()
	var v any
	if err := json.Unmarshal([]byte(body), &v); err != nil {
		t.Fatalf("响应不是合法 JSON：%v\n正文：%s", err, body)
	}
	cur := v
	for _, k := range keys {
		m, ok := cur.(map[string]any)
		if !ok {
			t.Fatalf("在 %q 处不是对象：%#v（正文 %s）", k, cur, body)
		}
		cur = m[k]
	}
	return cur
}

// testSID 登一个会话并返回 sid。P3-6 起 /ubus 的 call 先走前置 ACL 校验，未认证的
// 哨兵 sid 除 session.login 外一律 -32002；fixture 的 smoke-full 组授了 `*` ubus，
// 登录后足以放行各对象的**对象级**语义断言（那些才是这些用例的目标）。
func testSID(t *testing.T) string {
	t.Helper()
	_, out := doUbus(t, "POST", "/ubus/call/session",
		`{"jsonrpc":"2.0","id":"login","method":"login","params":{"username":"root","password":"test1234"}}`, nil)
	sid, _ := at(t, out, "result", "ubus_rpc_session").(string)
	if sid == "" {
		t.Fatalf("登录未拿到 sid：%s", out)
	}
	return sid
}

func sortedKeys(t *testing.T, v any) string {
	t.Helper()
	m, ok := v.(map[string]any)
	if !ok {
		t.Fatalf("不是对象：%#v", v)
	}
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return strings.Join(keys, ",")
}

func TestLegacyCallEcho(t *testing.T) {
	sid := testSID(t)
	body := `{"jsonrpc":"2.0","id":1,"method":"call","params":["` + sid + `","luci","getBoardJSON",{}]}`
	code, out := doUbus(t, "POST", "/ubus", body, nil)
	if code != http.StatusOK {
		t.Fatalf("状态 = %d，期望 200", code)
	}
	result, ok := at(t, out, "result").([]any)
	if !ok || len(result) != 2 {
		t.Fatalf("旧式 result 应是 [ret,{…}]，得到 %s", out)
	}
	if result[0] != float64(0) {
		t.Errorf("result[0] = %v，期望 0", result[0])
	}
	echo, ok := result[1].(map[string]any)["echo"].(map[string]any)
	if !ok {
		t.Fatalf("result[1] 缺少 echo：%s", out)
	}
	if echo["object"] != "luci" || echo["method"] != "getBoardJSON" || echo["sid"] != sid {
		t.Errorf("echo 回显不对：%#v", echo)
	}
	if at(t, out, "id") != float64(1) {
		t.Errorf("id 未原样回显：%s", out)
	}
}

func TestLegacyMissingIDIsNull(t *testing.T) {
	_, out := doUbus(t, "POST", "/ubus", `{"jsonrpc":"2.0","method":"list"}`, nil)
	if at(t, out, "id") != nil {
		t.Errorf("缺 id 应回 null：%s", out)
	}
}

func TestLegacyErrorCodes(t *testing.T) {
	sid := testSID(t)
	tests := []struct {
		name string
		body string
		want float64
	}{
		// 对象不存在优先于 ACL：即便用哨兵 sid，也先回 -32000。
		{"未知对象", `{"jsonrpc":"2.0","id":2,"method":"call","params":["","nope","list",{}]}`, -32000},
		{"未知方法", `{"jsonrpc":"2.0","id":3,"method":"frob"}`, -32601},
		{"jsonrpc 非 2.0", `{"jsonrpc":"1.0","id":4,"method":"list"}`, -32700},
		{"params 不足四项", `{"jsonrpc":"2.0","id":5,"method":"call","params":["","session","list"]}`, -32700},
		{"params 带 ubus_rpc_session", `{"jsonrpc":"2.0","id":6,"method":"call","params":["` + sid + `","session","list",{"ubus_rpc_session":"x"}]}`, -32602},
		{"正文非法 JSON", `{oops`, -32700},
		{"正文是标量", `42`, -32700},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			code, out := doUbus(t, "POST", "/ubus", tt.body, nil)
			if code != http.StatusOK {
				t.Fatalf("状态 = %d，期望 200（错误走信封）", code)
			}
			if got := at(t, out, "error", "code"); got != tt.want {
				t.Errorf("error.code = %v，期望 %v（正文 %s）", got, tt.want, out)
			}
		})
	}
}

func TestLegacyList(t *testing.T) {
	// 无 params → 对象路径数组，字典序
	_, out := doUbus(t, "POST", "/ubus", `{"jsonrpc":"2.0","id":7,"method":"list"}`, nil)
	arr, ok := at(t, out, "result").([]any)
	if !ok {
		t.Fatalf("result 应是数组：%s", out)
	}
	got := make([]string, 0, len(arr))
	for _, v := range arr {
		got = append(got, v.(string))
	}
	if strings.Join(got, ",") != "file,luci,luci-rpc,molly.probe,session,uci" {
		t.Errorf("路径数组 = %v", got)
	}

	// 带 params → 详细表；查不到的路径忽略
	_, out = doUbus(t, "POST", "/ubus", `{"jsonrpc":"2.0","id":8,"method":"list","params":["session","uci","nope"]}`, nil)
	if keys := sortedKeys(t, at(t, out, "result")); keys != "session,uci" {
		t.Errorf("详细表键 = %q，期望 session,uci", keys)
	}
}

func TestLegacyBatch(t *testing.T) {
	sid := testSID(t)
	body := `[{"jsonrpc":"2.0","id":9,"method":"call","params":["` + sid + `","uci","configs",{}]},{"jsonrpc":"2.0","id":10,"method":"list"}]`
	_, out := doUbus(t, "POST", "/ubus", body, nil)
	var batch []map[string]any
	if err := json.Unmarshal([]byte(out), &batch); err != nil || len(batch) != 2 {
		t.Fatalf("批响应形状不对：%s（err=%v）", out, err)
	}
	if _, out := doUbus(t, "POST", "/ubus", `[]`, nil); out != "[]" {
		t.Errorf("空数组正文应回 []，得到 %s", out)
	}
}

func TestRestCall(t *testing.T) {
	sid := testSID(t)
	hdr := map[string]string{"Authorization": "Bearer " + sid}
	code, out := doUbus(t, "POST", "/ubus/call/luci",
		`{"jsonrpc":"2.0","id":11,"method":"getBoardJSON","params":{}}`, hdr)
	if code != http.StatusOK {
		t.Fatalf("状态 = %d，期望 200", code)
	}
	echo, ok := at(t, out, "result", "echo").(map[string]any)
	if !ok {
		t.Fatalf("新式 result 应是回复表本身：%s", out)
	}
	if echo["object"] != "luci" || echo["method"] != "getBoardJSON" {
		t.Errorf("echo 回显不对：%#v", echo)
	}
	if echo["sid"] != sid {
		t.Errorf("Bearer 的 sid 未送进对象：%#v", echo["sid"])
	}

	// 无 Authorization → 哨兵 sid → 非 session 对象取不到权限 → -32002（fail-closed）
	_, out = doUbus(t, "POST", "/ubus/call/luci", `{"jsonrpc":"2.0","id":12,"method":"getBoardJSON"}`, nil)
	if code := at(t, out, "error", "code"); code != float64(-32002) {
		t.Errorf("无 Authorization 应回 -32002，得到 %v（正文 %s）", code, out)
	}
}

// TestPreACL 覆盖 uhttpd 那道前置 ACL 校验（uh_ubus_allowed → session.access）：
// 对应 Odin 版 tests/http_smoke.sh:208-216 的四条断言。
func TestPreACL(t *testing.T) {
	const sentinel = "00000000000000000000000000000000"

	// 哨兵调用非 session 对象 → -32002（取不到权限，fail-closed）
	_, out := doUbus(t, "POST", "/ubus",
		`{"jsonrpc":"2.0","id":50,"method":"call","params":["`+sentinel+`","uci","configs",{}]}`, nil)
	if code := at(t, out, "error", "code"); code != float64(-32002) {
		t.Errorf("哨兵调 uci → %v，期望 -32002（%s）", code, out)
	}

	// 哨兵 login → 放行（unauthenticated 组授了 session.login）
	_, out = doUbus(t, "POST", "/ubus/call/session",
		`{"jsonrpc":"2.0","id":51,"method":"login","params":{"username":"root","password":"test1234"}}`, nil)
	if sid, _ := at(t, out, "result", "ubus_rpc_session").(string); len(sid) != 32 {
		t.Errorf("哨兵 login 应放行并回 32 位 sid，得到 %s", out)
	}

	// 无效 sid → -32002（会话取不到 → fail-closed）
	_, out = doUbus(t, "POST", "/ubus",
		`{"jsonrpc":"2.0","id":52,"method":"call","params":["deadbeefdeadbeefdeadbeefdeadbeef","uci","configs",{}]}`, nil)
	if code := at(t, out, "error", "code"); code != float64(-32002) {
		t.Errorf("无效 sid → %v，期望 -32002（%s）", code, out)
	}

	// 对象不存在优先于 ACL → -32000
	_, out = doUbus(t, "POST", "/ubus",
		`{"jsonrpc":"2.0","id":53,"method":"call","params":["`+sentinel+`","nope","frob",{}]}`, nil)
	if code := at(t, out, "error", "code"); code != float64(-32000) {
		t.Errorf("对象不存在应优先 → %v，期望 -32000（%s）", code, out)
	}
}

func TestRestErrorCodes(t *testing.T) {
	sid := testSID(t)
	hdr := map[string]string{"Authorization": "Bearer " + sid}
	tests := []struct {
		name, path, body string
		want             float64
	}{
		{"对象不存在", "/ubus/call/nope", `{"jsonrpc":"2.0","id":14,"method":"frob"}`, -32000},
		{"未知方法 → ubus 返回码 3", "/ubus/call/uci", `{"jsonrpc":"2.0","id":15,"method":"frob"}`, 3},
		{"params 非表", "/ubus/call/uci", `{"jsonrpc":"2.0","id":16,"method":"configs","params":[1,2]}`, -32602},
		{"params 为 null", "/ubus/call/uci", `{"jsonrpc":"2.0","id":17,"method":"configs","params":null}`, -32602},
		{"对象不存在优先于参数错误", "/ubus/call/nope", `{"jsonrpc":"2.0","id":18,"method":"configs","params":[1]}`, -32000},
		{"正文非法 JSON", "/ubus/call/uci", `{oops`, -32700},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, out := doUbus(t, "POST", tt.path, tt.body, hdr)
			if got := at(t, out, "error", "code"); got != tt.want {
				t.Errorf("error.code = %v，期望 %v（正文 %s）", got, tt.want, out)
			}
		})
	}
}

func TestRouting(t *testing.T) {
	// GET /ubus/list → 200 + 合法 JSON
	code, out := doUbus(t, "GET", "/ubus/list", "", nil)
	if code != http.StatusOK {
		t.Fatalf("GET /ubus/list 状态 = %d", code)
	}
	all, ok := at(t, out).(map[string]any)
	if !ok {
		t.Fatalf("list 正文不是对象：%s", out)
	}
	if keys := sortedKeys(t, all); keys != "file,luci,luci-rpc,molly.probe,session,uci" {
		t.Errorf("list 对象 = %q", keys)
	}
	// list 内嵌 session 与 list/session 必须一致
	_, sess := doUbus(t, "GET", "/ubus/list/session", "", nil)
	inner, _ := json.Marshal(all["session"])
	outer, _ := json.Marshal(at(t, sess))
	if string(inner) != string(outer) {
		t.Errorf("list 内嵌 session 与 list/session 不一致")
	}

	// GET /ubus/list/nope → 500 + ubus 错误码 4
	code, out = doUbus(t, "GET", "/ubus/list/nope", "", nil)
	if code != http.StatusInternalServerError {
		t.Fatalf("GET /ubus/list/nope 状态 = %d，期望 500", code)
	}
	if at(t, out, "code") != float64(4) {
		t.Errorf("500 正文 code = %v，期望 4", at(t, out, "code"))
	}

	// /ubus 与 /ubus/<其它> GET → 404；POST /ubus/<非 call> → 404
	for _, p := range []string{"/ubus", "/ubus/nope"} {
		if code, _ := doUbus(t, "GET", p, "", nil); code != http.StatusNotFound {
			t.Errorf("GET %s = %d，期望 404", p, code)
		}
	}
	if code, _ := doUbus(t, "POST", "/ubus/call", `{}`, nil); code != http.StatusNotFound {
		t.Errorf("POST /ubus/call = %d，期望 404", code)
	}
	// 其余方法一律 400
	if code, _ := doUbus(t, "PUT", "/ubus", "", nil); code != http.StatusBadRequest {
		t.Errorf("PUT /ubus = %d，期望 400", code)
	}
	if code, _ := doUbus(t, "HEAD", "/ubus", "", nil); code != http.StatusBadRequest {
		t.Errorf("HEAD /ubus = %d，期望 400", code)
	}
}

func TestOptions(t *testing.T) {
	r := httptest.NewRequest("OPTIONS", "/ubus", nil)
	w := httptest.NewRecorder()
	ServeUbus(w, r, "/ubus", backend.New())
	res := w.Result()
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		t.Fatalf("OPTIONS 状态 = %d，期望 200", res.StatusCode)
	}
	if ct := res.Header.Get("Content-Type"); ct != "application/json" {
		t.Errorf("OPTIONS Content-Type = %q", ct)
	}
	if cl := res.Header.Get("Content-Length"); cl != "0" {
		t.Errorf("OPTIONS Content-Length = %q，期望 0", cl)
	}
}
