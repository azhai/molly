package backend

// spawn_run（darwin/宿主）—— 仍用 core:os 的 process_exec：宿主没有 uloop 服务线程，
// 不会触发 _reap_terminated 的 unreachable/SIGTRAP 陷阱，host 单测与冒烟因此保持原行为。
// stderr 恒被捕获（capture_stderr 在宿主侧忽略），需要转发的调用点自行写 os.stderr。

import "core:os"
import "core:thread"

// stdin_pw —— 交给写线程的一份最小状态：管道写端 + 待灌的字节。以指针传线程（8 字节，落在
// thread 的内联参数容量内）；父侧在线程 join 之后才让 arena 回收，故其指向的内存全程有效。
stdin_pw :: struct {
	w:    ^os.File,
	data: []u8,
}

// write_stdin_and_close —— 线程体：把 data 全量写进管道写端，处理短写；管道断开（子进程没读全
// 就回响应）则静默止。无论如何都 close 写端 → 子进程 stdin 读到 EOF。
write_stdin_and_close :: proc(d: ^stdin_pw) {
	defer os.close(d.w)
	off := 0
	for off < len(d.data) {
		n, err := os.write(d.w, d.data[off:])
		if err != nil || n <= 0 {
			return
		}
		off += n
	}
}

spawn_run :: proc(argv: []string, env: []string, stdin_data: []u8, stderr_capture: bool) -> Spawn_Result {
	_ = stderr_capture
	res: Spawn_Result

	desc: os.Process_Desc
	desc.command = argv
	if env != nil {
		desc.env = env
	}

	writer: ^thread.Thread = nil
	// 恒给子进程一根自己的 stdin 管道（对齐 linux 侧 molly_spawn 的 /dev/null、以及旧 run_cgi
	// 的“总是造管道并关闭”）。否则 desc.stdin=nil 会继承服务进程的 stdin，像 echo.sh 那种
	// 末尾 `cat` 的桩就会读父标准输入卡死。“无数据”时立刻关闭写端 → 子进程读到 EOF。
	r, w, perr := os.pipe()
	if perr != nil {
		res.started = false
		return res
	}
	if len(stdin_data) > 0 {
		wd := new(stdin_pw)
		wd.w = w
		wd.data = stdin_data
		writer = thread.create_and_start_with_poly_data(wd, write_stdin_and_close)
	} else {
		os.close(w) // 空 stdin → 立即 EOF
	}
	desc.stdin = r
	defer os.close(r)

	state, out, errb, err := os.process_exec(desc, context.allocator)
	if writer != nil {
		thread.join(writer)
	}
	res.started = err == nil
	res.exited = state.exited
	res.code = state.exit_code
	res.stdout = out
	res.stderr = errb
	return res
}
