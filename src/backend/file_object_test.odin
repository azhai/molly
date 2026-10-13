package backend

// file 对象的单元测试（移植 internal/backend/file_object_test.go 在 darwin 上可断言的部分）。
//
// 与 Go 版差异：Odin 无 t.TempDir()/t.Cleanup，改用 os.temp_directory + file_realpath 解析
// 软链（macOS TMPDIR 在 /var 下，/var → /private/var，必须先 realpath，否则 ACL 复查对不上），
// 每个用例末尾用 file_remove_recursive（空 sid 绕开 ACL）清理。
// exec 用例依赖 macOS 上 /bin/echo 与 PATH 解析顺序（本机 /usr/bin/echo 不存在）。

import "core:testing"
import "core:mem"
import "core:fmt"
import "core:os"
import "core:sort"
import "core:strings"
import "core:encoding/json"
import "core:sys/posix"

// ---------------------------------------------------------------------------
// 助手
// ---------------------------------------------------------------------------

F_Grant :: struct { object: string, function: string }

// bstr —— string → []u8（同布局；transmute 需作用于已定型值，故走过程形参）。
bstr :: proc(s: string) -> []u8 {
	return transmute([]u8)s
}

// fj —— 拼接路径片段（Odin 的 + 只允许常量字符串，非恒定量得走 tprintf）。
fj :: proc(a, b: string) -> string {
	return fmt.tprintf("%s%s", a, b)
}

// file_test_counter —— 每个用例一个独立子目录，避免用例间互相清理（os.temp_directory 只返回
// 共享的 TMPDIR，若直接当 root 用，第一个用例的 file_test_cleanup 会把整个 TMPDIR 删掉）。
file_test_counter : int = 0

// file_test_root —— 在 TMPDIR 下建唯一子目录并解软链（macOS /var→/private/var），返回绝对根。
file_test_root :: proc(t: ^testing.T, alloc: mem.Allocator) -> string {
	tmp, err := os.temp_directory(alloc)
	testing.expectf(t, err == nil, "temp_directory 失败: %v", err)
	for {
		if len(tmp) <= 1 || tmp[len(tmp)-1] != '/' {
			break
		}
		tmp = tmp[:len(tmp)-1]
	}
	file_test_counter += 1
	sub := fmt.tprintf("%s/molly_ft_%d", tmp, file_test_counter)
	mkerr := os.make_directory_all(sub)
	testing.expectf(t, mkerr == nil, "创建测试子目录 %s 失败: %v", sub, mkerr)
	root, ok := file_realpath(sub)
	testing.expectf(t, ok, "realpath 测试子目录失败: %s", sub)
	return root
}

// file_test_session —— 建干净会话，逐个授予 file scope 的 (object, function)。
file_test_session :: proc(t: ^testing.T, alloc: mem.Allocator, grants: []F_Grant) -> string {
	st, reply := Dispatch(alloc, "session", "create", "{}")
	testing.expectf(t, st == Status_OK, "create 状态 %d，期望 0", st)
	sid, ok := reply_str_field(t, alloc, reply, "ubus_rpc_session")
	testing.expectf(t, ok, "create 回复带 ubus_rpc_session（实得 %q）", reply)
	for g in grants {
		gp := fmt.tprintf(`{{"ubus_rpc_session":"%s","scope":"file","objects":[["%s","%s"]]}}`, sid, g.object, g.function)
		gst, _ := Dispatch(alloc, "session", "grant", gp)
		testing.expectf(t, gst == Status_OK, "grant(%s,%s) 状态 %d，期望 0", g.object, g.function, gst)
	}
	return sid
}

// file_req —— 组装 params（含/不含 sid）后派发。body 是花括号内的字段串（不含外层 {}）。
// 返回 (状态码, 回复)。注意：状态码在**第一个**返回值。
file_req :: proc(t: ^testing.T, alloc: mem.Allocator, sid, method, body: string) -> (i32, string) {
	params: string
	if len(sid) > 0 {
		if len(body) > 0 {
			params = fmt.tprintf(`{{"ubus_rpc_session":"%s",%s}}`, sid, body)
		} else {
			params = fmt.tprintf(`{{"ubus_rpc_session":"%s"}}`, sid)
		}
	} else {
		if len(body) > 0 {
			params = fmt.tprintf(`{{%s}}`, body)
		} else {
			params = "{}"
		}
	}
	_ = t
	return Dispatch(alloc, "file", method, params)
}

path_body :: proc(path: string) -> string {
	return fmt.tprintf(`"path":"%s"`, path)
}

// file_reply_obj —— 解析回复为对象。
file_reply_obj :: proc(t: ^testing.T, alloc: mem.Allocator, reply: string) -> json.Object {
	v, err := json.parse_string(reply, .JSON, true, alloc)
	if err != nil {
		testing.expectf(t, false, "reply 解析失败: %v (%q)", err, reply)
		return nil
	}
	o, ok := v.(json.Object)
	testing.expectf(t, ok, "reply 不是对象: %q", reply)
	return o
}

file_get_str :: proc(t: ^testing.T, alloc: mem.Allocator, reply, key: string) -> (string, bool) {
	o := file_reply_obj(t, alloc, reply)
	if o == nil {
		return "", false
	}
	v, has := o[key]
	if !has {
		return "", false
	}
	s, is_str := v.(json.String)
	return string(s), is_str
}

file_get_int :: proc(t: ^testing.T, alloc: mem.Allocator, reply, key: string) -> (int, bool) {
	o := file_reply_obj(t, alloc, reply)
	if o == nil {
		return 0, false
	}
	v, has := o[key]
	if !has {
		return 0, false
	}
	if n, ok := v.(json.Integer); ok {
		return int(n), true
	}
	if f, ok := v.(json.Float); ok {
		return int(f), true
	}
	testing.expectf(t, false, "字段 %q 不是数字: %#v", key, v)
	return 0, false
}

file_test_mkfile :: proc(t: ^testing.T, path, content: string) {
	err := os.write_entire_file(path, content)
	testing.expectf(t, err == nil, "写测试文件 %s 失败: %v", path, err)
}

file_test_mkdir :: proc(t: ^testing.T, path: string) {
	err := os.make_directory(path)
	testing.expectf(t, err == nil, "mkdir %s 失败: %v", path, err)
}

file_test_cleanup :: proc(root: string) {
	file_remove_recursive("", root)
}

// ---------------------------------------------------------------------------
// 纯函数
// ---------------------------------------------------------------------------

@(test)
test_file_canonicalize_path :: proc(t: ^testing.T) {
	backing: [262144]u8
	ar: mem.Arena
	mem.arena_init(&ar, backing[:])
	context.allocator = mem.arena_allocator(&ar)

	cases := []struct { input, want: string, ok: bool }{
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
	for c in cases {
		got, ok := file_canonicalize_path(c.input)
		testing.expectf(t, ok == c.ok && (ok == false || got == c.want),
			"file_canonicalize_path(%q) = (%q,%v)，期望 (%q,%v)", c.input, got, ok, c.want, c.ok)
	}
}

@(test)
test_file_status_of_errno :: proc(t: ^testing.T) {
	testing.expect_value(t, file_status_of_errno(.ENOENT), Status_Not_Found)
	testing.expect_value(t, file_status_of_errno(.EACCES), Status_Permission_Denied)
	testing.expect_value(t, file_status_of_errno(.ENOTDIR), Status_Invalid_Argument)
	testing.expect_value(t, file_status_of_errno(.NONE), Status_OK)
	testing.expect_value(t, file_status_of_errno(.EIO), Status_Unknown_Error)
}

// md5 独立自测：用 RFC 1321 已知向量，避免与实现自证。
@(test)
test_file_md5_vectors :: proc(t: ^testing.T) {
	backing: [262144]u8
	ar: mem.Arena
	mem.arena_init(&ar, backing[:])
	context.allocator = mem.arena_allocator(&ar)

	testing.expect_value(t, md5_hex(bstr("")), "d41d8cd98f00b204e9800998ecf8427e")
	testing.expect_value(t, md5_hex(bstr("abc")), "900150983cd24fb0d6963f7d28e17f72")
	testing.expect_value(t, md5_hex(bstr("molly-p3-4\n")), "77b943886b5f106167f1f082a1f0528e")
}

// ---------------------------------------------------------------------------
// read
// ---------------------------------------------------------------------------

@(test)
test_file_read :: proc(t: ^testing.T) {
	backing: [262144]u8
	ar: mem.Arena
	mem.arena_init(&ar, backing[:])
	context.allocator = mem.arena_allocator(&ar)
	alloc := context.allocator

	root := file_test_root(t, alloc)
	defer file_test_cleanup(root)
	work := fj(root, "/work")
	file_test_mkdir(t, work)

	// 缺 path → 2（先于 ACL）
	st, _ := file_req(t, alloc, "", "read", "")
	testing.expect_value(t, st, Status_Invalid_Argument)

	sid := file_test_session(t, alloc, nil) // 无任何授权
	st, _ = file_req(t, alloc, sid, "read", path_body("/etc/hosts"))
	testing.expect_value(t, st, Status_Permission_Denied)
	st, _ = file_req(t, alloc, sid, "read", path_body("/tmp/../etc/hosts"))
	testing.expect_value(t, st, Status_Permission_Denied)

	auth_sid := file_test_session(t, alloc, []F_Grant{F_Grant{fj(root, "/*"), "read"}})

	// 空文件 → 5（NO_DATA）
	empty := fj(work, "/empty.txt")
	file_test_mkfile(t, empty, "")
	st, _ = file_req(t, alloc, auth_sid, "read", path_body(empty))
	testing.expect_value(t, st, Status_No_Data)

	f := fj(work, "/probe.txt")
	file_test_mkfile(t, f, "molly-p3-4\n")
	reply: string
	st, reply = file_req(t, alloc, auth_sid, "read", path_body(f))
	testing.expect_value(t, st, Status_OK)
	data, ok := file_get_str(t, alloc, reply, "data")
	testing.expectf(t, ok && data == "molly-p3-4\n", "read data = %q", data)

	// base64
	st, reply = file_req(t, alloc, auth_sid, "read", fmt.tprintf(`"path":"%s","base64":true`, f))
	testing.expect_value(t, st, Status_OK)
	data, ok = file_get_str(t, alloc, reply, "data")
	testing.expectf(t, ok && data == "bW9sbHktcDMtNAo=", "base64 read = %q", data)

	// 不存在 → 4
	st, _ = file_req(t, alloc, auth_sid, "read", path_body(fj(work, "/nope")))
	testing.expect_value(t, st, Status_Not_Found)
}

// ---------------------------------------------------------------------------
// write + md5
// ---------------------------------------------------------------------------

@(test)
test_file_write_and_md5 :: proc(t: ^testing.T) {
	backing: [262144]u8
	ar: mem.Arena
	mem.arena_init(&ar, backing[:])
	context.allocator = mem.arena_allocator(&ar)
	alloc := context.allocator

	root := file_test_root(t, alloc)
	defer file_test_cleanup(root)
	work := fj(root, "/work")
	file_test_mkdir(t, work)

	star := fj(root, "/*")
	grants := []F_Grant{F_Grant{star, "read"}, F_Grant{star, "write"}}
	sid := file_test_session(t, alloc, grants)

	f := fj(work, "/new.txt")
	// 缺 data → 2
	st, _ := file_req(t, alloc, sid, "write", path_body(f))
	testing.expect_value(t, st, Status_Invalid_Argument)

	// 新建
	st, _ = file_req(t, alloc, sid, "write", fmt.tprintf(`"path":"%s","data":"hello write"`, f))
	testing.expect_value(t, st, Status_OK)
	_, reply := file_req(t, alloc, sid, "read", path_body(f))
	data, _ := file_get_str(t, alloc, reply, "data")
	testing.expect_value(t, data, "hello write")

	// append 不截断
	st, _ = file_req(t, alloc, sid, "write", fmt.tprintf(`"path":"%s","data":"+more","append":true`, f))
	testing.expect_value(t, st, Status_OK)
	_, reply = file_req(t, alloc, sid, "read", path_body(f))
	data, _ = file_get_str(t, alloc, reply, "data")
	testing.expect_value(t, data, "hello write+more")

	// base64 解码写
	b64 := fj(work, "/b64.txt")
	st, _ = file_req(t, alloc, sid, "write", fmt.tprintf(`"path":"%s","data":"YjY0LW9r","base64":true`, b64))
	testing.expect_value(t, st, Status_OK)
	_, reply = file_req(t, alloc, sid, "read", path_body(b64))
	data, _ = file_get_str(t, alloc, reply, "data")
	testing.expect_value(t, data, "b64-ok")

	// md5（权限名 read）
	probe := fj(work, "/probe.txt")
	file_test_mkfile(t, probe, "molly-p3-4\n")
	st, reply = file_req(t, alloc, sid, "md5", path_body(probe))
	testing.expect_value(t, st, Status_OK)
	md, ok := file_get_str(t, alloc, reply, "md5")
	testing.expectf(t, ok && md == "77b943886b5f106167f1f082a1f0528e", "md5 = %q", md)

	// md5 对目录 → 8
	adir := fj(work, "/adir")
	file_test_mkdir(t, adir)
	st, _ = file_req(t, alloc, sid, "md5", path_body(adir))
	testing.expect_value(t, st, Status_Not_Supported)
}

// ---------------------------------------------------------------------------
// stat / lstat / list
// ---------------------------------------------------------------------------

@(test)
test_file_stat_lstat_list :: proc(t: ^testing.T) {
	backing: [262144]u8
	ar: mem.Arena
	mem.arena_init(&ar, backing[:])
	context.allocator = mem.arena_allocator(&ar)
	alloc := context.allocator

	root := file_test_root(t, alloc)
	defer file_test_cleanup(root)
	work := fj(root, "/work")
	file_test_mkdir(t, work)

	star := fj(root, "/*")
	grants := []F_Grant{
		F_Grant{star, "read"},
		F_Grant{star, "write"},
		F_Grant{star, "list"},
	}
	sid := file_test_session(t, alloc, grants)

	probe := fj(work, "/probe.txt")
	file_test_mkfile(t, probe, "molly-p3-4\n")
	rc := posix.chmod(file_cstr(probe), file_mode_from_bits(0o644))
	testing.expectf(t, rc == .OK, "chmod 0644 失败: %s", probe)
	extras := [2]string{"new.txt", "b64.txt"}
	for n in extras {
		file_test_mkfile(t, fmt.tprintf("%s/%s", work, n), "x")
	}
	link := fj(work, "/link")
	lerr := os.symlink("probe.txt", link)
	testing.expectf(t, lerr == nil, "symlink 失败: %v", lerr)

	// stat：type/size/path + mode 含类型位（0o100644 = 33188）
	st: i32
	reply: string
	st, reply = file_req(t, alloc, sid, "stat", path_body(probe))
	testing.expect_value(t, st, Status_OK)
	typ, _ := file_get_str(t, alloc, reply, "type")
	size, _ := file_get_int(t, alloc, reply, "size")
	gpath, _ := file_get_str(t, alloc, reply, "path")
	mode, _ := file_get_int(t, alloc, reply, "mode")
	testing.expect_value(t, typ, "file")
	testing.expect_value(t, size, 11)
	testing.expect_value(t, gpath, probe)
	testing.expectf(t, mode == 33188, "stat mode = %d，期望 33188", mode)

	// lstat 符号链接 → symlink（不解析）；stat → 跟随到 file
	st, reply = file_req(t, alloc, sid, "lstat", path_body(link))
	typ, _ = file_get_str(t, alloc, reply, "type")
	testing.expect_value(t, typ, "symlink")
	st, reply = file_req(t, alloc, sid, "stat", path_body(link))
	typ, _ = file_get_str(t, alloc, reply, "type")
	testing.expect_value(t, typ, "file")

	// list：条目齐（. / .. 被跳过）
	st, reply = file_req(t, alloc, sid, "list", path_body(work))
	testing.expect_value(t, st, Status_OK)
	o := file_reply_obj(t, alloc, reply)
	arr, is_arr := o["entries"].(json.Array)
	testing.expectf(t, is_arr, "entries 不是数组: %#v", o["entries"])
	names := make([dynamic]string)
	link_target_name := ""
	link_target_type := ""
	for ev in arr {
		em, ok := ev.(json.Object)
		if !ok {
			continue
		}
		nm, is_n := em["name"].(json.String)
		if !is_n {
			continue
		}
		append(&names, string(nm))
		if string(nm) == "link" {
			if tv, is_t := em["target"].(json.Object); is_t {
				tn, _ := tv["name"].(json.String)
				tt, _ := tv["type"].(json.String)
				link_target_name = string(tn)
				link_target_type = string(tt)
			}
		}
	}
	sort.quick_sort(names[:])
	joined, _ := strings.join(names[:], ",")
	testing.expectf(t, joined == "b64.txt,link,new.txt,probe.txt", "list 条目 = %q", joined)
	// 符号链接条目带 target（name + type）
	testing.expect_value(t, link_target_name, "probe.txt")
	testing.expect_value(t, link_target_type, "file")

	// list 对普通文件 → 2（opendir ENOTDIR）
	st, _ = file_req(t, alloc, sid, "list", path_body(probe))
	testing.expect_value(t, st, Status_Invalid_Argument)
	// list 不存在的目录 → 4
	st, _ = file_req(t, alloc, sid, "list", path_body(fj(work, "/nope")))
	testing.expect_value(t, st, Status_Not_Found)
}

// ---------------------------------------------------------------------------
// 权限名各不相同
// ---------------------------------------------------------------------------

@(test)
test_file_permission_names :: proc(t: ^testing.T) {
	backing: [262144]u8
	ar: mem.Arena
	mem.arena_init(&ar, backing[:])
	context.allocator = mem.arena_allocator(&ar)
	alloc := context.allocator

	root := file_test_root(t, alloc)
	defer file_test_cleanup(root)
	work := fj(root, "/work")
	file_test_mkdir(t, work)
	probe := fj(work, "/probe.txt")
	file_test_mkfile(t, probe, "molly-p3-4\n")

	star := fj(root, "/*")
	// 只授 read+write（不授 list）：read/md5 放行，stat/list（"list" 权限）被拒
	sid := file_test_session(t, alloc, []F_Grant{
		F_Grant{star, "read"},
		F_Grant{star, "write"},
	})
	st, _ := file_req(t, alloc, sid, "stat", path_body(probe))
	testing.expect_value(t, st, Status_Permission_Denied)
	st, _ = file_req(t, alloc, sid, "list", path_body(work))
	testing.expect_value(t, st, Status_Permission_Denied)
	st, _ = file_req(t, alloc, sid, "read", path_body(probe))
	testing.expect_value(t, st, Status_OK)
	st, _ = file_req(t, alloc, sid, "md5", path_body(probe))
	testing.expect_value(t, st, Status_OK)

	// 清空 file scope → read 也变 6
	revoke_params := fmt.tprintf(`{{"ubus_rpc_session":"%s","scope":"file"}}`, sid)
	rst, _ := Dispatch(alloc, "session", "revoke", revoke_params)
	testing.expect_value(t, rst, Status_OK)
	st, _ = file_req(t, alloc, sid, "read", path_body(probe))
	testing.expect_value(t, st, Status_Permission_Denied)
}

// ---------------------------------------------------------------------------
// remove
// ---------------------------------------------------------------------------

@(test)
test_file_remove :: proc(t: ^testing.T) {
	backing: [262144]u8
	ar: mem.Arena
	mem.arena_init(&ar, backing[:])
	context.allocator = mem.arena_allocator(&ar)
	alloc := context.allocator

	root := file_test_root(t, alloc)
	defer file_test_cleanup(root)
	work := fj(root, "/work")
	file_test_mkdir(t, work)
	star := fj(root, "/*")
	sid := file_test_session(t, alloc, []F_Grant{
		F_Grant{star, "read"},
		F_Grant{star, "write"},
		F_Grant{star, "list"},
	})

	f := fj(work, "/new.txt")
	file_test_mkfile(t, f, "x")
	st, _ := file_req(t, alloc, sid, "remove", path_body(f))
	testing.expect_value(t, st, Status_OK)
	st, _ = file_req(t, alloc, sid, "read", path_body(f))
	testing.expect_value(t, st, Status_Not_Found)

	// 递归删除目录
	dir := fj(work, "/rmdir")
	err := os.make_directory_all(fj(dir, "/sub"))
	testing.expectf(t, err == nil, "mkdir_all 失败: %v", err)
	file_test_mkfile(t, fj(dir, "/sub/child.txt"), "y")
	st, _ = file_req(t, alloc, sid, "remove", path_body(dir))
	testing.expect_value(t, st, Status_OK)
	st, _ = file_req(t, alloc, sid, "stat", path_body(dir))
	testing.expect_value(t, st, Status_Not_Found)
}

// ---------------------------------------------------------------------------
// 符号链接复查防退化
// ---------------------------------------------------------------------------

@(test)
test_file_symlink_escape :: proc(t: ^testing.T) {
	backing: [262144]u8
	ar: mem.Arena
	mem.arena_init(&ar, backing[:])
	context.allocator = mem.arena_allocator(&ar)
	alloc := context.allocator

	root := file_test_root(t, alloc)
	defer file_test_cleanup(root)
	star := fj(root, "/*")
	sid := file_test_session(t, alloc, []F_Grant{F_Grant{star, "read"}})

	escape := fj(root, "/escape")
	err := os.symlink("/etc/hosts", escape)
	testing.expectf(t, err == nil, "symlink 失败: %v", err)
	// 链接在授权目录里但指向外 → 6
	st, _ := file_req(t, alloc, sid, "read", path_body(escape))
	testing.expect_value(t, st, Status_Permission_Denied)
}

// ---------------------------------------------------------------------------
// exec
// ---------------------------------------------------------------------------

@(test)
test_file_exec_acl :: proc(t: ^testing.T) {
	backing: [262144]u8
	ar: mem.Arena
	mem.arena_init(&ar, backing[:])
	context.allocator = mem.arena_allocator(&ar)
	alloc := context.allocator

	// 带 env + 会话 → 6（先于 ACL/查找）
	sid := file_test_session(t, alloc, nil)
	env_body := `"command":"echo","env":{"A":"1"}` // 静态串，不经 tprintf → 花括号安全
	st, _ := file_req(t, alloc, sid, "exec", env_body)
	testing.expect_value(t, st, Status_Permission_Denied)

	// 未授权 → 6（ACL 查 PATH 解析后的可执行文件路径）
	st, _ = file_req(t, alloc, sid, "exec", `"command":"echo"`)
	testing.expect_value(t, st, Status_Permission_Denied)

	// 不存在的命令 → 4
	st, _ = file_req(t, alloc, sid, "exec", `"command":"molly-definitely-not-here"`)
	testing.expect_value(t, st, Status_Not_Found)

	// 缺 command → 2
	st, _ = file_req(t, alloc, sid, "exec", "")
	testing.expect_value(t, st, Status_Invalid_Argument)

	// 授权 /bin/echo（路径对象）→ code 0 + stdout
	exe_sid := file_test_session(t, alloc, []F_Grant{F_Grant{"/bin/echo", "exec"}})
	reply: string
	st, reply = file_req(t, alloc, exe_sid, "exec", `"command":"echo","params":["hello exec"]`)
	testing.expect_value(t, st, Status_OK)
	code, _ := file_get_int(t, alloc, reply, "code")
	out, ok := file_get_str(t, alloc, reply, "stdout")
	testing.expect_value(t, code, 0)
	testing.expectf(t, ok && strings.trim_space(out) == "hello exec", "exec echo stdout = %q", out)

	// 第二种授权形态：整条命令行字符串（file.c:1081）
	cmd_sid := file_test_session(t, alloc, []F_Grant{F_Grant{"/bin/echo only-this", "exec"}})
	st, reply = file_req(t, alloc, cmd_sid, "exec", `"command":"echo","params":["only-this"]`)
	testing.expect_value(t, st, Status_OK)
	out, _ = file_get_str(t, alloc, reply, "stdout")
	testing.expectf(t, strings.trim_space(out) == "only-this", "命令行 ACL stdout = %q", out)
	st, _ = file_req(t, alloc, cmd_sid, "exec", `"command":"echo","params":["other"]`)
	testing.expect_value(t, st, Status_Permission_Denied)
}
