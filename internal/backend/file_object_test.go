//go:build darwin

package backend

// file 对象的单元测试（对齐 Odin 版 src/backend/file_object.odin 与
// tests/http_smoke.sh 的「P3-4 file 对象」整段在 darwin 上可断言的部分）。
//
// exec 用例依赖 macOS 上 /bin/echo 的存在与 PATH 解析顺序（/usr/bin/echo 不存在），
// 所以整个文件加 darwin tag，与同包的 uci/luci 测试一致。

import (
	"crypto/md5"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

// fileTestRoot 给一个已解析掉符号链接的临时目录（macOS 的 TMPDIR 在 /var 下，
// /var → /private/var，必须先 realpath，否则 ACL 复查会对不上）。
func fileTestRoot(t *testing.T) string {
	t.Helper()
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatalf("解析临时目录失败: %v", err)
	}
	return root
}

// fileTestSession 建一个干净会话，可选地授予 file scope 的 (object,function)。
func fileTestSession(t *testing.T, grants ...[2]string) string {
	t.Helper()
	reply, st := SessionCall("create", `{}`)
	if st != StatusOK {
		t.Fatalf("create 状态 %d，期望 0", st)
	}
	var doc struct {
		Sid string `json:"ubus_rpc_session"`
	}
	if err := json.Unmarshal([]byte(reply), &doc); err != nil {
		t.Fatalf("create 回复解析失败: %v (%s)", err, reply)
	}
	sid := doc.Sid
	if len(grants) > 0 {
		objs := make([][]string, 0, len(grants))
		for _, g := range grants {
			objs = append(objs, []string{g[0], g[1]})
		}
		body, _ := json.Marshal(map[string]any{
			"ubus_rpc_session": sid, "scope": "file", "objects": objs,
		})
		if _, st := SessionCall("grant", string(body)); st != StatusOK {
			t.Fatalf("grant 状态 %d，期望 0", st)
		}
	}
	t.Cleanup(func() {
		b, _ := json.Marshal(map[string]any{"ubus_rpc_session": sid})
		SessionCall("destroy", string(b))
	})
	return sid
}

// fileReq 组装 params（含 sid）后调用 callFile。
func fileReq(t *testing.T, sid, method string, params map[string]any) (string, int) {
	t.Helper()
	body := map[string]any{}
	for k, v := range params {
		body[k] = v
	}
	if sid != "" {
		body["ubus_rpc_session"] = sid
	}
	b, err := json.Marshal(body)
	if err != nil {
		t.Fatalf("marshal params 失败: %v", err)
	}
	return callFile(method, string(b))
}

func fileReply(t *testing.T, reply string) map[string]any {
	t.Helper()
	var d map[string]any
	if err := json.Unmarshal([]byte(reply), &d); err != nil {
		t.Fatalf("reply 解析失败: %v (%q)", err, reply)
	}
	return d
}

func fileInt(t *testing.T, d map[string]any, key string) int {
	t.Helper()
	f, ok := d[key].(float64)
	if !ok {
		t.Fatalf("字段 %q 不是数字: %#v", key, d[key])
	}
	return int(f)
}

// --- 纯函数 -----------------------------------------------------------------

func TestFileCanonicalizePath(t *testing.T) {
	cases := []struct {
		in, want string
		ok       bool
	}{
		{"/tmp/../etc/hosts", "/etc/hosts", true},
		{"//a//b", "/a/b", true},
		{"/a/./b", "/a/b", true},
		{"/a/b/", "/a/b", true},
		{"/", "/", true},
		{"/..", "/", true},
		{"/a/../..", "/", true},
		{"a/b", "a/b", true},
		{"", "", false},
	}
	for _, c := range cases {
		got, ok := fileCanonicalizePath(c.in)
		if ok != c.ok || (ok && got != c.want) {
			t.Errorf("fileCanonicalizePath(%q) = (%q,%v)，期望 (%q,%v)", c.in, got, ok, c.want, c.ok)
		}
	}
}

func TestFileStatusOf(t *testing.T) {
	if got := fileStatusOf(os.ErrNotExist); got != StatusNotFound {
		t.Errorf("NotExist → %d，期望 4", got)
	}
	if got := fileStatusOf(os.ErrPermission); got != StatusPermissionDenied {
		t.Errorf("Permission → %d，期望 6", got)
	}
}

// --- read ------------------------------------------------------------------

func TestFileRead(t *testing.T) {
	root := fileTestRoot(t)
	work := root + "/work"
	if err := os.Mkdir(work, 0o755); err != nil {
		t.Fatal(err)
	}

	// 缺 path → 2（先于 ACL）
	if _, st := fileReq(t, "", "read", nil); st != StatusInvalidArgument {
		t.Errorf("read 缺 path = %d，期望 2", st)
	}

	sid := fileTestSession(t) // 无任何授权
	if _, st := fileReq(t, sid, "read", map[string]any{"path": "/etc/hosts"}); st != StatusPermissionDenied {
		t.Errorf("无权限读 /etc/hosts = %d，期望 6", st)
	}
	// 路径规范化：/tmp/../etc/hosts → /etc/hosts，同样未授权 → 6
	if _, st := fileReq(t, sid, "read", map[string]any{"path": "/tmp/../etc/hosts"}); st != StatusPermissionDenied {
		t.Errorf("规范化后读 /etc/hosts = %d，期望 6", st)
	}

	authSid := fileTestSession(t, [2]string{root + "/*", "read"})

	// 空文件 → 5（NO_DATA）
	empty := work + "/empty.txt"
	if err := os.WriteFile(empty, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	if _, st := fileReq(t, authSid, "read", map[string]any{"path": empty}); st != StatusNoData {
		t.Errorf("读空文件 = %d，期望 5", st)
	}

	f := work + "/probe.txt"
	if err := os.WriteFile(f, []byte("molly-p3-4\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	reply, st := fileReq(t, authSid, "read", map[string]any{"path": f})
	if st != StatusOK {
		t.Fatalf("读授权文件 = %d，期望 0", st)
	}
	if got := fileReply(t, reply)["data"]; got != "molly-p3-4\n" {
		t.Errorf("read data = %#v", got)
	}

	// base64
	reply, st = fileReq(t, authSid, "read", map[string]any{"path": f, "base64": true})
	if st != StatusOK {
		t.Fatalf("base64 读 = %d，期望 0", st)
	}
	wantB64 := base64.StdEncoding.EncodeToString([]byte("molly-p3-4\n"))
	if got := fileReply(t, reply)["data"]; got != wantB64 {
		t.Errorf("base64 read = %#v，期望 %q", got, wantB64)
	}

	// 不存在 → 4
	if _, st := fileReq(t, authSid, "read", map[string]any{"path": work + "/nope"}); st != StatusNotFound {
		t.Errorf("读不存在文件 = %d，期望 4", st)
	}
}

// --- write + md5 -----------------------------------------------------------

func TestFileWriteAndMd5(t *testing.T) {
	root := fileTestRoot(t)
	work := root + "/work"
	if err := os.Mkdir(work, 0o755); err != nil {
		t.Fatal(err)
	}
	sid := fileTestSession(t,
		[2]string{root + "/*", "read"},
		[2]string{root + "/*", "write"},
	)

	f := work + "/new.txt"
	// 缺 data → 2
	if _, st := fileReq(t, sid, "write", map[string]any{"path": f}); st != StatusInvalidArgument {
		t.Errorf("write 缺 data = %d，期望 2", st)
	}
	// 新建
	if _, st := fileReq(t, sid, "write", map[string]any{"path": f, "data": "hello write"}); st != StatusOK {
		t.Errorf("write 新建 = %d，期望 0", st)
	}
	reply, _ := fileReq(t, sid, "read", map[string]any{"path": f})
	if got := fileReply(t, reply)["data"]; got != "hello write" {
		t.Errorf("写回读 = %#v", got)
	}
	// append 不截断
	if _, st := fileReq(t, sid, "write", map[string]any{"path": f, "data": "+more", "append": true}); st != StatusOK {
		t.Errorf("write append = %d，期望 0", st)
	}
	reply, _ = fileReq(t, sid, "read", map[string]any{"path": f})
	if got := fileReply(t, reply)["data"]; got != "hello write+more" {
		t.Errorf("append 后内容 = %#v", got)
	}

	// base64 解码
	b64 := work + "/b64.txt"
	if _, st := fileReq(t, sid, "write", map[string]any{"path": b64, "data": "YjY0LW9r", "base64": true}); st != StatusOK {
		t.Errorf("write base64 = %d，期望 0", st)
	}
	reply, _ = fileReq(t, sid, "read", map[string]any{"path": b64})
	if got := fileReply(t, reply)["data"]; got != "b64-ok" {
		t.Errorf("base64 写回读 = %#v", got)
	}

	// md5（权限名 read）
	probe := work + "/probe.txt"
	if err := os.WriteFile(probe, []byte("molly-p3-4\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	reply, st := fileReq(t, sid, "md5", map[string]any{"path": probe})
	if st != StatusOK {
		t.Fatalf("md5 = %d，期望 0", st)
	}
	wantMd5 := fmt.Sprintf("%x", md5.Sum([]byte("molly-p3-4\n")))
	if got := fileReply(t, reply)["md5"]; got != wantMd5 {
		t.Errorf("md5 = %#v，期望 %s", got, wantMd5)
	}

	// md5 对目录 → 8（上游只认普通文件）
	adir := work + "/adir"
	if err := os.Mkdir(adir, 0o755); err != nil {
		t.Fatal(err)
	}
	if _, st := fileReq(t, sid, "md5", map[string]any{"path": adir}); st != StatusNotSupported {
		t.Errorf("md5 对目录 = %d，期望 8", st)
	}
}

// --- stat / lstat / list ---------------------------------------------------

func TestFileStatLstatList(t *testing.T) {
	root := fileTestRoot(t)
	work := root + "/work"
	if err := os.Mkdir(work, 0o755); err != nil {
		t.Fatal(err)
	}
	sid := fileTestSession(t,
		[2]string{root + "/*", "read"},
		[2]string{root + "/*", "write"},
		[2]string{root + "/*", "list"},
	)

	probe := work + "/probe.txt"
	if err := os.WriteFile(probe, []byte("molly-p3-4\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(probe, 0o644); err != nil {
		t.Fatal(err)
	}
	for _, n := range []string{"new.txt", "b64.txt"} {
		if err := os.WriteFile(work+"/"+n, []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	link := work + "/link"
	if err := os.Symlink("probe.txt", link); err != nil {
		t.Fatal(err)
	}

	// stat：type/size/path + mode 含类型位（0o100644=33188）
	reply, st := fileReq(t, sid, "stat", map[string]any{"path": probe})
	if st != StatusOK {
		t.Fatalf("stat = %d，期望 0", st)
	}
	d := fileReply(t, reply)
	if d["type"] != "file" || fileInt(t, d, "size") != 11 || d["path"] != probe {
		t.Errorf("stat = %#v", d)
	}
	if fileInt(t, d, "mode") != 33188 {
		t.Errorf("stat mode = %v，期望 33188", d["mode"])
	}

	// lstat 符号链接 → symlink（不解析）；stat → 跟随到 file
	reply, _ = fileReq(t, sid, "lstat", map[string]any{"path": link})
	if got := fileReply(t, reply)["type"]; got != "symlink" {
		t.Errorf("lstat link type = %#v，期望 symlink", got)
	}
	reply, _ = fileReq(t, sid, "stat", map[string]any{"path": link})
	if got := fileReply(t, reply)["type"]; got != "file" {
		t.Errorf("stat link type = %#v，期望 file", got)
	}

	// list：条目齐（. / .. 被跳过）
	reply, st = fileReq(t, sid, "list", map[string]any{"path": work})
	if st != StatusOK {
		t.Fatalf("list = %d，期望 0", st)
	}
	entries, ok := fileReply(t, reply)["entries"].([]any)
	if !ok {
		t.Fatalf("entries 不是数组: %#v", fileReply(t, reply)["entries"])
	}
	names := make([]string, 0, len(entries))
	var linkEntry map[string]any
	for _, e := range entries {
		em := e.(map[string]any)
		names = append(names, em["name"].(string))
		if em["name"] == "link" {
			linkEntry = em
		}
	}
	sort.Strings(names)
	if got := strings.Join(names, ","); got != "b64.txt,link,new.txt,probe.txt" {
		t.Errorf("list 条目 = %q", got)
	}
	// 符号链接条目带 target（name+type）
	if linkEntry == nil {
		t.Fatalf("list 缺 link 条目")
	}
	target, ok := linkEntry["target"].(map[string]any)
	if !ok {
		t.Fatalf("link 缺 target: %#v", linkEntry)
	}
	if target["name"] != "probe.txt" || target["type"] != "file" {
		t.Errorf("link target = %#v", target)
	}

	// list 对普通文件 → 2（opendir ENOTDIR）
	if _, st := fileReq(t, sid, "list", map[string]any{"path": probe}); st != StatusInvalidArgument {
		t.Errorf("list 普通文件 = %d，期望 2", st)
	}
	// list 不存在的目录 → 4
	if _, st := fileReq(t, sid, "list", map[string]any{"path": work + "/nope"}); st != StatusNotFound {
		t.Errorf("list 不存在目录 = %d，期望 4", st)
	}
}

// --- 权限名各不相同 ---------------------------------------------------------

func TestFilePermissionNames(t *testing.T) {
	root := fileTestRoot(t)
	work := root + "/work"
	if err := os.Mkdir(work, 0o755); err != nil {
		t.Fatal(err)
	}
	probe := work + "/probe.txt"
	if err := os.WriteFile(probe, []byte("molly-p3-4\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	// 只授 read+write（不授 list）：md5/read/write 放行，stat/list（"list"）被拒
	sid := fileTestSession(t,
		[2]string{root + "/*", "read"},
		[2]string{root + "/*", "write"},
	)
	if _, st := fileReq(t, sid, "stat", map[string]any{"path": probe}); st != StatusPermissionDenied {
		t.Errorf("stat（list 权限）无授权 = %d，期望 6", st)
	}
	if _, st := fileReq(t, sid, "list", map[string]any{"path": work}); st != StatusPermissionDenied {
		t.Errorf("list 无授权 = %d，期望 6", st)
	}
	if _, st := fileReq(t, sid, "read", map[string]any{"path": probe}); st != StatusOK {
		t.Errorf("read 有授权 = %d，期望 0", st)
	}
	if _, st := fileReq(t, sid, "md5", map[string]any{"path": probe}); st != StatusOK {
		t.Errorf("md5 有授权 = %d，期望 0", st)
	}

	// 清空 file scope → read 也变 6
	body, _ := json.Marshal(map[string]any{"ubus_rpc_session": sid, "scope": "file"})
	if _, st := SessionCall("revoke", string(body)); st != StatusOK {
		t.Fatalf("revoke 状态 %d", st)
	}
	if _, st := fileReq(t, sid, "read", map[string]any{"path": probe}); st != StatusPermissionDenied {
		t.Errorf("清空 scope 后 read = %d，期望 6", st)
	}
}

// --- remove ----------------------------------------------------------------

func TestFileRemove(t *testing.T) {
	root := fileTestRoot(t)
	work := root + "/work"
	if err := os.Mkdir(work, 0o755); err != nil {
		t.Fatal(err)
	}
	sid := fileTestSession(t,
		[2]string{root + "/*", "read"},
		[2]string{root + "/*", "write"},
		[2]string{root + "/*", "list"},
	)

	f := work + "/new.txt"
	if err := os.WriteFile(f, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, st := fileReq(t, sid, "remove", map[string]any{"path": f}); st != StatusOK {
		t.Errorf("remove 文件 = %d，期望 0", st)
	}
	if _, st := fileReq(t, sid, "read", map[string]any{"path": f}); st != StatusNotFound {
		t.Errorf("remove 后 read = %d，期望 4", st)
	}

	// 递归删除目录
	dir := work + "/rmdir"
	if err := os.MkdirAll(dir+"/sub", 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(dir+"/sub/child.txt", []byte("y"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, st := fileReq(t, sid, "remove", map[string]any{"path": dir}); st != StatusOK {
		t.Errorf("remove 目录 = %d，期望 0", st)
	}
	if _, st := fileReq(t, sid, "stat", map[string]any{"path": dir}); st != StatusNotFound {
		t.Errorf("remove 后 stat = %d，期望 4", st)
	}
}

// --- 符号链接复查防退化 ------------------------------------------------------

func TestFileSymlinkEscape(t *testing.T) {
	root := fileTestRoot(t)
	sid := fileTestSession(t, [2]string{root + "/*", "read"})

	escape := root + "/escape"
	if err := os.Symlink("/etc/hosts", escape); err != nil {
		t.Fatal(err)
	}
	// 链接在授权目录里但指向外 → 6
	if _, st := fileReq(t, sid, "read", map[string]any{"path": escape}); st != StatusPermissionDenied {
		t.Errorf("符号链接指向授权外 = %d，期望 6", st)
	}
}

// --- exec ------------------------------------------------------------------

func TestFileExecACL(t *testing.T) {
	// 带 env + 会话 → 6（先于 ACL/查找）
	sid := fileTestSession(t)
	if _, st := fileReq(t, sid, "exec", map[string]any{"command": "echo", "env": map[string]any{"A": "1"}}); st != StatusPermissionDenied {
		t.Errorf("exec 带 env + 会话 = %d，期望 6", st)
	}
	// 未授权 → 6（ACL 查 PATH 解析后的可执行文件路径）
	if _, st := fileReq(t, sid, "exec", map[string]any{"command": "echo"}); st != StatusPermissionDenied {
		t.Errorf("exec 未授权 = %d，期望 6", st)
	}
	// 不存在的命令 → 4
	if _, st := fileReq(t, sid, "exec", map[string]any{"command": "molly-definitely-not-here"}); st != StatusNotFound {
		t.Errorf("exec 不存在命令 = %d，期望 4", st)
	}
	// 缺 command → 2
	if _, st := fileReq(t, sid, "exec", nil); st != StatusInvalidArgument {
		t.Errorf("exec 缺 command = %d，期望 2", st)
	}

	// 授权 /bin/echo（路径对象）→ code 0 + stdout
	exeSid := fileTestSession(t, [2]string{"/bin/echo", "exec"})
	reply, st := fileReq(t, exeSid, "exec", map[string]any{"command": "echo", "params": []any{"hello exec"}})
	if st != StatusOK {
		t.Fatalf("exec echo = %d，期望 0", st)
	}
	d := fileReply(t, reply)
	if fileInt(t, d, "code") != 0 || strings.TrimSpace(fmt.Sprint(d["stdout"])) != "hello exec" {
		t.Errorf("exec echo 回复 = %#v", d)
	}

	// 第二种授权形态：整条命令行字符串（file.c:1081）
	cmdSid := fileTestSession(t, [2]string{"/bin/echo only-this", "exec"})
	reply, st = fileReq(t, cmdSid, "exec", map[string]any{"command": "echo", "params": []any{"only-this"}})
	if st != StatusOK {
		t.Fatalf("命令行 ACL 精确匹配 = %d，期望 0", st)
	}
	if got := strings.TrimSpace(fmt.Sprint(fileReply(t, reply)["stdout"])); got != "only-this" {
		t.Errorf("命令行 ACL stdout = %q", got)
	}
	if _, st := fileReq(t, cmdSid, "exec", map[string]any{"command": "echo", "params": []any{"other"}}); st != StatusPermissionDenied {
		t.Errorf("命令行 ACL 参数不同 = %d，期望 6", st)
	}
}
