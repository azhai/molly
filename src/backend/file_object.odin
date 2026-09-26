package backend

// ---------------------------------------------------------------------------
// file 对象（P3-4 第一批：路径/权限核心 + `read`）
//
// 契约：rpcd@e37ed9d8 的 `file.c`。8 个方法（`file.c` 的方法表）：
//   read / write / list / lstat / stat / md5 / remove / exec
// 本片实现 `read` 与**所有方法共用的路径/权限核心**；其余 7 个方法回
// NOT_SUPPORTED(8)（P3-4 续，见 .ai-memory/p3-luci-server.md 的分片）。
//
// 与 uci 对象不同，file 是**平台无关**的（只用 core:os 与 libc 的 realpath），
// 所以 darwin 上也是真实现、能端到端测 —— 只有 `exec`（异步进程 + 管道）例外。
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

import "core:encoding/base64"
import "core:encoding/json"
import "core:mem"
import "core:os"
import "core:strings"

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
// 只做**文本**折叠：重复的 `/`、`/./`、`/x/../`、结尾的 `/`（根目录除外）。
// 空路径 → false（上游返回 NULL → EINVAL → 2）。
file_canonicalize_path :: proc(path: string, alloc: mem.Allocator) -> (string, bool) {
	if len(path) == 0 {
		return "", false
	}

	out := make([dynamic]u8, 0, len(path) + 1, alloc)
	p := 0
	for p < len(path) {
		if path[p] != '/' {
			append(&out, path[p])
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
			// `/../`：回退到上一个 `/`（那个 `/` 本身留着，等着被下一段的 `/` 覆盖）
			if p + 2 < len(path) && path[p + 2] == '.' && (p + 3 == len(path) || path[p + 3] == '/') {
				for len(out) > 0 {
					if out[len(out) - 1] == '/' {
						break
					}
					pop(&out)
				}
				p += 3
				continue
			}
		}

		append(&out, path[p])
		p += 1
	}

	// 去掉结尾的 `/`（根目录除外）；空串补成 `/`
	if len(out) > 1 && out[len(out) - 1] == '/' {
		pop(&out)
	} else if len(out) == 0 {
		append(&out, '/')
	}

	return string(out[:]), true
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
// 返回 path、文件大小（need_stat 时有效）与状态码（0 = 继续）。
file_check_path :: proc(
	sid, perm, raw: string,
	need_stat: bool,
	use_lstat: bool,
	alloc: mem.Allocator,
) -> (path: string, size: i64, status: int) {
	canon, ok := file_canonicalize_path(raw, alloc)
	if !ok {
		return "", 0, FILE_STATUS_INVALID_ARGUMENT
	}

	if !file_acl_ok(sid, canon, perm) {
		return "", 0, FILE_STATUS_PERMISSION_DENIED
	}

	// C 的宏 rpc_check_path 会解析符号链接（read/write/list/stat/md5）；
	// rpc_check_path_with_lstat 不解析（lstat 要看链接本身、remove 靠 unlink 的 no-follow）
	if !use_lstat {
		new_path, pending := file_check_symlink_access(sid, perm, canon, alloc)
		if new_path == "" {
			return "", 0, pending
		}
		path = new_path
		// 挂起的 ENOENT：只有接下来要 stat 时才会变成错误（write 要 create，不能提前失败）
		if need_stat && pending == FILE_STATUS_NOT_FOUND {
			return path, 0, pending
		}
	} else {
		path = canon
	}

	if need_stat {
		info, serr := os.stat(path, alloc)
		if serr != nil {
			return path, 0, file_status_of(serr)
		}
		size = info.size
	}

	return path, size, FILE_STATUS_OK
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

	path, size, status := file_check_path(sid, "read", raw, true, false, alloc)
	if status != 0 {
		return "", status
	}
	if size >= FILE_MAX_SIZE {
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
	case "write", "list", "lstat", "stat", "md5", "remove", "exec":
		// P3-4 续（见文件头）。其中 exec 最重（异步进程 + 两条管道 + 超时），单独一片。
		// 在实现之前一律回 8：**不做任何文件系统改动**。
		return "", FILE_STATUS_NOT_SUPPORTED
	case:
		return "", FILE_STATUS_METHOD_NOT_FOUND
	}
}
