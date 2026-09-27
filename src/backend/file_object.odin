package backend

// ---------------------------------------------------------------------------
// file 对象（P3-4：路径/权限核心 + read/stat/lstat/list/md5/write/remove）
//
// 契约：rpcd@e37ed9d8 的 `file.c`。8 个方法（`file.c:1227-1234` 的方法表）：
//   read / write / list / lstat / stat / md5 / remove / exec
// 8 个方法全部实现。`exec` 是同步版（fork + 双管道 poll + 120s 超时），上游用
// uloop + ubus 延迟回复异步回包——对调用方可观测行为一致（偏离记 §9.3）。
//
// **权限名按方法各不相同**（上游照抄，改错一个 golden 就对不上）：
//   read/md5 → "read"；write/remove → "write"；list/stat/lstat → "list"。
//
// 与 uci 对象不同，file 是**平台无关**的（只用 core:os 与 libc 的 realpath），
// 所以 darwin 上也是真实现、能端到端测。
//
// 安全要点（务必照抄，别简化）：路径的 ACL 是按**文本**匹配的，所以
//   1) 先把路径规范化（`file_canonicalize_path`，file.c:189-248）：折掉 `//`、`/./`、`/../`
//      与结尾的 `/`；
//   2) 用规范化后的路径查 ACL（`session.access("file", <path>, <perm>)`）；
//   3) **再用 realpath(3) 解析一次符号链接**，如果解析结果与文本路径不同，就对解析结果
//      再查一遍 ACL，并把后续所有操作都改成对解析后的路径做（`file.c:261-359`）。
//      不做第 3 步的话：「ACL 授权了 /tmp/x/，攻击者在 /tmp/x/ 里放一个指向 /etc/shadow 的
//      符号链接」就能读到 /etc/shadow。
// ---------------------------------------------------------------------------

import "core:c"
import "core:crypto/legacy/md5"
import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:time"

import "molly:backend/bindings"

// 与 session/uci 的对象状态码同一套 ubus 码；名字按对象区分。
FILE_STATUS_OK :: 0
FILE_STATUS_INVALID_ARGUMENT :: 2
FILE_STATUS_METHOD_NOT_FOUND :: 3
FILE_STATUS_NOT_FOUND :: 4
FILE_STATUS_NO_DATA :: 5
FILE_STATUS_PERMISSION_DENIED :: 6
FILE_STATUS_NOT_SUPPORTED :: 8
FILE_STATUS_UNKNOWN_ERROR :: 9

// file.c:43-46
FILE_MIN_SIZE :: 4096
FILE_MAX_SIZE :: 4096 * 64

// file.c:157-177 rpc_errno_status 的等价映射。core:os 的错误是
// General_Error | Platform_Error 两层的联合，Platform_Error 就是各平台的 errno。
file_status_of :: proc(err: os.Error) -> int {
	#partial switch e in err {
	case os.General_Error:
		if e == .Not_Exist {
			return FILE_STATUS_NOT_FOUND
		}
		if e == .Invalid_File || e == .Invalid_Dir || e == .Invalid_Path {
			return FILE_STATUS_INVALID_ARGUMENT
		}
		return FILE_STATUS_UNKNOWN_ERROR
	case os.Platform_Error:
		if e == .EACCES || e == .EPERM {
			return FILE_STATUS_PERMISSION_DENIED
		}
		if e == .ENOENT {
			return FILE_STATUS_NOT_FOUND
		}
		if e == .ENOTDIR || e == .EINVAL {
			return FILE_STATUS_INVALID_ARGUMENT
		}
		return FILE_STATUS_UNKNOWN_ERROR
	}
	return FILE_STATUS_UNKNOWN_ERROR
}

// ---------------------------------------------------------------------------
// 路径
// ---------------------------------------------------------------------------

// file.c:189-248 rpc_canonicalize_path（纯函数，可单测）。
// 只做**文本**折叠：重复的 `/`、`/./`、结尾的 `/`（根目录除外）。
// 关键：上游的 `/../` **只在 `..` 之后是 `/` 或结尾时才折叠**（即 `..` 必须是完整片段），
// 中间跟着普通字符的 `..` 不折叠——安全靠后面的 realpath 复查兜底（见 file_check_symlink_access）。
// 空路径 → false（上游返回 NULL → EINVAL → 2）。
file_canonicalize_path :: proc(path: string, alloc: mem.Allocator) -> (string, bool) {
	if len(path) == 0 {
		return "", false
	}

	// 用定长缓冲 + 输出游标 cp，逐字节复刻上游的指针语义（含 `/../` 折叠时的「游标回退后
	// 下一个字符**覆盖**那个 /」）——用 [dynamic]u8 的 pop 会留下 / 再追加，产生双斜杠。
	buf := make([]u8, len(path) + 1, alloc)
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
		if p + 1 < len(path) && path[p + 1] == '/' {
			p += 1
			continue
		}

		if p + 1 < len(path) && path[p + 1] == '.' {
			// `/./`
			if p + 2 == len(path) || path[p + 2] == '/' {
				p += 2
				continue
			}
			// `/../`：游标回退到上一个 `/`（停在那个 / 上，等着被下一个字符覆盖）
			if p + 2 < len(path) && path[p + 2] == '.' && (p + 3 == len(path) || path[p + 3] == '/') {
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

	// 去掉结尾的 `/`（根目录除外）；空串补成 `/`
	if cp > 1 && buf[cp - 1] == '/' {
		cp -= 1
	} else if cp == 0 {
		buf[0] = '/'
		cp = 1
	}

	return string(buf[:cp]), true
}

// realpath(3)：解析符号链接后的绝对路径。失败返回 false（上游靠 errno 区分
// ENOENT 与其它错误，我们这里靠调用点继续判断，见 file_check_symlink_access）。
file_realpath :: proc(path: string, alloc: mem.Allocator) -> (string, bool) {
	buf: [4096]u8 // PATH_MAX：Linux 4096、macOS 1024，取大者
	got := bindings.c_realpath(strings.clone_to_cstring(path, alloc), &buf[0])
	if got == nil {
		return "", false
	}
	return strings.clone(string(got), alloc), true
}

// file.c:180-187 rpc_file_access：session.access("file", <path>, <perm>)。
// sid 缺失（内部调用）不做访问控制。
@(private)
file_acl_ok :: proc(sid, path, perm: string) -> bool {
	if len(sid) == 0 {
		return true
	}
	ses := session_get(sid)
	return ses != nil && session_acl_allowed(ses, "file", path, perm)
}

// file.c:261-359 rpc_check_symlink_access。返回（可能被替换的路径, 挂起的状态码）：
//   * 没有符号链接（realpath 结果与文本路径相同）→ 原路径、0
//   * 有符号链接 → 对**解析后的路径**再查 ACL，通过就换成解析后的路径
//   * realpath 失败且该路径本身是个符号链接（悬空链接）→ 6
//     （上游注释：不能默默 create-through 它，比如 file.write 的 O_CREAT）
//   * realpath 失败（目标不存在）→ 解析父目录后拼回 basename 再查 ACL；
//     父目录没变说明目标确实不存在 → 状态码 4（ENOENT，路径仍然被替换）
file_check_symlink_access :: proc(
	sid, perm, path: string,
	alloc: mem.Allocator,
) -> (new_path: string, pending: int) {
	if resolved, ok := file_realpath(path, alloc); ok {
		if resolved == path {
			return path, 0
		}
		if !file_acl_ok(sid, resolved, perm) {
			return "", FILE_STATUS_PERMISSION_DENIED
		}
		return resolved, 0
	}

	// 悬空的符号链接：看起来「不存在」，但对 open(O_CREAT) 来说是必须拒绝的
	if _, link_err := os.read_link(path, alloc); link_err == nil {
		return "", FILE_STATUS_PERMISSION_DENIED
	}

	slash := strings.last_index_byte(path, '/')
	if slash < 0 {
		return "", FILE_STATUS_NOT_FOUND
	}

	dir := slash == 0 ? "/" : path[:slash]
	base := path[slash + 1:]

	resolved_dir, dir_ok := file_realpath(dir, alloc)
	if !dir_ok {
		return "", FILE_STATUS_UNKNOWN_ERROR
	}
	if resolved_dir == dir {
		// 父目录没变 → 目标确实不存在
		return path, FILE_STATUS_NOT_FOUND
	}

	new_path = strings.concatenate([]string{resolved_dir, "/", base}, alloc)
	if !file_acl_ok(sid, new_path, perm) {
		return "", FILE_STATUS_PERMISSION_DENIED
	}
	return new_path, FILE_STATUS_NOT_FOUND
}

// file.c:361-416 的 __rpc_check_path：规范化 → ACL → 符号链接复查 →（可选）stat。
// 返回 path、stat 信息（need_stat 时有效；use_lstat=true 时用 lstat）与状态码（0 = 继续）。
file_check_path :: proc(
	sid, perm, raw: string,
	need_stat: bool,
	use_lstat: bool,
	alloc: mem.Allocator,
) -> (path: string, info: os.File_Info, status: int) {
	canon, ok := file_canonicalize_path(raw, alloc)
	if !ok {
		return "", info, FILE_STATUS_INVALID_ARGUMENT
	}

	if !file_acl_ok(sid, canon, perm) {
		return "", info, FILE_STATUS_PERMISSION_DENIED
	}

	// C 的宏 rpc_check_path 会解析符号链接（read/write/list/stat/md5）；
	// rpc_check_path_with_lstat 不解析（lstat 要看链接本身、remove 靠 unlink 的 no-follow）
	if !use_lstat {
		new_path, pending := file_check_symlink_access(sid, perm, canon, alloc)
		if new_path == "" {
			return "", info, pending
		}
		path = new_path
		// 挂起的 ENOENT：只有接下来要 stat 时才会变成错误（write 要 create，不能提前失败）
		if need_stat && pending == FILE_STATUS_NOT_FOUND {
			return path, info, pending
		}
	} else {
		path = canon
	}

	if need_stat {
		serr: os.Error
		if use_lstat {
			info, serr = os.lstat(path, alloc)
		} else {
			info, serr = os.stat(path, alloc)
		}
		if serr != nil {
			return path, info, file_status_of(serr)
		}
	}

	return path, info, FILE_STATUS_OK
}

// ---------------------------------------------------------------------------
// 方法
// ---------------------------------------------------------------------------

// file.c:418-497 rpc_file_read。
//   params: path（必需）、base64?
//   回复: {"data": "<内容或 base64>"}
//   空文件/读不到内容 → 5（NO_DATA）；文件 >= 256KB → 8（NOT_SUPPORTED）
@(private)
file_method_read :: proc(params: json.Object, sid: string, alloc: mem.Allocator) -> (string, int) {
	raw, has_path := uci_param_str(params, "path")
	if !has_path {
		return "", FILE_STATUS_INVALID_ARGUMENT
	}

	path, info, status := file_check_path(sid, "read", raw, true, false, alloc)
	if status != 0 {
		return "", status
	}
	if info.size >= FILE_MAX_SIZE {
		return "", FILE_STATUS_NOT_SUPPORTED
	}

	data, rerr := os.read_entire_file(path, alloc)
	if rerr != nil {
		return "", file_status_of(rerr)
	}
	// C 的 read() <= 0 → NO_DATA（空文件与空 sysfs 文件都走这条）
	if len(data) == 0 {
		return "", FILE_STATUS_NO_DATA
	}

	text := string(data)
	if uci_param_bool(params, "base64") {
		text = base64.encode(data, allocator = alloc)
	}

	doc := make(json.Object, 1, alloc)
	doc["data"] = json.Value(json.String(text))
	return session_marshal(json.Value(doc), alloc), FILE_STATUS_OK
}

// ---------------------------------------------------------------------------
// 第二批：stat / lstat / list / md5 / write / remove（exec 仍回 8）
// ---------------------------------------------------------------------------

// file.c:145-154 d_types。
@(private)
file_type_str :: proc(t: os.File_Type) -> string {
	#partial switch t {
	case .Block_Device:    return "block"
	case .Character_Device: return "char"
	case .Directory:       return "directory"
	case .Named_Pipe:      return "fifo"
	case .Symlink:         return "symlink"
	case .Regular:         return "file"
	case .Socket:          return "socket"
	}
	return "unknown"
}

// 上游回的 mode 是完整 st_mode（含类型位）。Odin 的 File_Info.mode 只有权限位，
// 这里把类型位拼回去，保证与真机 golden 一致。
@(private)
file_type_mode_bits :: proc(t: os.File_Type) -> u32 {
	#partial switch t {
	case .Regular:         return 0o100000
	case .Directory:       return 0o040000
	case .Symlink:         return 0o120000
	case .Named_Pipe:      return 0o010000
	case .Socket:          return 0o140000
	case .Block_Device:    return 0o060000
	case .Character_Device: return 0o020000
	}
	return 0
}

// file.c:634-651 _rpc_file_add_stat 的等价回复（除 user/group）。
// 偏离：uid/gid 上游也回，但 Odin 的 File_Info 不含它们——user/group（getpwuid/getgrgid）
// 与 uid/gid 一起省略，见 docs/interfaces.md §9.3。
@(private)
file_stat_dump_json :: proc(info: os.File_Info, alloc: mem.Allocator) -> json.Object {
	obj := make(json.Object, 9, alloc)
	obj["type"] = json.Value(json.String(file_type_str(info.type)))
	obj["size"] = json.Value(json.Integer(info.size))
	obj["mode"] = json.Value(json.Integer(i64(transmute(u32)(info.mode)) | i64(file_type_mode_bits(info.type))))
	obj["atime"] = json.Value(json.Integer(time.to_unix_seconds(info.access_time)))
	obj["mtime"] = json.Value(json.Integer(time.to_unix_seconds(info.modification_time)))
	obj["ctime"] = json.Value(json.Integer(time.to_unix_seconds(info.creation_time)))
	obj["inode"] = json.Value(json.Integer(i64(u32(info.inode)))) // 上游 add_u32，截到 32 位
	return obj
}

// file.c:726-746 rpc_file_stat。注意权限名是 **"list"**（上游照抄），
// 且走 stat（跟随符号链接）。
@(private)
file_method_stat :: proc(params: json.Object, sid: string, alloc: mem.Allocator) -> (string, int) {
	raw, has_path := uci_param_str(params, "path")
	if !has_path {
		return "", FILE_STATUS_INVALID_ARGUMENT
	}

	path, info, status := file_check_path(sid, "list", raw, true, false, alloc)
	if status != 0 {
		return "", status
	}

	doc := file_stat_dump_json(info, alloc)
	doc["path"] = json.Value(json.String(path))
	return session_marshal(json.Value(doc), alloc), FILE_STATUS_OK
}

// file.c:748-768 rpc_file_lstat。权限名也是 "list"；**不解析符号链接**
// （看的就是链接本身），所以链接的 type 是 "symlink"。
@(private)
file_method_lstat :: proc(params: json.Object, sid: string, alloc: mem.Allocator) -> (string, int) {
	raw, has_path := uci_param_str(params, "path")
	if !has_path {
		return "", FILE_STATUS_INVALID_ARGUMENT
	}

	path, info, status := file_check_path(sid, "list", raw, true, true, alloc)
	if status != 0 {
		return "", status
	}

	doc := file_stat_dump_json(info, alloc)
	doc["path"] = json.Value(json.String(path))
	return session_marshal(json.Value(doc), alloc), FILE_STATUS_OK
}

// file.c:653-724 rpc_file_list。权限 "list"，目录本身要解析符号链接；
// 每个条目用 **lstat**（链接要显式暴露 target）。
@(private)
file_method_list :: proc(params: json.Object, sid: string, alloc: mem.Allocator) -> (string, int) {
	raw, has_path := uci_param_str(params, "path")
	if !has_path {
		return "", FILE_STATUS_INVALID_ARGUMENT
	}

	path, _, status := file_check_path(sid, "list", raw, false, false, alloc)
	if status != 0 {
		return "", status
	}

	infos, derr := os.read_directory_by_path(path, -1, alloc)
	if derr != nil {
		return "", file_status_of(derr)
	}

	entries := make([dynamic]json.Value, 0, len(infos), alloc)
	for e in infos {
		// 上游 readdir 后显式跳过 . / ..
		if e.name == "." || e.name == ".." {
			continue
		}
		entry_path := fmt.aprintf("%s/%s", path, e.name, allocator = alloc)

		linfo, lerr := os.lstat(entry_path, alloc)
		if lerr != nil {
			continue // 上游 lstat 失败的条目直接跳过（file.c:682）
		}

		doc := file_stat_dump_json(linfo, alloc)
		doc["name"] = json.Value(json.String(strings.clone(e.name, alloc)))

		// 符号链接：嵌套 target = {name: 链接目标文本, ...目标 stat 或 type:"broken"}
		if linfo.type == .Symlink {
			target := make(json.Object, 8, alloc)
			if link, rerr := os.read_link(entry_path, alloc); rerr == nil {
				target["name"] = json.Value(json.String(strings.clone(link, alloc)))
			}
			if tinfo, terr := os.stat(entry_path, alloc); terr == nil {
				for k, v in file_stat_dump_json(tinfo, alloc) {
					target[k] = v
				}
			} else {
				target["type"] = json.Value(json.String("broken"))
			}
			doc["target"] = json.Value(target)
		}

		append(&entries, json.Value(doc))
	}

	out := make(json.Object, 1, alloc)
	out["entries"] = json.Value(json.Array(entries))
	return session_marshal(json.Value(out), alloc), FILE_STATUS_OK
}

// file.c:561-592 rpc_file_md5。权限 "read"；只对**普通文件**有效（其它 → 8）。
@(private)
file_method_md5 :: proc(params: json.Object, sid: string, alloc: mem.Allocator) -> (string, int) {
	raw, has_path := uci_param_str(params, "path")
	if !has_path {
		return "", FILE_STATUS_INVALID_ARGUMENT
	}

	path, info, status := file_check_path(sid, "read", raw, true, false, alloc)
	if status != 0 {
		return "", status
	}
	if info.type != .Regular {
		return "", FILE_STATUS_NOT_SUPPORTED
	}

	data, rerr := os.read_entire_file(path, alloc)
	if rerr != nil {
		return "", file_status_of(rerr)
	}

	ctx: md5.Context
	md5.init(&ctx)
	md5.update(&ctx, data)
	digest: [16]u8
	md5.final(&ctx, digest[:])

	hex := make([]u8, 32, alloc)
	digits := "0123456789abcdef"
	for b, i in digest {
		hex[i * 2] = digits[b >> 4]
		hex[i * 2 + 1] = digits[b & 15]
	}

	doc := make(json.Object, 1, alloc)
	doc["md5"] = json.Value(json.String(string(hex[:])))
	return session_marshal(json.Value(doc), alloc), FILE_STATUS_OK
}

// file.c:499-559 rpc_file_write。
//   params: path（必需）、data（必需，缺 → 2）、append?、mode?、base64?
//   成功**不回数据**（与上游一致）。默认 O_TRUNC；append=true → O_APPEND；
//   mode 只在**新建**文件时生效（& 0777，默认 0666）。
@(private)
file_method_write :: proc(params: json.Object, sid: string, alloc: mem.Allocator) -> (string, int) {
	raw, has_path := uci_param_str(params, "path")
	if !has_path {
		return "", FILE_STATUS_INVALID_ARGUMENT
	}
	data_v, has_data := params["data"]
	if !has_data {
		return "", FILE_STATUS_INVALID_ARGUMENT
	}
	data: []byte
	if s, is_str := data_v.(json.String); is_str {
		data = transmute([]byte)(string(s))
	} else {
		return "", FILE_STATUS_INVALID_ARGUMENT
	}

	path, _, status := file_check_path(sid, "write", raw, false, false, alloc)
	if status != 0 {
		return "", status
	}

	// 挂起的 ENOENT（父目录解析后目标不存在）：write 可以 create，照常往下走
	if data_b64 := uci_param_bool(params, "base64"); data_b64 && len(data) > 0 {
		decoded, derr := base64.decode(string(data), allocator = alloc)
		if derr != nil {
			// 上游 b64_decode 失败 → UNKNOWN_ERROR
			return "", FILE_STATUS_UNKNOWN_ERROR
		}
		data = decoded
	}

	flags := os.File_Flags{.Write, .Create}
	if uci_param_bool(params, "append") {
		flags += {.Append}
	} else {
		flags += {.Trunc}
	}

	// mode 只在创建时生效；权限位与 unix 位一一对应（Permission_Flag 的枚举值就是位号）
	mode_bits := u32(0o666)
	if m, has_mode := params["mode"]; has_mode {
		if n, is_int := m.(json.Integer); is_int {
			mode_bits = u32(n) & 0o777
		}
	}

	f, oerr := os.open(path, flags, transmute(os.Permissions)(mode_bits))
	if oerr != nil {
		return "", file_status_of(oerr)
	}
	defer os.close(f)

	if len(data) > 0 {
		if _, werr := os.write(f, data); werr != nil {
			return "", file_status_of(werr)
		}
	}
	if serr := os.sync(f); serr != nil {
		return "", file_status_of(serr)
	}
	// 上游随后还调了全局 sync()；进程内等价物没有便携 API，省略（偏离已记文档）

	// 成功不回数据
	return "", FILE_STATUS_OK
}

// file.c:773-818 rpc_file_remove_recursive。**每个条目都要单独过 write ACL**
// （file.c:792）——授权 /tmp 只能删 /tmp 下你自己创建的东西，子目录越权即整条 6。
@(private)
file_remove_recursive :: proc(sid, path: string, alloc: mem.Allocator) -> int {
	infos, derr := os.read_directory_by_path(path, -1, alloc)
	if derr != nil {
		return file_status_of(derr)
	}

	for e in infos {
		if e.name == "." || e.name == ".." {
			continue
		}
		entry_path := fmt.aprintf("%s/%s", path, e.name, allocator = alloc)

		if !file_acl_ok(sid, entry_path, "write") {
			return FILE_STATUS_PERMISSION_DENIED
		}

		linfo, lerr := os.lstat(entry_path, alloc)
		if lerr != nil {
			continue // 上游 lstat 失败的条目跳过
		}
		if linfo.type == .Directory {
			if st := file_remove_recursive(sid, entry_path, alloc); st != 0 {
				return st
			}
		} else if err := os.remove(entry_path); err != nil {
			return file_status_of(err)
		}
	}

	// POSIX 上 remove(3) 对空目录就是 rmdir，所以这里与 unlink 共用一个 os.remove
	if err := os.remove(path); err != nil {
		return file_status_of(err)
	}
	return FILE_STATUS_OK
}

// file.c:820-844 rpc_file_remove。权限 "write"；**不解析符号链接**
// （unlink 的 no-follow 语义——删除的是链接本身，不是目标）。
// 目录 → 递归删除（每个条目单独过 ACL）。
@(private)
file_method_remove :: proc(params: json.Object, sid: string, alloc: mem.Allocator) -> (string, int) {
	raw, has_path := uci_param_str(params, "path")
	if !has_path {
		return "", FILE_STATUS_INVALID_ARGUMENT
	}

	path, info, status := file_check_path(sid, "write", raw, true, true, alloc)
	if status != 0 {
		return "", status
	}

	if info.type == .Directory {
		if st := file_remove_recursive(sid, path, alloc); st != 0 {
			return "", st
		}
		return "", FILE_STATUS_OK
	}

	if err := os.remove(path); err != nil {
		return "", file_status_of(err)
	}
	return "", FILE_STATUS_OK
}

// ---------------------------------------------------------------------------
// exec（file.c:846-1203；P3-4 收尾）
// ---------------------------------------------------------------------------

// 上游 rpc_errno_status 之外的码：UBUS_STATUS_TIMEOUT
FILE_STATUS_TIMEOUT :: 7

// RPC_EXEC_DEFAULT_TIMEOUT（exec.h:27）：120 秒
FILE_EXEC_TIMEOUT_MS :: 120 * 1000
// RPC_CMDLINE_MAX_SIZE（file.c:49）：整条命令行 ACL 对象的上限
FILE_EXEC_CMDLINE_MAX :: 1024
// 参数个数上限（file.c:1073）
FILE_EXEC_MAX_ARGS :: 255
// 输出上限：上游是 ustream 缓冲（libubox 内部大小），满 → 8；这里取 64KB 近似
FILE_EXEC_OUTPUT_CAP :: 64 * 1024

// file.c:846-885 rpc_file_exec_lookup：先试命令本身，再沿 PATH 找（无 PATH 用
// /bin:/usr/bin:/sbin:/usr/sbin）。找不到 → 4。
@(private)
file_exec_lookup :: proc(cmd: string, alloc: mem.Allocator) -> (string, int) {
	if info, err := os.stat(cmd, alloc); err == nil && info.type == .Regular {
		return cmd, FILE_STATUS_OK
	}

	search := os.get_env("PATH", alloc)
	if len(search) == 0 {
		search = "/bin:/usr/bin:/sbin:/usr/sbin"
	}

	for part in strings.split(search, ":", alloc) {
		cand := fmt.aprintf("%s/%s", part, cmd, allocator = alloc)
		if info, err := os.stat(cand, alloc); err == nil && info.type == .Regular {
			return cand, FILE_STATUS_OK
		}
	}
	return "", FILE_STATUS_NOT_FOUND
}

// file.c:846-885 的 PATH 查找 + file.c:1055-1083 的 ACL 规则：
//   1. 可执行文件路径本身查 `session.access("file", <exe>, "exec")`；
//   2. 没过的话，把**整条命令行**（"exe arg1 arg2…"，≤1024B、≤255 个参数）当作
//      第二个 ACL 对象再查一次——ACL 可以只授权「某个可执行文件带任意参数」，
//      也可以授权「这条精确命令行」。两条都不过 → 6。
file_exec_check_acl :: proc(
	sid, exe: string,
	argv: []string,
	alloc: mem.Allocator,
) -> int {
	if file_acl_ok(sid, exe, "exec") {
		return FILE_STATUS_OK
	}

	// 组整条命令行（file.c:1065-1082）：exe 后跟 " %s" 的参数；非字符串参数上游
	// 直接跳过（blobmsg 类型检查），个数超 255 或总长超 1024 → 6。
	argc := 1
	for a in argv[1:] {
		if argc >= FILE_EXEC_MAX_ARGS {
			return FILE_STATUS_PERMISSION_DENIED
		}
		argc += 1
	}
	cmdline := exe
	for a in argv[1:] {
		cmdline = fmt.aprintf("%s %s", cmdline, a, allocator = alloc)
		if len(cmdline) >= FILE_EXEC_CMDLINE_MAX {
			return FILE_STATUS_PERMISSION_DENIED
		}
	}
	if !file_acl_ok(sid, cmdline, "exec") {
		return FILE_STATUS_PERMISSION_DENIED
	}
	return FILE_STATUS_OK
}

// 读一次管道直到 EOF/超限/暂空。返回（eof, 超限）。
@(private)
exec_read_once :: proc(fd: posix.FD, buf: ^[dynamic]u8) -> (eof: bool, over: bool) {
	tmp: [4096]u8
	for {
		r := posix.read(fd, &tmp[0], c.size_t(len(tmp)))
		if r > 0 {
			for b in tmp[:r] {
				append(buf, b)
			}
			if len(buf^) > FILE_EXEC_OUTPUT_CAP {
				return false, true
			}
			continue
		}
		return r == 0, false
	}
}

// file.c:1028-1203 rpc_file_exec_run 的**同步**版本。上游用 uloop 定时器 + ubus
// 延迟回复（进程退出后异步回包）；molly 的对象层是同步 RPC，就在本线程里等到
// 进程退出（或超时/输出超限）再回——对调用方可观测行为一致，代价是占用 ubus 线程
// 最长 120s（偏离已记文档）。不做 shell 拼接：argv 数组直接 execv（AGENTS.md §2.2）。
@(private)
file_method_exec :: proc(params: json.Object, sid: string, alloc: mem.Allocator) -> (string, int) {
	cmd, has_cmd := uci_param_str(params, "command")
	if !has_cmd {
		return "", FILE_STATUS_INVALID_ARGUMENT
	}

	// file.c:1047-1048：带会话的调用不允许传 env（env 注入只留给内部路径）
	_, has_env := params["env"]
	if has_env && len(sid) > 0 {
		return "", FILE_STATUS_PERMISSION_DENIED
	}

	exe, st := file_exec_lookup(cmd, alloc)
	if st != 0 {
		return "", st
	}
	exe2, ok := file_canonicalize_path(exe, alloc)
	if !ok {
		return "", FILE_STATUS_UNKNOWN_ERROR
	}
	exe = exe2

	// 参数：数组里的字符串才收（file.c:1070-1071 / :1130-1133 跳过其它类型）
	argv := make([dynamic]string, 0, 8, alloc)
	append(&argv, exe)
	if p, has_params := params["params"]; has_params {
		if arr, is_arr := p.(json.Array); is_arr {
			for v in arr {
				if s, is_str := v.(json.String); is_str {
					append(&argv, string(s))
				}
			}
		}
	}

	if st := file_exec_check_acl(sid, exe, argv[:], alloc); st != 0 {
		return "", st
	}

	// fork 之前把 C 字符串数组全部构造好（子进程里不允许分配，见 cgi_exec 同一规则）
	argv_c := make([dynamic]cstring, 0, len(argv) + 1, alloc)
	for a in argv {
		append(&argv_c, strings.clone_to_cstring(a, alloc))
	}
	append(&argv_c, nil)

	opipe: [2]posix.FD
	epipe: [2]posix.FD
	if posix.pipe(&opipe) != .OK {
		return "", FILE_STATUS_UNKNOWN_ERROR
	}
	if posix.pipe(&epipe) != .OK {
		posix.close(opipe[0])
		posix.close(opipe[1])
		return "", FILE_STATUS_UNKNOWN_ERROR
	}

	pid := posix.fork()
	if pid < 0 {
		for f in opipe {
			posix.close(f)
		}
		for f in epipe {
			posix.close(f)
		}
		return "", FILE_STATUS_UNKNOWN_ERROR
	}

	if pid == 0 {
		// ★ 子进程：到这里只做 async-signal-safe 调用（dup2/close/open/execv/_exit）
		devnull := posix.open("/dev/null", {.RDWR})
		if int(devnull) < 0 {
			posix._exit(127)
		}
		posix.dup2(devnull, 0) // stdin → /dev/null
		posix.dup2(opipe[1], 1)
		posix.dup2(epipe[1], 2)
		posix.close(opipe[0])
		posix.close(opipe[1])
		posix.close(epipe[0])
		posix.close(epipe[1])
		if int(devnull) > 2 {
			posix.close(devnull)
		}

		if has_env {
			// 上游 file.c:1156-1165。走到这里说明 sid 为空（内部调用），见入口检查。
			if e, ok := params["env"]; ok {
				if obj, is_obj := e.(json.Object); is_obj {
					for k, v in obj {
						if s, is_str := v.(json.String); is_str {
							posix.setenv(
								strings.clone_to_cstring(k, alloc),
								strings.clone_to_cstring(string(s), alloc),
								true,
							)
						}
					}
				}
			}
		}

		if posix.execv(argv_c[0], &argv_c[0]) != 0 {
			posix._exit(127)
		}
		posix._exit(127)
	}

	// ★ 父进程：关闭写端，双管道轮询读到 EOF（或超时/超限）
	posix.close(opipe[1])
	posix.close(epipe[1])

	out := make([dynamic]u8, 0, 4096, alloc)
	errb := make([dynamic]u8, 0, 4096, alloc)
	out_open := true
	err_open := true

	tmp: [4096]u8
	for out_open || err_open {
		rem := FILE_EXEC_TIMEOUT_MS
		fds: [2]posix.pollfd
		nfds := 0
		if out_open {
			fds[nfds] = posix.pollfd{fd = opipe[0], events = {.IN}}
			nfds += 1
		}
		if err_open {
			fds[nfds] = posix.pollfd{fd = epipe[0], events = {.IN}}
			nfds += 1
		}

		n := posix.poll(&fds[0], posix.nfds_t(nfds), c.int(rem))
		if n < 0 {
			// EINTR 等暂时性错误：继续等
			continue
		}
		if n == 0 {
			// 超时：SIGKILL（file.c:965-966）→ 状态 7
			_ = posix.kill(pid, .SIGKILL)
			st: c.int
			_ = posix.waitpid(pid, &st, {})
			return "", FILE_STATUS_TIMEOUT
		}

		for i := 0; i < nfds; i += 1 {
			if fds[i].revents & ({.IN} | {.HUP}) == {} {
				continue
			}
			eof, over: bool
			if fds[i].fd == opipe[0] {
				eof, over = exec_read_once(opipe[0], &out)
			} else {
				eof, over = exec_read_once(epipe[0], &errb)
			}
			if over {
				// 输出超限 → 8（上游是 ustream 缓冲满；顺手杀进程，上游不杀——偏离已记）
				_ = posix.kill(pid, .SIGKILL)
				wst: c.int
				_ = posix.waitpid(pid, &wst, {})
				return "", FILE_STATUS_NOT_SUPPORTED
			}
			if eof {
				if fds[i].fd == opipe[0] {
					out_open = false
				} else {
					err_open = false
				}
				posix.close(fds[i].fd)
			}
		}
	}

	wst: c.int
	_ = posix.waitpid(pid, &wst, {})
	code: int
	if posix.WIFEXITED(wst) {
		code = int(posix.WEXITSTATUS(wst))
	} else if posix.WIFSIGNALED(wst) {
		// 被信号杀掉：上游的 WEXITSTATUS 是未定义值，这里给一个稳定的 0xff
		code = 0xff
	}

	posix.close(opipe[0])
	posix.close(epipe[0])

	doc := make(json.Object, 3, alloc)
	doc["code"] = json.Value(json.Integer(i64(code)))
	if len(out) > 0 {
		doc["stdout"] = json.Value(json.String(string(out[:])))
	}
	if len(errb) > 0 {
		doc["stderr"] = json.Value(json.String(string(errb[:])))
	}
	return session_marshal(json.Value(doc), alloc), FILE_STATUS_OK
}

// file 对象的调用入口（与 session_call / uci_call 同形）。
file_call :: proc(method: string, params_json: string, alloc: mem.Allocator) -> (reply: string, status: int) {
	params := make(json.Object, 0, alloc)
	if len(params_json) > 0 {
		doc: json.Value
		if err := json.unmarshal(transmute([]byte)(params_json), &doc, .JSON, alloc); err == nil {
			if obj, is_obj := doc.(json.Object); is_obj {
				params = obj
			}
		}
	}

	sid, _ := uci_sid_of(params)

	switch method {
	case "read":
		return file_method_read(params, sid, alloc)
	case "write":
		return file_method_write(params, sid, alloc)
	case "list":
		return file_method_list(params, sid, alloc)
	case "lstat":
		return file_method_lstat(params, sid, alloc)
	case "stat":
		return file_method_stat(params, sid, alloc)
	case "md5":
		return file_method_md5(params, sid, alloc)
	case "remove":
		return file_method_remove(params, sid, alloc)
	case "exec":
		return file_method_exec(params, sid, alloc)
	case:
		return "", FILE_STATUS_METHOD_NOT_FOUND
	}
}
