package backend

// spawn_run（linux）—— 走 src/native/shim.c 的 molly_spawn：自带 fork/dup2/execv/poll/waitpid，
// 只等自己的 pid、容忍 ECHILD、绝不 trap，彻底绕开 core:os process_exec 在 _reap_terminated
// 里的 `unreachable()` → SIGTRAP 陷阱（详见 process_spawn.odin 顶注）。

import "core:strings"
import "bindings"

spawn_run :: proc(argv: []string, env: []string, stdin_data: []u8, stderr_capture: bool) -> Spawn_Result {
	res: Spawn_Result

	cargv := make([]cstring, len(argv) + 1)
	for s, i in argv {
		cs, _ := strings.clone_to_cstring(s)
		cargv[i] = cs
	}
	cargv[len(argv)] = nil

	cenv: []cstring
	if env != nil {
		cenv = make([]cstring, len(env) + 1)
		for s, i in env {
			cs, _ := strings.clone_to_cstring(s)
			cenv[i] = cs
		}
		cenv[len(env)] = nil
	}
	envp: ^cstring = nil
	if len(cenv) > 0 {
		envp = &cenv[0]
	}

	stdin_ptr: ^u8 = nil
	if len(stdin_data) > 0 {
		stdin_ptr = &stdin_data[0]
	}
	capture: i32 = 0
	if stderr_capture {
		capture = 1
	}

	out_so, out_se: cstring
	so_len, se_len, exited, code: i32

	rc := bindings.molly_spawn(
		&cargv[0], envp,
		stdin_ptr, i32(len(stdin_data)), capture,
		&out_so, &so_len, &out_se, &se_len,
		&exited, &code,
	)
	res.started = rc == 0
	res.exited = exited != 0
	res.code = int(code)
	res.stdout = spawn_take(out_so, so_len)
	res.stderr = spawn_take(out_se, se_len)
	return res
}

// spawn_take —— 把 C 侧 malloc 的 (ptr,len) 拷进当前 context 分配器并释放原缓冲。
// n 为准（二进制安全，命令输出/cgi-backup 归档都可能含 NUL）。
spawn_take :: proc(cs: cstring, n: i32) -> []u8 {
	if cs == nil {
		return nil
	}
	if n <= 0 {
		bindings.molly_free(transmute(rawptr)(cs))
		return nil
	}
	src := transmute([^]u8)(transmute(rawptr)(cs))
	out := make([]u8, int(n))
	copy(out, src[0:int(n)])
	bindings.molly_free(transmute(rawptr)(cs))
	return out
}
