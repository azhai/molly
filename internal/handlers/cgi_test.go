package handlers

import (
	"net/http/httptest"
	"strings"
	"testing"
)

// envValue 从 "K=V" 列表里取 K 的值。
func envValue(env []string, key string) string {
	for _, e := range env {
		if strings.HasPrefix(e, key+"=") {
			return e[len(key)+1:]
		}
	}
	return "\x00不存在"
}

func TestParseCGIResponse(t *testing.T) {
	t.Run("CRLF 与 Status", func(t *testing.T) {
		resp, ok := parseCGIResponse("Content-Type: text/plain\r\nStatus: 302 Found\r\nLocation: /x\r\n\r\nbody")
		if !ok {
			t.Fatal("解析失败")
		}
		if resp.code != 302 || resp.reason != "Found" {
			t.Errorf("code/reason = %d/%q", resp.code, resp.reason)
		}
		if resp.contentType != "text/plain" || resp.body != "body" {
			t.Errorf("contentType/body = %q/%q", resp.contentType, resp.body)
		}
		if len(resp.extra) != 1 || resp.extra[0].Name != "Location" || resp.extra[0].Value != "/x" {
			t.Errorf("extra = %+v", resp.extra)
		}
	})

	t.Run("LF LF 分隔", func(t *testing.T) {
		resp, ok := parseCGIResponse("Content-Type: text/html\n\nhi")
		if !ok || resp.body != "hi" || resp.code != 200 {
			t.Fatalf("ok=%v resp=%+v", ok, resp)
		}
	})

	t.Run("容忍 HTTP/1.1 起始行", func(t *testing.T) {
		resp, ok := parseCGIResponse("HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\n\r\nx")
		if !ok || resp.code != 404 {
			t.Fatalf("ok=%v code=%d", ok, resp.code)
		}
	})

	t.Run("Status 无原因短语时用表内短语", func(t *testing.T) {
		resp, ok := parseCGIResponse("Status: 403\r\nContent-Type: text/plain\r\n\r\n")
		if !ok || resp.reason != "Forbidden" {
			t.Fatalf("ok=%v reason=%q", ok, resp.reason)
		}
	})

	t.Run("缺 Content-Type → 失败", func(t *testing.T) {
		if _, ok := parseCGIResponse("Status: 200 OK\r\n\r\nx"); ok {
			t.Fatal("缺 Content-Type 应当判失败")
		}
	})

	t.Run("没有空行分隔 → 失败", func(t *testing.T) {
		if _, ok := parseCGIResponse("Content-Type: text/plain"); ok {
			t.Fatal("没有头体分隔应当判失败")
		}
	})

	t.Run("Content-Length / Connection 被丢弃", func(t *testing.T) {
		resp, ok := parseCGIResponse(
			"Content-Type: text/plain\r\nContent-Length: 999\r\nConnection: close\r\n\r\n")
		if !ok {
			t.Fatal("解析失败")
		}
		if len(resp.extra) != 0 {
			t.Errorf("Content-Length / Connection 不该透传：%+v", resp.extra)
		}
	})
}

func TestBuildCGIEnv(t *testing.T) {
	r := httptest.NewRequest("POST", "/cgi-bin/luci/admin/status/overview?v=1&x=2",
		strings.NewReader("hello"))
	r.Host = "router.lan"
	r.Header.Set("X-Test", "abc")
	r.Header.Set("Content-Type", "application/json")

	env := buildCGIEnv(r, "/admin/status/overview", "127.0.0.1", // 树路径：前缀归 SCRIPT_NAME

		"tests/fixtures/www", "/tmp/molly-ubus.sock", []byte("hello"))

	cases := map[string]string{
		"GATEWAY_INTERFACE": "CGI/1.1",
		"SERVER_SOFTWARE":   "molly",
		"SERVER_PROTOCOL":   "HTTP/1.1",
		"REQUEST_METHOD":    "POST",
		"REQUEST_URI":       "/cgi-bin/luci/admin/status/overview?v=1&x=2",
		"SCRIPT_NAME":       "/cgi-bin/luci",
		"PATH_INFO":         "/admin/status/overview",
		"QUERY_STRING":      "v=1&x=2",
		"DOCUMENT_ROOT":     "tests/fixtures/www",
		"REMOTE_ADDR":       "127.0.0.1",
		"CONTENT_LENGTH":    "5",
		"CONTENT_TYPE":      "application/json",
		"HTTP_X_TEST":       "abc",
		"HTTP_HOST":         "router.lan",
		"MOLLY_UBUS_SOCKET": "/tmp/molly-ubus.sock",
	}
	for k, want := range cases {
		if got := envValue(env, k); got != want {
			t.Errorf("%s = %q，期望 %q", k, got, want)
		}
	}
	// 特例头不做成 HTTP_*
	for _, k := range []string{"HTTP_CONTENT_TYPE", "HTTP_CONTENT_LENGTH"} {
		if got := envValue(env, k); got != "\x00不存在" {
			t.Errorf("%s 不该出现，实际 %q", k, got)
		}
	}
}

// molly 只下发 sysauth_molly，而设备上的原生 ucode dispatcher 只认 sysauth_http/sysauth_https；
// 把会话转交给子进程时必须补上那两个名字，否则每个 /admin 页都会 403。
func TestBuildCGIEnvRenamesSessionCookie(t *testing.T) {
	sid := "0123456789abcdef0123456789abcdef"
	r := httptest.NewRequest("GET", "/admin/system/package-manager", nil)
	r.Header.Set("Cookie", "sysauth_molly="+sid)
	env := buildCGIEnv(r, "/admin/system/package-manager", "127.0.0.1", "/www", "", nil)
	got := envValue(env, "HTTP_COOKIE")
	for _, want := range []string{"sysauth_molly=" + sid, "sysauth_http=" + sid, "sysauth_https=" + sid} {
		if !strings.Contains(got, want) {
			t.Errorf("HTTP_COOKIE 缺 %q；实际 %q", want, got)
		}
	}
	n := 0
	for _, e := range env {
		if strings.HasPrefix(e, "HTTP_COOKIE=") {
			n++
		}
	}
	if n != 1 {
		t.Errorf("HTTP_COOKIE 出现 %d 次，期望 1", n)
	}
}

// 无会话（匿名）时不该伪造任何会话 cookie。
func TestBuildCGIEnvAnonymousNoCookie(t *testing.T) {
	r := httptest.NewRequest("GET", "/admin/status/overview", nil)
	env := buildCGIEnv(r, "/admin/status/overview", "127.0.0.1", "/www", "", nil)
	if got := envValue(env, "HTTP_COOKIE"); got != "\x00不存在" {
		t.Errorf("匿名请求不该有 HTTP_COOKIE，实际 %q", got)
	}
}

func TestBuildCGIEnvBarePrefix(t *testing.T) {
	r := httptest.NewRequest("GET", "/cgi-bin/luci", nil)
	env := buildCGIEnv(r, "", "127.0.0.1", "/www", "", nil) // 根：树路径为空串
	if got := envValue(env, "PATH_INFO"); got != "" {
		t.Errorf("裸前缀的 PATH_INFO = %q，期望空", got)
	}
	if got := envValue(env, "CONTENT_LENGTH"); got != "0" {
		t.Errorf("CONTENT_LENGTH = %q，期望 0", got)
	}
	if got := envValue(env, "MOLLY_UBUS_SOCKET"); got != "\x00不存在" {
		t.Errorf("没配 --ubus-socket 时不该有 MOLLY_UBUS_SOCKET")
	}
}

// 专家版前缀 /admin + --luci-strip admin：交给 ucode 的 SCRIPT_NAME 必须去掉那段尾缀，
// 否则 build_url = SCRIPT_NAME(/admin) + 树首段 admin 会把 URL 拼成 /admin/admin/…（双写）。
func TestCGIScriptNameWithStrip(t *testing.T) {
	defer func(p, s string) { LuciPrefix, LuciStripSegment = p, s }(LuciPrefix, LuciStripSegment)

	if err := SetLuciPrefix("/admin"); err != nil {
		t.Fatal(err)
	}
	if err := SetLuciStripSegment("admin"); err != nil {
		t.Fatal(err)
	}
	if got := cgiScriptName(); got != "" {
		t.Errorf("SCRIPT_NAME = %q，期望空串（/admin 去掉尾段 admin）", got)
	}

	r := httptest.NewRequest("GET", "/admin/status/overview", nil)
	env := buildCGIEnv(r, "/admin/status/overview", "127.0.0.1", "/www", "", nil)
	if got := envValue(env, "SCRIPT_NAME"); got != "" {
		t.Errorf("env SCRIPT_NAME = %q，期望空串", got)
	}
	// PATH_INFO 仍是完整树路径（ucode 靠它找节点）
	if got := envValue(env, "PATH_INFO"); got != "/admin/status/overview" {
		t.Errorf("PATH_INFO = %q，期望 /admin/status/overview", got)
	}
}

// 上游默认（无前缀改写、strip 为空）：SCRIPT_NAME 逐字节等于 LuciPrefix，行为不变。
func TestCGIScriptNameNoStrip(t *testing.T) {
	defer func(p, s string) { LuciPrefix, LuciStripSegment = p, s }(LuciPrefix, LuciStripSegment)

	if err := SetLuciPrefix("/cgi-bin/luci"); err != nil {
		t.Fatal(err)
	}
	if err := SetLuciStripSegment(""); err != nil {
		t.Fatal(err)
	}
	if got := cgiScriptName(); got != "/cgi-bin/luci" {
		t.Errorf("SCRIPT_NAME = %q，期望 /cgi-bin/luci", got)
	}
}

func TestSplitCommand(t *testing.T) {
	got := splitCommand("  /usr/bin/ucode \t /www/cgi-bin/luci ")
	want := []string{"/usr/bin/ucode", "/www/cgi-bin/luci"}
	if len(got) != len(want) {
		t.Fatalf("got %v", got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("[%d] = %q，期望 %q", i, got[i], want[i])
		}
	}
	if len(splitCommand("   ")) != 0 {
		t.Error("空白命令应当切成空切片")
	}
}

func TestHeaderEnvName(t *testing.T) {
	if got := headerEnvName("X-Forwarded-For"); got != "X_FORWARDED_FOR" {
		t.Errorf("got %q", got)
	}
}

func TestCGIMethodString(t *testing.T) {
	for _, m := range []string{"GET", "HEAD", "POST", "PUT", "DELETE", "OPTIONS"} {
		if got := cgiMethodString(m); got != m {
			t.Errorf("%s → %q", m, got)
		}
	}
	if got := cgiMethodString("FROB"); got != "UNKNOWN" {
		t.Errorf("FROB → %q，期望 UNKNOWN", got)
	}
}
