package backend

// cgi-io —— fs.exec_direct / fs.read_direct 与专家版备份的服务端（对齐 internal/backend/cgi_io.go）。
//
// 安全模型（关键，同 Go）：/cgi-exec 能跑的命令与 `ubus file.exec` **完全一致**——复用同一批 ACL
// 原语（file_exec_lookup / file_canonicalize_path / file_exec_check_acl / file_check_path），
// 不新开执行面。会话必须是已认证的（cgiio_require_session），匿名/默认会话一律 PermissionDenied。
//
// 与 Go 的差别只在**回包时机**：Go 用 io.Writer 流式；Odin 宿主侧经统一的 spawn_run（同步把整段
// stdout/stderr 收进缓冲；linux 走 shim.c 的 molly_spawn，darwin 走 os.process_exec），handler 据
// 返回码决定「未发头时映射成 4xx」还是「发 200 + 原始字节」。观测行为一致（cgi-io 语义：命令非零
// 退出也照吐已产生的输出）。

import "core:c"
import "core:sys/posix"

// cgiio_max_args —— 与 file.exec 一致（file.c:1073）：整条命令行的参数个数上限。
cgiio_max_args :: 255

// cgiio_require_session —— 三件套都要求**已认证**会话（匿名/默认一律拒）。命令/路径本身能不能过，
// 另由 file.* ACL 兜底（fail-closed）。
cgiio_require_session :: proc(sid: string) -> bool {
	return len(sid) > 0 && sid != Sess_Default_ID
}

// cgiio_tokenize —— 把 cgi-io 的 command 串还原成 argv。前端 fs.js 对每个 token 先 `\`→`\\`、
// 再把空白 `\s`→`\<空白>`，用单个空格连接、整体 URL 编码（body 已由 Parse_Form 解好码）。这里做逆运算：
// 反斜杠转义下一个字符，未转义空格是分隔符，空 token 丢弃。
cgiio_tokenize :: proc(command_line: string) -> []string {
	argv: [dynamic]string
	cur: [dynamic]u8
	has := false // 当前是否有正在累积的 token（区分「空 token」与「无 token」）

	for i := 0; i < len(command_line); i += 1 {
		c := command_line[i]
		if c == '\\' {
			has = true
			if i+1 < len(command_line) {
				i += 1
				append(&cur, command_line[i])
			} else {
				append(&cur, '\\') // 结尾孤立反斜杠：按字面保留
			}
		} else if c == ' ' {
			if has {
				append(&argv, dup_token(cur))
				clear(&cur)
				has = false
			}
		} else {
			has = true
			append(&cur, c)
		}
	}
	if has {
		append(&argv, dup_token(cur))
	}
	delete(cur)
	return argv[:]
}

// dup_token —— 把一个 token 拷成独立 string（不能直接 string(cur[:])：cur 缓冲会被后续
// append 重分配，多个 token 会全部悬垂到同一块尾缓冲）。
dup_token :: proc(cur: [dynamic]u8) -> string {
	buf := make([]u8, len(cur))
	copy(buf, cur[:])
	return string(buf)
}

// CGI_Exec —— 执行 command（已 URL 解码、含反斜杠转义），把原始 stdout（want_stderr 时并入 stderr）
// 收进 data 返回。落 context.allocator。返回 ubus 状态码（Status_OK→200 由 handler 映射 HTTP）。
CGI_Exec :: proc(sid, command: string, want_stderr: bool) -> (data: []u8, status: i32) {
	if ! cgiio_require_session(sid) {
		return nil, Status_Permission_Denied
	}
	argv := cgiio_tokenize(command)
	if len(argv) == 0 || len(argv) > cgiio_max_args+1 {
		return nil, Status_Invalid_Argument
	}
	exe, st := file_exec_lookup(argv[0])
	if st != Status_OK {
		return nil, st // 找不到可执行 → Status_Not_Found
	}
	exe_canon, ok := file_canonicalize_path(exe)
	if ! ok {
		return nil, Status_Unknown_Error
	}
	// argv[0] 是原始命令名，就地换成规范化后的可执行路径（免拼接）。
	full := argv[:]
	full[0] = exe_canon

	// 与 ubus file.exec 同一道 ACL：路径或整条命令行必须被会话的 file.exec 白名单放行。
	if st := file_exec_check_acl(sid, exe_canon, full); st != Status_OK {
		return nil, st // 拒 → Status_Permission_Denied
	}

	sres := spawn_run(full, nil, nil, true)
	out, errb := sres.stdout, sres.stderr
	// cgi-io 语义：无论退出码，都把已产生的输出当 200 回吐。want_stderr 时 stderr 并入同一流（2>&1）。
	if want_stderr && len(errb) > 0 {
		joined := make([]u8, len(out) + len(errb))
		copy(joined, out)
		copy(joined[len(out):], errb)
		return joined, Status_OK
	}
	res := make([]u8, len(out))
	copy(res, out)
	return res, Status_OK
}

// CGI_Download —— 把 path 指向的文件内容收进 data 返回。权限名 "read"（与 file.read 同），含符号链接复查。
CGI_Download :: proc(sid, path: string) -> (data: []u8, status: i32) {
	if ! cgiio_require_session(sid) {
		return nil, Status_Permission_Denied
	}
	resolved, ent, st := file_check_path(sid, "read", path, true, false)
	if st != Status_OK {
		return nil, st
	}
	if cast(i64)ent.st.st_size >= file_max_size {
		return nil, Status_Not_Supported
	}
	content, rstatus := file_read_all(resolved)
	if rstatus != Status_OK {
		return nil, rstatus
	}
	return content, Status_OK
}

// CGI_Backup —— 跑固定的 `/sbin/sysupgrade -b -`，把归档（tar.gz）收进 data 返回。
// 与 CGI_Exec 同一道闸：先 require_session，再 file.exec ACL（这条命令必须在会话白名单里）。
CGI_Backup :: proc(sid: string) -> (data: []u8, status: i32) {
	if ! cgiio_require_session(sid) {
		return nil, Status_Permission_Denied
	}
	exe, st := file_exec_lookup("/sbin/sysupgrade")
	if st != Status_OK {
		return nil, st // 找不到 sysupgrade → Status_Not_Found
	}
	exe_canon, ok := file_canonicalize_path(exe)
	if ! ok {
		return nil, Status_Unknown_Error
	}
	full := []string{exe_canon, "-b", "-"}

	if st := file_exec_check_acl(sid, exe_canon, full); st != Status_OK {
		return nil, st
	}
	sres := spawn_run(full, nil, nil, true)
	out := sres.stdout
	res := make([]u8, len(out))
	copy(res, out)
	return res, Status_OK
}

// CGI_Upload —— ui.uploadFile 的落盘半（对齐 Go backend.CGIUpload）：把已解析出的 filedata 字节
// 写到 filename 指定的路径。安全闸同 file.write：先 require_session，再 file_check_path("write",...)，
// 以 O_WRONLY|O_CREAT|O_TRUNC + 0o644（对齐 Go 的 os.OpenFile 权限）打开并 fsync。multipart 解析、
// size/MD5/SHA256 累计在 handler 侧做（那里数据已整段缓冲在 req.body）。
CGI_Upload :: proc(sid, filename: string, data: []u8) -> i32 {
	if ! cgiio_require_session(sid) {
		return Status_Permission_Denied
	}
	resolved, _, st := file_check_path(sid, "write", filename, false, false)
	if st != Status_OK {
		return st
	}
	flags: posix.O_Flags = {.WRONLY, .CREAT, .TRUNC}
	fd := posix.open(file_cstr(resolved), flags, file_mode_from_bits(0o644))
	if cast(int)fd < 0 {
		return file_status_of_errno(posix.errno())
	}
	defer posix.close(fd)
	if len(data) > 0 {
		n := posix.write(fd, raw_data(data), cast(c.size_t)len(data))
		if n < 0 {
			return file_status_of_errno(posix.errno())
		}
	}
	if posix.fsync(fd) == .FAIL {
		return file_status_of_errno(posix.errno())
	}
	// 上游随后还调了全局 sync()；进程内等价物没有便携 API，省略（与 file_method_write 同一偏离）。
	return Status_OK
}
