package backend

// process_spawn —— 子进程执行的平台无关契约（对齐 Go 的 os/exec 观测语义）。
//
// 为什么要自己包一层、而不是直接 core:os 的 process_exec：Odin 的 process_exec 在
// linux 上经 _process_start + _reap_terminated，后者对 waitid 返回的 info.code 做
// switch，一旦子进程被别的收尸者抢先回收（molly 服务线程里 libubox uloop 的
// waitpid(-1) 就是这种角色），waitid 返 ECHILD、info 未填充、code=0 → 命中
// `case .NONE: unreachable()` → 裸 SIGTRAP 崩掉整个进程。故：
//   - linux（process_spawn_linux.odin）：走 src/native/shim.c 的 molly_spawn
//     （自带 fork/dup2/execv/poll/waitpid，只等自己的 pid、容忍 ECHILD、绝不 trap）；
//   - darwin（process_spawn_darwin.odin）：仍用 os.process_exec（宿主无 uloop 服务线程，
//     不会触发该陷阱；host 单测/冒烟因此保持原行为）。
//
// 四个调用点（file.exec、--luci-cgi、cgi-io、改密码 openssl）统一走 spawn_run。

// Spawn_Result —— 一次子进程执行的结局。
Spawn_Result :: struct {
	started: bool, // 子进程被成功 fork+exec（false → 启动失败：调用方按 127 / "spawn failed" 处理）
	exited:  bool, // true → 正常退出（code=退出码）；false → 被信号终止（code=信号号）
	code:    int,  // 退出码或信号号
	stdout:  []u8, // 捕获的标准输出
	stderr:  []u8, // capture_stderr=false 时通常为空（子进程 stderr 直通 molly fd 2）
}

// spawn_exit_code —— 把结局转成 file.exec 的 code 字段，逐条对齐 Go 的 fileExecExitCode：
// 未启动 → 127；被信号杀 → 0xff；正常退出 → 实际退出码。
spawn_exit_code :: proc(res: Spawn_Result) -> int {
	if ! res.started {
		return 127
	}
	if ! res.exited {
		return 0xff
	}
	return res.code
}
