package handlers

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// withPrefix 临时改专家版前缀/strip，测完还原（cgi_base 由这两者推得）。
// 用 t.Cleanup 而非 defer：defer 会在本函数返回时就把全局改回去，测试体里反而看不到设置值。
func withPrefix(t *testing.T, prefix, strip string) {
	t.Helper()
	p, s := LuciPrefix, LuciStripSegment
	t.Cleanup(func() { LuciPrefix, LuciStripSegment = p, s })
	if err := SetLuciPrefix(prefix); err != nil {
		t.Fatal(err)
	}
	if err := SetLuciStripSegment(strip); err != nil {
		t.Fatal(err)
	}
}

// 本部署（prefix=/admin、strip=admin）：SCRIPT_NAME=""→cgi_base=""，三件套落在裸 /cgi-*。
func TestCGIIORoutingBareBase(t *testing.T) {
	withPrefix(t, "/admin", "admin")

	if got := cgiBasePrefix(); got != "" {
		t.Errorf("cgi_base = %q，期望空串", got)
	}
	for _, p := range []string{"/cgi-exec", "/cgi-download", "/cgi-upload", "/cgi-backup"} {
		if !IsCGIIOPath(p) {
			t.Errorf("%s 应判为 cgi-io 端点", p)
		}
	}
	if IsCGIIOPath("/admin/status/overview") {
		t.Error("/admin/… 不该判为 cgi-io 端点")
	}
	if IsCGIIOPath("/cgi-exec/x") { // 只精确匹配，不做前缀吞并
		t.Error("/cgi-exec/x 不该命中 cgi-io")
	}
}

// 上游默认（prefix=/cgi-bin/luci、不 strip）：cgi_base="/cgi-bin"，端点在 /cgi-bin/cgi-*。
func TestCGIIORoutingDefaultBase(t *testing.T) {
	withPrefix(t, "/cgi-bin/luci", "")

	if got := cgiBasePrefix(); got != "/cgi-bin" {
		t.Errorf("cgi_base = %q，期望 /cgi-bin", got)
	}
	if !IsCGIIOPath("/cgi-bin/cgi-exec") {
		t.Error("/cgi-bin/cgi-exec 应命中 cgi-io")
	}
	if IsCGIIOPath("/cgi-exec") {
		t.Error("默认 base 下裸 /cgi-exec 不该命中")
	}
}

// HTTP 状态码映射：走 fail-closed（非法会话/输入），无需真授权。
// 非 POST→405；空会话→403；未授权命令→403；不存在命令→404；空命令→400。
func TestCGIIExecStatusMapping(t *testing.T) {
	withPrefix(t, "/admin", "admin")

	if rec := cgiIORequest(t, "GET", "/cgi-exec", ""); rec.Code != http.StatusMethodNotAllowed {
		t.Errorf("GET /cgi-exec = %d，期望 405", rec.Code)
	}

	const bogus = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" // 非空、非默认，内部会话存储查不到

	cases := []struct {
		name, body string
		want       int
	}{
		{"空会话", "sessionid=&command=echo+hi", http.StatusForbidden},
		{"未授权命令", "sessionid=" + bogus + "&command=echo+hi", http.StatusForbidden},
		{"不存在命令", "sessionid=" + bogus + "&command=molly-not-here", http.StatusNotFound},
		{"空命令", "sessionid=" + bogus + "&command=%20%20", http.StatusBadRequest},
	}
	for _, c := range cases {
		rec := cgiIORequest(t, "POST", "/cgi-exec", c.body)
		if rec.Code != c.want {
			t.Errorf("%s: POST /cgi-exec = %d，期望 %d（body=%q）", c.name, rec.Code, c.want, c.body)
		}
	}
}

// download/upload 的空会话一律 403（会话必需，先于文件访问）。
func TestCGIIOSessionRequired(t *testing.T) {
	withPrefix(t, "/admin", "admin")

	rec := cgiIORequest(t, "POST", "/cgi-download", "sessionid=&path=/etc/hosts")
	if rec.Code != http.StatusForbidden {
		t.Errorf("空会话 download = %d，期望 403", rec.Code)
	}
}

// cgi-backup：非 POST→405；空会话→403（会话必需，先于跑 sysupgrade，无需真授权）。
func TestCGIIBackupStatusMapping(t *testing.T) {
	withPrefix(t, "/admin", "admin")

	if rec := cgiIORequest(t, "GET", "/cgi-backup", ""); rec.Code != http.StatusMethodNotAllowed {
		t.Errorf("GET /cgi-backup = %d，期望 405", rec.Code)
	}
	if rec := cgiIORequest(t, "POST", "/cgi-backup", "sessionid="); rec.Code != http.StatusForbidden {
		t.Errorf("空会话 POST /cgi-backup = %d，期望 403", rec.Code)
	}
}

// upload 无论成败都以 200 + JSON 回吐；非法会话回 {failure:true}。
func TestCGIIUploadJSONContract(t *testing.T) {
	withPrefix(t, "/admin", "admin")

	body, contentType := multipartBody(t, "", "/tmp/upload.ipk", "payload")
	rec := cgiIORequestWithContentType(t, "POST", "/cgi-upload", body, contentType)
	if rec.Code != http.StatusOK {
		t.Fatalf("upload HTTP = %d，期望恒 200（body=%s）", rec.Code, rec.Body.String())
	}
	if got := rec.Header().Get("Content-Type"); !strings.Contains(got, "application/json") {
		t.Errorf("upload Content-Type = %q，期望 application/json", got)
	}
	if !strings.Contains(rec.Body.String(), `"failure":true`) {
		t.Errorf("非法会话 upload 应带 failure:true，实际 = %s", rec.Body.String())
	}
}

// --- helpers ---------------------------------------------------------------

func cgiIORequest(t *testing.T, method, path, body string) *httptest.ResponseRecorder {
	t.Helper()
	return cgiIORequestWithContentType(t, method, path, body, "application/x-www-form-urlencoded")
}

func cgiIORequestWithContentType(t *testing.T, method, path, body, contentType string) *httptest.ResponseRecorder {
	t.Helper()
	var rdr *strings.Reader
	if method == http.MethodPost {
		rdr = strings.NewReader(body)
	} else {
		rdr = strings.NewReader("")
	}
	r := httptest.NewRequest(method, path, rdr)
	if contentType != "" {
		r.Header.Set("Content-Type", contentType)
	}
	rec := httptest.NewRecorder()
	ServeCGIIO(rec, r, path)
	return rec
}

// multipartBody 拼一份最小 multipart/form-data（sessionid / filename / filedata）。
func multipartBody(t *testing.T, sid, filename, data string) (body, contentType string) {
	t.Helper()
	b := &strings.Builder{}
	b.WriteString("--BOUNDARY\r\n")
	b.WriteString("Content-Disposition: form-data; name=\"sessionid\"\r\n\r\n")
	b.WriteString(sid + "\r\n")
	b.WriteString("--BOUNDARY\r\n")
	b.WriteString("Content-Disposition: form-data; name=\"filename\"\r\n\r\n")
	b.WriteString(filename + "\r\n")
	b.WriteString("--BOUNDARY\r\n")
	b.WriteString("Content-Disposition: form-data; name=\"filedata\"; filename=\"upload.ipk\"\r\n")
	b.WriteString("Content-Type: application/octet-stream\r\n\r\n")
	b.WriteString(data + "\r\n")
	b.WriteString("--BOUNDARY--\r\n")
	return b.String(), "multipart/form-data; boundary=BOUNDARY"
}
