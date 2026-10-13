package backend

// file —— molly 自持的 ubus 对象（逐段对齐 internal/backend/file_object.go，后者对照
// rpcd@e37ed9d8 的 file.c）。
//
// 8 个方法（file.c:1227-1234 方法表）：read / write / list / lstat / stat / md5 / remove / exec。
// 平台无关：直接用 posix 系统调用（stat/lstat/opendir/readlink/realpath/unlink/rmdir/open…），
// darwin 与 linux 共用同一份（file 不是平台 provider）。
//
// 权限名按方法各不相同（上游照抄）：read/md5→"read"，write/remove→"write"，
// list/stat/lstat→"list"，exec→"exec"。
//
// 安全要点：路径 ACL 按**文本**匹配，所以顺序是（file.c:261-359）：
//   1) 文本规范化（//、/./、/../、结尾 /）；
//   2) 用规范化路径查 ACL；
//   3) realpath 解一次符号链接；解析结果不同就对**解析后**路径再查一遍并改用它。
// 不做第 3 步：「ACL 授权 /tmp/x/、里面有指向 /etc/shadow 的软链」就能越权读。
//
// 偏离（见 docs/interfaces.md §9.3）：stat 回复省略 uid/gid/user/group；exec 同步实现
// （上游 uloop 异步回包，可观测行为一致）。exec 的 120s 超时在宿主同步执行下不启用，
// 延迟回滚/看门狗线程留给阶段 3h 的 linux 运行期接入。

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:c"
import "core:encoding/json"
import "core:encoding/base64"
import "core:sys/posix"

file_max_size      :: 4096 * 64      // file.c:43-46 读上限（>= 则 8）
file_exec_cmdline_max :: 1024        // file.c:49 整条命令行 ACL 对象上限
file_exec_max_args    :: 255         // file.c:1073 参数个数上限
file_exec_output_cap  :: 64 * 1024   // 输出缓冲上限（满 → 8）
file_path_max         :: 4096        // readlink/realpath 缓冲

file_s_ifmt :: 0o170000 // 类型位掩码（与上游 st_mode 对齐）

// file_mode_u32 —— 便携地把 mode_t(bit_set) 读成原始整数（macOS u16 / linux u32，按字节取）。
file_mode_u32 :: proc(m: posix.mode_t) -> u32 {
	mm := m
	res: u32 = 0
	p := cast([^]u8)&mm
	for i := 0; i < size_of(posix.mode_t); i += 1 {
		res |= cast(u32)p[i] << cast(u32)(i*8)
	}
	return res
}

// file_mode_from_bits —— 反向：把原始权限位（如 0o666）拼成 mode_t 传给 open(2)。
file_mode_from_bits :: proc(bits: u32) -> posix.mode_t {
	m: posix.mode_t = {}
	p := cast([^]u8)&m
	v := cast(u64)bits
	for i := 0; i < size_of(posix.mode_t); i += 1 {
		p[i] = cast(u8)(v >> cast(u64)(i*8))
	}
	return m
}

// ---------------------------------------------------------------------------
// 小工具
// ---------------------------------------------------------------------------

file_cstr :: proc(s: string) -> cstring {
	return strings.clone_to_cstring(s) // context.allocator，NUL 结尾
}

// file_status_of_errno —— file.c:157-177 rpc_errno_status 的等价映射。
file_status_of_errno :: proc(e: posix.Errno) -> i32 {
	#partial switch e {
	case .NONE:   return Status_OK
	case .ENOENT: return Status_Not_Found
	case .EACCES: return Status_Permission_Denied
	case .ENOTDIR, .EINVAL: return Status_Invalid_Argument
	}
	return Status_Unknown_Error
}

// ---------------------------------------------------------------------------
// 路径规范化 / realpath / readlink（file.c:189-248）
// ---------------------------------------------------------------------------

// file_canonicalize_path —— 纯文本折叠：重复 `/`、`/./`、结尾 `/`（根除外）。
// `/../` 只在 `..` 之后是 `/` 或结尾时才折叠。空路径 → false。
file_canonicalize_path :: proc(path: string) -> (string, bool) {
	if len(path) == 0 {
		return "", false
	}
	buf := make([]u8, len(path))
	cp := 0
	p := 0
	for p < len(path) {
		if path[p] != '/' {
			buf[cp] = path[p]
			cp += 1
			p += 1
			continue
		}
		// 重复的 `/`
		if p+1 < len(path) && path[p+1] == '/' {
			p += 1
			continue
		}
		if p+1 < len(path) && path[p+1] == '.' {
			// `/./`
			if p+2 == len(path) || path[p+2] == '/' {
				p += 2
				continue
			}
			// `/../`：游标回退到上一个 `/`
			if p+2 < len(path) && path[p+2] == '.' && (p+3 == len(path) || path[p+3] == '/') {
				for cp > 0 {
					cp -= 1
					if buf[cp] == '/' {
						break
					}
				}
				p += 3
				continue
			}
		}
		buf[cp] = path[p]
		cp += 1
		p += 1
	}
	// 去掉结尾 `/`（根除外）；空串补成 `/`
	if cp > 1 && buf[cp-1] == '/' {
		cp -= 1
	} else if cp == 0 {
		return "/", true
	}
	s, _ := strings.clone(string(buf[:cp]))
	return s, true
}

// file_realpath —— realpath(3)：解析符号链接后的绝对路径；失败（含目标不存在）返回 false。
file_realpath :: proc(path: string) -> (string, bool) {
	buf: [file_path_max]u8
	r := posix.realpath(file_cstr(path), raw_data(buf[:]))
	if r == nil {
		return "", false
	}
	s, err := strings.clone_from_cstring(r)
	if err != nil {
		return "", false
	}
	return s, true
}

// file_readlink —— os.Readlink 等价；成功返回链接目标文本。
file_readlink :: proc(path: string) -> (string, bool) {
	buf: [file_path_max]u8
	n := posix.readlink(file_cstr(path), raw_data(buf[:]), cast(c.size_t)size_of(buf))
	if n < 0 {
		return "", false
	}
	s, _ := strings.clone(string(buf[:cast(int)n]))
	return s, true
}

// file_acl_ok —— file.c:180-187 rpc_file_access。sid 缺失（内部调用）不做访问控制。
file_acl_ok :: proc(sid, path, perm: string) -> bool {
	if len(sid) == 0 {
		return true
	}
	return session_access(sid, "file", path, perm)
}

// file_check_symlink_access —— file.c:261-359。返回（可能被替换的路径, 挂起状态码）。
file_check_symlink_access :: proc(sid, perm, path: string) -> (string, i32) {
	if resolved, ok := file_realpath(path); ok {
		if resolved == path {
			return path, 0
		}
		if !file_acl_ok(sid, resolved, perm) {
			return "", Status_Permission_Denied
		}
		return resolved, 0
	}
	// 悬空符号链接：看起来「不存在」，但对 open(O_CREAT) 必须拒绝
	if _, is_link := file_readlink(path); is_link {
		return "", Status_Permission_Denied
	}
	slash := -1
	for i := len(path) - 1; i >= 0; i -= 1 {
		if path[i] == '/' {
			slash = i
			break
		}
	}
	if slash < 0 {
		return "", Status_Not_Found
	}
	dir := "/"
	if slash != 0 {
		dir = path[:slash]
	}
	base := path[slash+1:]
	resolved_dir, dir_ok := file_realpath(dir)
	if !dir_ok {
		return "", Status_Unknown_Error
	}
	if resolved_dir == dir {
		// 父目录没变 → 目标确实不存在
		return path, Status_Not_Found
	}
	new_path := fmt.tprintf("%s/%s", resolved_dir, base)
	if !file_acl_ok(sid, new_path, perm) {
		return "", Status_Permission_Denied
	}
	return new_path, Status_Not_Found
}

File_Entry :: struct {
	st:    posix.stat_t,
	valid: bool,
}

// file_check_path —— file.c:361-416 __rpc_check_path。规范化 → ACL →（非 lstat）软链复查 →（可选）stat。
file_check_path :: proc(sid, perm, raw: string, need_stat, use_lstat: bool) -> (path: string, ent: File_Entry, status: i32) {
	canon, ok := file_canonicalize_path(raw)
	if !ok {
		return "", ent, Status_Invalid_Argument
	}
	if !file_acl_ok(sid, canon, perm) {
		return "", ent, Status_Permission_Denied
	}
	path = canon
	if !use_lstat {
		new_path, pending := file_check_symlink_access(sid, perm, canon)
		if new_path == "" {
			return "", ent, pending
		}
		path = new_path
		if need_stat && pending == Status_Not_Found {
			return path, ent, pending
		}
	}
	if !need_stat {
		return path, ent, Status_OK
	}
	res: posix.result
	if use_lstat {
		res = posix.lstat(file_cstr(path), &ent.st)
	} else {
		res = posix.stat(file_cstr(path), &ent.st)
	}
	if res == .FAIL {
		return path, ent, file_status_of_errno(posix.errno())
	}
	ent.valid = true
	return path, ent, Status_OK
}

// ---------------------------------------------------------------------------
// 类型 / mode / stat 回复（file.c:145-154 d_types + :634-651 _rpc_file_add_stat）
// ---------------------------------------------------------------------------

file_type_str :: proc(mode: posix.mode_t) -> string {
	if posix.S_ISDIR(mode)  { return "directory" }
	if posix.S_ISLNK(mode)  { return "symlink" }
	if posix.S_ISFIFO(mode) { return "fifo" }
	if posix.S_ISSOCK(mode) { return "socket" }
	if posix.S_ISBLK(mode)  { return "block" }
	if posix.S_ISCHR(mode)  { return "char" }
	return "file"
}

// file_stat_json —— type/size/mode/atime/mtime/ctime/inode。mode = 完整 st_mode 的类型位 | 权限位
// （省略 setuid/sticky，与 Go 一致：golden 0o100644=33188）。
file_stat_json :: proc(st: ^posix.stat_t) -> json.Object {
	// mode_t 是 bit_set，其底层整数就是原始 st_mode（单标志位存 2^log2(v)=v）。
	raw := file_mode_u32(st.st_mode)
	obj: json.Object = make(json.Object)
	obj["type"] = json.String(file_type_str(st.st_mode))
	obj["size"] = json.Integer(cast(int)st.st_size)
	obj["mode"] = json.Integer(cast(int)((raw & file_s_ifmt) | (raw & 0o777)))
	obj["atime"] = json.Integer(cast(int)st.st_atim.tv_sec)
	obj["mtime"] = json.Integer(cast(int)st.st_mtim.tv_sec)
	obj["ctime"] = json.Integer(cast(int)st.st_ctim.tv_sec)
	obj["inode"] = json.Integer(cast(int)(cast(u32)st.st_ino))
	return obj
}

// ---------------------------------------------------------------------------
// 方法入口
// ---------------------------------------------------------------------------

file_param_str :: proc(o: json.Object, key: string) -> (string, bool) {
	return param_str(o, key)
}

// file_read_all —— 读整文件；错误映射到 ubus 状态。
file_read_all :: proc(path: string) -> (data: []u8, status: i32) {
	fd := posix.open(file_cstr(path), {})
	if cast(int)fd < 0 {
		return nil, file_status_of_errno(posix.errno())
	}
	defer posix.close(fd)
	buf := make([dynamic]u8)
	tmp: [4096]u8
	for {
		n := posix.read(fd, raw_data(tmp[:]), cast(c.size_t)size_of(tmp))
		if n < 0 {
			e := posix.errno()
			if e == .EINTR {
				continue
			}
			return nil, file_status_of_errno(e)
		}
		if n == 0 {
			break
		}
		append(&buf, ..tmp[:cast(int)n])
	}
	out := make([]u8, len(buf))
	copy(out, buf[:])
	return out, Status_OK
}

// file.c:418-497 rpc_file_read。params: path（必需）、base64?。空/读不到 → 5；>=256KB → 8。
file_method_read :: proc(o: json.Object, sid: string) -> (status: i32, reply: string) {
	raw, has := file_param_str(o, "path")
	if !has {
		return Status_Invalid_Argument, ""
	}
	path, ent, rc := file_check_path(sid, "read", raw, true, false)
	if rc != Status_OK {
		return rc, ""
	}
	if cast(i64)ent.st.st_size >= file_max_size {
		return Status_Not_Supported, ""
	}
	data, rstatus := file_read_all(path)
	if rstatus != Status_OK {
		return rstatus, ""
	}
	// C 的 read() <= 0 → NO_DATA（空文件与空 sysfs 文件都走这条）
	if len(data) == 0 {
		return Status_No_Data, ""
	}
	text := string(data)
	if uci_param_bool(o, "base64") {
		text = base64.encode(data)
	}
	doc: json.Object = make(json.Object)
	doc["data"] = json.String(text)
	return Status_OK, json_unparse(doc)
}

// file.c:561-592 rpc_file_md5。权限 "read"；只对普通文件有效（其它 → 8）。
file_method_md5 :: proc(o: json.Object, sid: string) -> (status: i32, reply: string) {
	raw, has := file_param_str(o, "path")
	if !has {
		return Status_Invalid_Argument, ""
	}
	path, ent, rc := file_check_path(sid, "read", raw, true, false)
	if rc != Status_OK {
		return rc, ""
	}
	if !posix.S_ISREG(ent.st.st_mode) {
		return Status_Not_Supported, ""
	}
	data, rstatus := file_read_all(path)
	if rstatus != Status_OK {
		return rstatus, ""
	}
	doc: json.Object = make(json.Object)
	doc["md5"] = json.String(md5_hex(data))
	return Status_OK, json_unparse(doc)
}

// file.c:726-746 rpc_file_stat。权限名是 "list"，走 stat（跟随符号链接）。
file_method_stat :: proc(o: json.Object, sid: string) -> (status: i32, reply: string) {
	raw, has := file_param_str(o, "path")
	if !has {
		return Status_Invalid_Argument, ""
	}
	path, ent, rc := file_check_path(sid, "list", raw, true, false)
	if rc != Status_OK {
		return rc, ""
	}
	doc := file_stat_json(&ent.st)
	doc["path"] = json.String(path)
	return Status_OK, json_unparse(doc)
}

// file.c:748-768 rpc_file_lstat。权限名 "list"；不解析符号链接。
file_method_lstat :: proc(o: json.Object, sid: string) -> (status: i32, reply: string) {
	raw, has := file_param_str(o, "path")
	if !has {
		return Status_Invalid_Argument, ""
	}
	path, ent, rc := file_check_path(sid, "list", raw, true, true)
	if rc != Status_OK {
		return rc, ""
	}
	doc := file_stat_json(&ent.st)
	doc["path"] = json.String(path)
	return Status_OK, json_unparse(doc)
}

// file.c:653-724 rpc_file_list。权限 "list"，目录本身解析符号链接；每个条目用 lstat。
file_method_list :: proc(o: json.Object, sid: string) -> (status: i32, reply: string) {
	raw, has := file_param_str(o, "path")
	if !has {
		return Status_Invalid_Argument, ""
	}
	path, _, rc := file_check_path(sid, "list", raw, false, false)
	if rc != Status_OK {
		return rc, ""
	}
	d := posix.opendir(file_cstr(path))
	if d == nil {
		return file_status_of_errno(posix.errno()), ""
	}
	defer posix.closedir(d)

	entries: json.Array = make(json.Array)
	for {
		ent := posix.readdir(d)
		if ent == nil {
			break
		}
		name, _ := strings.clone_from_cstring(cast(cstring)(&ent.d_name[0]))
		if name == "." || name == ".." {
			continue
		}
		entry_path := fmt.tprintf("%s/%s", path, name)
		lst: posix.stat_t
		if posix.lstat(file_cstr(entry_path), &lst) == .FAIL {
			continue // 上游 lstat 失败的条目直接跳过（file.c:682）
		}
		doc := file_stat_json(&lst)
		doc["name"] = json.String(name)
		if posix.S_ISLNK(lst.st_mode) {
			target: json.Object = make(json.Object)
			if link, ok := file_readlink(entry_path); ok {
				target["name"] = json.String(link)
			}
			tst: posix.stat_t
			if posix.stat(file_cstr(entry_path), &tst) == .OK {
				for key, val in file_stat_json(&tst) {
					target[key] = val
				}
			} else {
				target["type"] = json.String("broken")
			}
			doc["target"] = json.Value(target)
		}
		append(&entries, json.Value(doc))
	}
	outer: json.Object = make(json.Object)
	outer["entries"] = json.Value(entries)
	return Status_OK, json_unparse(outer)
}

// file.c:499-559 rpc_file_write。params: path（必需）、data（必需）/append?/mode?/base64?。
func_default  :: 0o666
file_method_write :: proc(o: json.Object, sid: string) -> (status: i32, reply: string) {
	raw, has := file_param_str(o, "path")
	if !has {
		return Status_Invalid_Argument, ""
	}
	data_str, has_data := file_param_str(o, "data")
	if !has_data {
		return Status_Invalid_Argument, ""
	}
	data: []u8 = transmute([]u8)data_str

	path, _, rc := file_check_path(sid, "write", raw, false, false)
	if rc != Status_OK {
		return rc, ""
	}

	if uci_param_bool(o, "base64") && len(data) > 0 {
		decoded, derr := base64.decode(data_str)
		if derr != nil {
			return Status_Unknown_Error, "" // 上游 b64_decode 失败 → UNKNOWN_ERROR
		}
		data = decoded
	}

	flags: posix.O_Flags = {.WRONLY, .CREAT}
	if uci_param_bool(o, "append") {
		flags |= {.APPEND}
	} else {
		flags |= {.TRUNC}
	}
	mode_bits: u32 = func_default
	if m, has_mode := param_int(o, "mode"); has_mode {
		mode_bits = cast(u32)m & 0o777
	}

	fd := posix.open(file_cstr(path), flags, file_mode_from_bits(mode_bits))
	if cast(int)fd < 0 {
		return file_status_of_errno(posix.errno()), ""
	}
	defer posix.close(fd)
	if len(data) > 0 {
		n := posix.write(fd, raw_data(data), cast(c.size_t)len(data))
		if n < 0 {
			return file_status_of_errno(posix.errno()), ""
		}
	}
	if posix.fsync(fd) == .FAIL {
		return file_status_of_errno(posix.errno()), ""
	}
	// 上游随后还调了全局 sync()；进程内等价物没有便携 API，省略（偏离已记文档）
	return Status_OK, ""
}

// file.c:773-818 rpc_file_remove_recursive。每个条目都要单独过 write ACL。
file_remove_recursive :: proc(sid, path: string) -> i32 {
	d := posix.opendir(file_cstr(path))
	if d == nil {
		return file_status_of_errno(posix.errno())
	}
	defer posix.closedir(d)
	for {
		ent := posix.readdir(d)
		if ent == nil {
			break
		}
		name, _ := strings.clone_from_cstring(cast(cstring)(&ent.d_name[0]))
		if name == "." || name == ".." {
			continue
		}
		entry_path := fmt.tprintf("%s/%s", path, name)
		if !file_acl_ok(sid, entry_path, "write") {
			return Status_Permission_Denied
		}
		lst: posix.stat_t
		if posix.lstat(file_cstr(entry_path), &lst) == .FAIL {
			continue
		}
		if posix.S_ISDIR(lst.st_mode) {
			if st := file_remove_recursive(sid, entry_path); st != Status_OK {
				return st
			}
		} else if posix.unlink(file_cstr(entry_path)) == .FAIL {
			return file_status_of_errno(posix.errno())
		}
	}
	// POSIX 上 rmdir 删空目录
	if posix.rmdir(file_cstr(path)) == .FAIL {
		return file_status_of_errno(posix.errno())
	}
	return Status_OK
}

// file.c:820-844 rpc_file_remove。权限 "write"；不解析符号链接（unlink 的 no-follow）。
file_method_remove :: proc(o: json.Object, sid: string) -> (status: i32, reply: string) {
	raw, has := file_param_str(o, "path")
	if !has {
		return Status_Invalid_Argument, ""
	}
	path, ent, rc := file_check_path(sid, "write", raw, true, true)
	if rc != Status_OK {
		return rc, ""
	}
	if posix.S_ISDIR(ent.st.st_mode) {
		if st := file_remove_recursive(sid, path); st != Status_OK {
			return st, ""
		}
		return Status_OK, ""
	}
	if posix.unlink(file_cstr(path)) == .FAIL {
		return file_status_of_errno(posix.errno()), ""
	}
	return Status_OK, ""
}

// ---------------------------------------------------------------------------
// exec（file.c:846-1203）
// ---------------------------------------------------------------------------

// file_exec_lookup —— file.c:846-885。先试命令本身，再沿 PATH 找（无 PATH 用默认列表）。
file_exec_lookup :: proc(cmd: string) -> (string, i32) {
	st: posix.stat_t
	if posix.stat(file_cstr(cmd), &st) == .OK && posix.S_ISREG(st.st_mode) {
		return cmd, Status_OK
	}
	search := os.get_env("PATH", context.allocator)
	if len(search) == 0 {
		search = "/bin:/usr/bin:/sbin:/usr/sbin"
	}
	start := 0
	for i := 0; i <= len(search); i += 1 {
		if i == len(search) || search[i] == ':' {
			if i > start {
				part := search[start:i]
				cand := fmt.tprintf("%s/%s", part, cmd)
				cst: posix.stat_t
				if posix.stat(file_cstr(cand), &cst) == .OK && posix.S_ISREG(cst.st_mode) {
					return cand, Status_OK
				}
			}
			start = i + 1
		}
	}
	return "", Status_Not_Found
}

// file_exec_check_acl —— file.c:1055-1083：① 可执行文件路径查 exec；② 没过就把整条命令行
// （"exe arg1 arg2…"，≤1024B、≤255 参数）当第二个 ACL 对象再查一次。两条都不过 → 6。
file_exec_check_acl :: proc(sid, exe: string, argv: []string) -> i32 {
	if file_acl_ok(sid, exe, "exec") {
		return Status_OK
	}
	argc := 1
	for i := 1; i < len(argv); i += 1 {
		if argc >= file_exec_max_args {
			return Status_Permission_Denied
		}
		argc += 1
	}
	cmdline := exe
	for i := 1; i < len(argv); i += 1 {
		cmdline = fmt.tprintf("%s %s", cmdline, argv[i])
		if len(cmdline) >= file_exec_cmdline_max {
			return Status_Permission_Denied
		}
	}
	if !file_acl_ok(sid, cmdline, "exec") {
		return Status_Permission_Denied
	}
	return Status_OK
}

// file_exec_env —— 合并 os.environ() 与注入的 env 表（同键覆盖），对应上游子进程里的 setenv。
file_exec_env :: proc(o: json.Object, env_obj: json.Object) -> []string {
	base, err := os.environ(context.allocator)
	merged := make([dynamic]string)
	index := make(map[string]int)
	if err == nil {
		for kv in base {
			key := kv
			if i := strings.index(kv, "="); i >= 0 {
				key = kv[:i]
			}
			if _, seen := index[key]; seen {
				continue
			}
			index[key] = len(merged)
			append(&merged, kv)
		}
	}
	for k, v in env_obj {
		s, ok := uci_raw_str(v)
		if !ok {
			continue
		}
		if i, seen := index[k]; seen {
			merged[i] = fmt.tprintf("%s=%s", k, s)
		} else {
			index[k] = len(merged)
			append(&merged, fmt.tprintf("%s=%s", k, s))
		}
	}
	_ = o
	return merged[:]
}

// 退出码映射见 process_spawn.odin 的 spawn_exit_code（对齐 Go fileExecExitCode）。

// file.c:1028-1203 rpc_file_exec_run 的**同步**版本。不做 shell 拼接：argv 数组直接交给子进程。
file_method_exec :: proc(o: json.Object, sid: string) -> (status: i32, reply: string) {
	cmd, has := file_param_str(o, "command")
	if !has {
		return Status_Invalid_Argument, ""
	}
	_, has_env := o["env"]
	if has_env && len(sid) > 0 {
		return Status_Permission_Denied, "" // file.c:1047：带会话不允许传 env
	}
	exe, lst := file_exec_lookup(cmd)
	if lst != Status_OK {
		return lst, ""
	}
	can, ok := file_canonicalize_path(exe)
	if !ok {
		return Status_Unknown_Error, ""
	}
	exe = can

	argv := make([dynamic]string)
	append(&argv, exe)
	if arr, has_params := uci_param_array(o, "params"); has_params {
		for v in arr {
			if s, is_str := uci_raw_str(v); is_str {
				append(&argv, s)
			}
		}
	}
	if st := file_exec_check_acl(sid, exe, argv[:]); st != Status_OK {
		return st, ""
	}

	env: []string
	if has_env {
		if env_obj, is_obj := uci_param_object(o, "env"); is_obj {
			env = file_exec_env(o, env_obj)
		}
	}
	res := spawn_run(argv[:], env, nil, true)
	out, errb := res.stdout, res.stderr
	if len(out) > file_exec_output_cap || len(errb) > file_exec_output_cap {
		return Status_Not_Supported, "" // 输出超限 → 8（上游 ustream 缓冲满）
	}
	// 注：120s 超时在宿主同步执行下不启用；看门狗线程留给阶段 3h 的 linux 运行期。

	doc: json.Object = make(json.Object)
	doc["code"] = json.Integer(spawn_exit_code(res))
	if len(out) > 0 {
		doc["stdout"] = json.String(string(out))
	}
	if len(errb) > 0 {
		doc["stderr"] = json.String(string(errb))
	}
	return Status_OK, json_unparse(doc)
}

// ---------------------------------------------------------------------------
// 入口（注册为 "file" 对象）
// ---------------------------------------------------------------------------

file_handler :: proc(method, params_json: string, alloc: mem.Allocator) -> (status: i32, reply: string) {
	_ = alloc
	session_ensure_store()
	params: json.Object
	if len(params_json) > 0 {
		if v, err := json.parse_string(params_json, .JSON, true, context.allocator); err == nil {
			if o, ok := v.(json.Object); ok {
				params = o
			}
		}
	}
	if params == nil {
		params = make(json.Object)
	}
	sid, _ := param_str(params, "ubus_rpc_session")

	switch method {
	case "read":   return file_method_read(params, sid)
	case "write":  return file_method_write(params, sid)
	case "list":   return file_method_list(params, sid)
	case "lstat":  return file_method_lstat(params, sid)
	case "stat":   return file_method_stat(params, sid)
	case "md5":    return file_method_md5(params, sid)
	case "remove": return file_method_remove(params, sid)
	case "exec":   return file_method_exec(params, sid)
	}
	return Status_Method_Not_Found, ""
}
