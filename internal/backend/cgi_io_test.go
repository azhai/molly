//go:build darwin

package backend

// cgi-io 的单元测试：分词纯函数 + 三件套的 ACL 兜底（与 file.exec/file.read/file.write 同源）。
//
// 与 file_object_test.go 共用 fileTestSession / fileTestRoot：exec 用例依赖 macOS 上
// /bin/echo 的存在与 PATH 解析，所以整个文件加 darwin tag。

import (
	"bytes"
	"os"
	"strings"
	"testing"
)

func TestCGIIOTokenize(t *testing.T) {
	cases := []struct {
		in   string
		want []string
	}{
		{"echo hello world", []string{"echo", "hello", "world"}},
		{"/bin/echo hi", []string{"/bin/echo", "hi"}},
		// 前端把 token 内空白转义成 `\`+空白，这里应还原成单个 token：
		{"ls -d /tmp/a\\ b", []string{"ls", "-d", "/tmp/a b"}},
		// `\\` → 字面反斜杠：
		{"cat C:\\\\tmp", []string{"cat", "C:\\tmp"}},
		// 前后多余空白不产生空 token：
		{"  echo  hi  ", []string{"echo", "hi"}},
		{"", nil},
		{"   ", nil},
	}
	for _, c := range cases {
		got := cgiioTokenize(c.in)
		if len(got) != len(c.want) {
			t.Errorf("tokenize(%q) = %v，期望 %v", c.in, got, c.want)
			continue
		}
		for i := range got {
			if got[i] != c.want[i] {
				t.Errorf("tokenize(%q)[%d] = %q，期望 %q", c.in, i, got[i], c.want[i])
			}
		}
	}
}

func TestCGIIRequireSession(t *testing.T) {
	if cgiioRequireSession("") {
		t.Error("空会话不该放行")
	}
	if cgiioRequireSession(SessionDefaultID) {
		t.Error("默认会话不该放行")
	}
	if !cgiioRequireSession("0123456789abcdef0123456789abcdef") {
		t.Error("真实会话该放行")
	}
}

func TestCGIIExecSessionRequired(t *testing.T) {
	var out bytes.Buffer
	// 空/默认会话一律 6，且不触碰文件系统（先于查找与 ACL）。
	if st := CGIExec("", "echo hi", false, &out); st != StatusPermissionDenied {
		t.Errorf("空会话 exec = %d，期望 6", st)
	}
	if st := CGIExec(SessionDefaultID, "echo hi", false, &out); st != StatusPermissionDenied {
		t.Errorf("默认会话 exec = %d，期望 6", st)
	}
}

func TestCGIIExecACLAndNotFound(t *testing.T) {
	var out bytes.Buffer

	// 未授权但命令可找到（echo→/bin/echo）→ 6（ACL 兜底）。
	sid := fileTestSession(t)
	if st := CGIExec(sid, "echo hi", false, &out); st != StatusPermissionDenied {
		t.Errorf("未授权 exec = %d，期望 6", st)
	}

	// 命令找不到 → 4（先于 ACL：查找失败就是 NotFound）。
	if st := CGIExec(sid, "molly-definitely-not-here", false, &out); st != StatusNotFound {
		t.Errorf("不存在命令 = %d，期望 4", st)
	}

	// 空命令行 → 2（分词后无 token）。
	if st := CGIExec(sid, "   ", false, &out); st != StatusInvalidArgument {
		t.Errorf("空命令 = %d，期望 2", st)
	}
}

func TestCGIIExecAllowedStreams(t *testing.T) {
	sid := fileTestSession(t, [2]string{"/bin/echo", "exec"})
	var out bytes.Buffer
	if st := CGIExec(sid, "echo cgi-io works", false, &out); st != StatusOK {
		t.Fatalf("授权 exec = %d，期望 0", st)
	}
	if got := strings.TrimRight(out.String(), "\n"); got != "cgi-io works" {
		t.Errorf("流式输出 = %q，期望 %q", out.String(), "cgi-io works")
	}
}

func TestCGIIExecCommandLineACL(t *testing.T) {
	// 只放行整条命令行 `/bin/echo only-this`：精确匹配跑通，参数不同被拒。
	sid := fileTestSession(t, [2]string{"/bin/echo only-this", "exec"})

	var out bytes.Buffer
	if st := CGIExec(sid, "echo only-this", false, &out); st != StatusOK {
		t.Fatalf("命令行 ACL 精确匹配 = %d，期望 0", st)
	}
	if got := strings.TrimRight(out.String(), "\n"); got != "only-this" {
		t.Errorf("输出 = %q，期望 only-this", got)
	}

	var denied bytes.Buffer
	if st := CGIExec(sid, "echo other", false, &denied); st != StatusPermissionDenied {
		t.Errorf("命令行 ACL 参数不同 = %d，期望 6", st)
	}
}

func TestCGIIDownload(t *testing.T) {
	root := fileTestRoot(t)
	if err := os.Mkdir(root+"/work", 0o755); err != nil {
		t.Fatal(err)
	}
	f := root + "/work/list.txt"
	if err := os.WriteFile(f, []byte("line-a\nline-b\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	// 未授权 → 6。
	noSid := fileTestSession(t)
	var out bytes.Buffer
	if st := CGIDownload(noSid, "/etc/hosts", &out); st != StatusPermissionDenied {
		t.Errorf("无授权 download = %d，期望 6", st)
	}

	// 授权读 → 内容原样流式吐出。
	okSid := fileTestSession(t, [2]string{root + "/*", "read"})
	out.Reset()
	if st := CGIDownload(okSid, f, &out); st != StatusOK {
		t.Fatalf("授权 download = %d，期望 0", st)
	}
	if out.String() != "line-a\nline-b\n" {
		t.Errorf("download 内容 = %q", out.String())
	}

	// 授权但不存在 → 4。
	out.Reset()
	if st := CGIDownload(okSid, root+"/work/nope", &out); st != StatusNotFound {
		t.Errorf("不存在文件 download = %d，期望 4", st)
	}
}

func TestCGIIUpload(t *testing.T) {
	root := fileTestRoot(t)
	if err := os.Mkdir(root+"/work", 0o755); err != nil {
		t.Fatal(err)
	}
	target := root + "/work/upload.ipk"

	// 未授权 → 6，且不落盘。
	noSid := fileTestSession(t)
	if st := CGIUpload(noSid, "/tmp/upload.ipk", strings.NewReader("x")); st != StatusPermissionDenied {
		t.Errorf("无授权 upload = %d，期望 6", st)
	}

	// 授权写 → 落盘且内容一致。
	okSid := fileTestSession(t, [2]string{root + "/*", "write"})
	if st := CGIUpload(okSid, target, strings.NewReader("payload")); st != StatusOK {
		t.Fatalf("授权 upload = %d，期望 0", st)
	}
	if got, _ := os.ReadFile(target); string(got) != "payload" {
		t.Errorf("upload 落盘内容 = %q，期望 payload", got)
	}
}
