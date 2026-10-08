package handlers

import (
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"

	"github.com/azhai/molly/internal/backend"
)

func TestSanitizeSID(t *testing.T) {
	cases := []struct{ in, want string }{
		{"", ""},
		{"0123456789abcdef0123456789abcdef", "0123456789abcdef0123456789abcdef"},
		{"ABCDEF0123456789ABCDEF0123456789", "ABCDEF0123456789ABCDEF0123456789"},
		// 非 hex 整串丢弃：这个值要拼进页面的 JS 字符串，收窄比转义可靠
		{"<script>x</script>", ""},
		{`"';alert(1)//`, ""},
		{"deadbeef<script>", ""},
		{"中文", ""},
		// 超长的合法 hex：截到 32 位
		{strings.Repeat("a", 40), strings.Repeat("a", 32)},
	}
	for _, c := range cases {
		if got := sanitizeSID(c.in); got != c.want {
			t.Errorf("sanitizeSID(%q) = %q，期望 %q", c.in, got, c.want)
		}
	}
}

func TestBuildNovicePage(t *testing.T) {
	page := buildNovicePage("0123456789abcdef0123456789abcdef")
	if strings.Contains(page, "__SID__") || strings.Contains(page, "__EXPERT_PREFIX__") {
		t.Fatal("占位符没有被替换干净")
	}
	if !strings.Contains(page, `SID_INJECTED = "0123456789abcdef0123456789abcdef"`) {
		t.Error("会话 id 没有被注入")
	}
	if !strings.Contains(page, `EXPERT_PREFIX = "`+LuciPrefix+`"`) {
		t.Errorf("专家版前缀没有被注入（期望 %q）", LuciPrefix)
	}
	// 非法 sid 进不去页面
	if bad := buildNovicePage("<script>x</script>"); strings.Contains(bad, "<script>x") {
		t.Error("非法 sid 泄漏进了页面")
	}
}

func TestWidenSessionCookiePath(t *testing.T) {
	cases := []struct{ in, want string }{
		// 会话 cookie：path 放宽成 /
		{"sysauth_molly=abc; path=/pro/; SameSite=strict; HttpOnly",
			"sysauth_molly=abc; path=/; SameSite=strict; HttpOnly"},
		{"sysauth_http=abc; Path=/cgi-bin/luci", "sysauth_http=abc; Path=/"},
		{"sysauth=deadbeef; path=/cgi-bin/luci", "sysauth=deadbeef; path=/"},
		// 没写 path：补一个（否则作用域由浏览器按默认目录规则猜）
		{"sysauth_molly=abc; HttpOnly", "sysauth_molly=abc; HttpOnly; path=/"},
		// 非会话 cookie：逐字节透传
		{"foo=bar; path=/pro/", "foo=bar; path=/pro/"},
		{"luci_lang=zh_cn", "luci_lang=zh_cn"},
	}
	for _, c := range cases {
		if got := widenSessionCookiePath(c.in); got != c.want {
			t.Errorf("widenSessionCookiePath(%q) = %q，期望 %q", c.in, got, c.want)
		}
	}
}

// 会话统一的核心断言（单元级）：新手版登录下发的 cookie，专家版（内置 dispatcher）直接认。
//
// 端到端那一份在 tests/smoke.sh，这里盯的是「不靠 HTTP 也会断」的那部分：cookie 的属性
// （path=/、HttpOnly）、以及登录走的就是 session 对象。
func TestNoviceLoginSharesSessionWithExpert(t *testing.T) {
	be := backend.New()

	// 登录走共用的 /auth/login（页面与专家版表单都往这里打）
	form := url.Values{"username": {"root"}, "password": {"test1234"}}
	r := httptest.NewRequest(http.MethodPost, "/auth/login", strings.NewReader(form.Encode()))
	r.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	w := httptest.NewRecorder()
	ServeAuth(w, r, "/auth/login", be)

	if w.Code != http.StatusFound {
		t.Fatalf("登录应回 302，实际 %d（正文 %q）", w.Code, w.Body.String())
	}
	// 没带 next 时回 "/"（它自己会再 302 到 /lite/）
	if loc := w.Header().Get("Location"); loc != "/" {
		t.Fatalf("登录成功应回到 /，实际 %q", loc)
	}
	res := w.Result()
	cookies := res.Cookies()
	if len(cookies) != 1 {
		t.Fatalf("应下发 1 个 cookie，实际 %d 个", len(cookies))
	}
	ck := cookies[0]
	if ck.Name != sessionCookie {
		t.Errorf("cookie 名应为 %q，实际 %q", sessionCookie, ck.Name)
	}
	if ck.Path != "/" {
		t.Errorf("cookie path 应为 /（两套界面共用），实际 %q", ck.Path)
	}
	if !ck.HttpOnly {
		t.Error("会话 cookie 应为 HttpOnly")
	}
	if sid := sanitizeSID(ck.Value); sid == "" || sid != ck.Value {
		t.Fatalf("cookie 里的 sid 形态不对：%q", ck.Value)
	}

	// 同一个 sid 拿去专家版页面：应当直接可用（同一条会话）
	er := httptest.NewRequest(http.MethodGet, "/cgi-bin/luci/admin/status/overview", nil)
	er.Header.Set("Cookie", sessionCookie+"="+ck.Value)
	ew := httptest.NewRecorder()
	ServeLuci(ew, er, "/cgi-bin/luci/admin/status/overview", LuciConfig{
		MenuDir: "../../tests/fixtures/menu.d",
		Deps:    be,
	})
	if ew.Code != http.StatusOK {
		t.Fatalf("专家版页面应接受新手版登录得到的会话（期望 200），实际 %d（正文 %q）",
			ew.Code, ew.Body.String())
	}
	if !strings.Contains(ew.Body.String(), "<h1>Overview</h1>") {
		t.Errorf("专家版页面正文不对：%q", ew.Body.String())
	}

	// 退出：清 cookie
	or := httptest.NewRequest(http.MethodPost, "/auth/logout", strings.NewReader(url.Values{}.Encode()))
	or.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	or.Header.Set("Cookie", sessionCookie+"="+ck.Value)
	ow := httptest.NewRecorder()
	ServeAuth(ow, or, "/auth/logout", be)
	if ow.Code != http.StatusFound {
		t.Fatalf("退出应回 302，实际 %d", ow.Code)
	}
	cleared := ow.Result().Cookies()
	if len(cleared) != 1 || cleared[0].Value != "" || cleared[0].MaxAge >= 0 {
		t.Errorf("退出应清掉会话 cookie，实际 %+v", cleared)
	}
}

func TestNoviceLoginWrongPassword(t *testing.T) {
	form := url.Values{"username": {"root"}, "password": {"wrong"}}
	r := httptest.NewRequest(http.MethodPost, "/auth/login", strings.NewReader(form.Encode()))
	r.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	w := httptest.NewRecorder()
	ServeAuth(w, r, "/auth/login", backend.New())

	if w.Code != http.StatusFound {
		t.Fatalf("登录失败也应回 302（回登录页），实际 %d", w.Code)
	}
	if loc := w.Header().Get("Location"); loc != "/?auth_error=bad_credentials" {
		t.Errorf("登录失败应回 /?auth_error=bad_credentials，实际 %q", loc)
	}
	if cs := w.Result().Cookies(); len(cs) != 0 {
		t.Errorf("登录失败不该下发 cookie，实际 %+v", cs)
	}
}

// 入口 `/` 只跳转，不出页面。用 302 而不是 301/308：前缀以后还可能再挪。
func TestNoviceEntryRedirect(t *testing.T) {
	for _, method := range []string{http.MethodGet, http.MethodHead, http.MethodPost} {
		r := httptest.NewRequest(method, "/", nil)
		w := httptest.NewRecorder()
		ServeNovice(w, r, "/", backend.New())
		if w.Code != http.StatusFound {
			t.Errorf("%s / 应回 302，实际 %d", method, w.Code)
		}
		if loc := w.Header().Get("Location"); loc != NovicePrefix+"/" {
			t.Errorf("%s / 的 Location 应为 %s/，实际 %q", method, NovicePrefix, loc)
		}
		if body := w.Body.String(); body != "" {
			t.Errorf("%s / 不该带正文，实际 %q", method, body)
		}
	}
}

// 非 GET/HEAD/POST 一律 405（与专家版一致）。
func TestNoviceMethodNotAllowed(t *testing.T) {
	r := httptest.NewRequest(http.MethodPut, "/lite", nil)
	w := httptest.NewRecorder()
	ServeNovice(w, r, "/lite", backend.New())
	if w.Code != http.StatusMethodNotAllowed {
		t.Errorf("PUT /lite 应回 405，实际 %d", w.Code)
	}
	// 路径判定范围：/lite 系列算新手版，/ 是入口（不是页面），别的都不算
	if !IsNovicePath("/lite") || !IsNovicePath("/lite/") || !IsNovicePath("/lite/index.html") {
		t.Error("IsNovicePath 应认 /lite、/lite/、/lite/index.html")
	}
	if IsNovicePath("/") {
		t.Error("/ 是入口（IsNoviceEntry），不是页面路径")
	}
	if IsNovicePath("/lite/admin") || IsNovicePath("/other") {
		t.Error("IsNovicePath 不该认别的路径")
	}
	if !IsNoviceEntry("/") || IsNoviceEntry("/lite") {
		t.Error("IsNoviceEntry 只该认 /")
	}
}

// 认证端点搬走之后，新手版页面**不再**接 POST：登录/退出只在 /auth 下。
func TestNoviceNoLongerHandlesPost(t *testing.T) {
	r := httptest.NewRequest(http.MethodPost, "/lite/", strings.NewReader(url.Values{
		"action": {"login"}, "username": {"root"}, "password": {"test1234"},
	}.Encode()))
	r.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	w := httptest.NewRecorder()
	ServeNovice(w, r, "/lite/", backend.New())
	if w.Code != http.StatusMethodNotAllowed {
		t.Fatalf("POST /lite/ 应回 405（认证已搬到 /auth），实际 %d", w.Code)
	}
}

// /auth 的三个端点与路径边界。
func TestAuthPaths(t *testing.T) {
	for _, p := range []string{"/auth", "/auth/", "/auth/login", "/auth/logout", "/auth/password"} {
		if !AuthPaths(p) {
			t.Errorf("AuthPaths(%q) 应为 true", p)
		}
	}
	for _, p := range []string{"/", "/lite", "/plus", "/authx", "/ubus"} {
		if AuthPaths(p) {
			t.Errorf("AuthPaths(%q) 应为 false", p)
		}
	}
	// /auth 下没有别的东西：GET 与不认识的子路径都 404（也不该泄露方法存在性）
	for _, tc := range []struct{ method, path string }{
		{http.MethodGet, "/auth/login"},
		{http.MethodPost, "/auth/nope"},
		{http.MethodPost, "/auth"},
	} {
		r := httptest.NewRequest(tc.method, tc.path, nil)
		w := httptest.NewRecorder()
		ServeAuth(w, r, tc.path, backend.New())
		if w.Code != http.StatusNotFound {
			t.Errorf("%s %s 应回 404，实际 %d", tc.method, tc.path, w.Code)
		}
	}
}

// next 只接受同源绝对路径：鉴权端点的跳转参数是开放重定向的经典入口。
func TestAuthNextRejectsOffsite(t *testing.T) {
	cases := map[string]string{
		"":                      "/",
		"/lite/":                "/lite/",
		"//evil.example/x":      "/",
		"http://evil.example/":  "/",
		"https://evil.example/": "/",
		"lite/":                 "/",
	}
	for in, want := range cases {
		r := httptest.NewRequest(http.MethodPost, "/auth/login",
			strings.NewReader(url.Values{"next": {in}}.Encode()))
		r.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		if got := authNext(r); got != want {
			t.Errorf("authNext(%q) = %q，期望 %q", in, got, want)
		}
	}
}
