package handlers

// cgi_run —— /cgi-bin/luci → 子进程的桥接里**带 I/O** 的那半（对齐 internal/handlers/cgi.go 的
// runCGI / cgiFail / exitDesc / splitCommand）。纯决策的两半（build_cgi_env / parse_cgi_response）
// 在 cgi.odin，已脱离套接字/进程在 host 单测里钉死；这里把它们接到真实的进程/管道上：
//
//   1. split_command 拆 --luci-cgi 的管理员固定命令；
//   2. build_cgi_env 造环境，req.body 作子进程 stdin；
//   3. backend.spawn_run 起子进程并**捕获** stdout（stderr 直通 molly 自己的 stderr，对齐 Go 让
//      ucode 报错进日志的意图）；
//   4. parse_cgi_response 解读 stdout；失败 → 500 带退出码与前 200 字节的 %q；成功 → http.Emit
//      （头名逐字节透传、Content-Length 由 Emit 重算、HEAD 有头无体、keep-alive 默认）。
//
// 进程执行统一收口到 backend.spawn_run（见 src/backend/process_spawn.odin）：linux 走 shim.c 的
// molly_spawn，用 poll 同时写 stdin、读 stdout/stderr，64KB 请求体超过管道缓冲也不死锁（sizeprobe
// 桩专门验这条）；darwin 宿主侧仍用 os.process_exec（内部一条短命写线程灌 stdin）。

import "core:os"
import "core:fmt"
import "molly:http"
import "molly:backend"

// split_command —— 命令按空格/制表符切分（不接受引号与转义）：--luci-cgi 是管理员配置的固定命令。
// 只切 ' ' 与 '\t'（对齐 Go 的 FieldsFunc，而非会多切 unicode 空白的 strings.Fields）。
split_command :: proc(cmd: string) -> [dynamic]string {
	parts: [dynamic]string
	i := 0
	for i < len(cmd) {
		if cmd[i] == ' ' || cmd[i] == '\t' {
			i += 1
			continue
		}
		start := i
		for i < len(cmd) && cmd[i] != ' ' && cmd[i] != '\t' {
			i += 1
		}
		append(&parts, cmd[start:i])
	}
	return parts
}

// exit_desc —— 子进程怎么结束的。Spawn_Result 用 code 同时承载「退出码」与「信号号」
// （started=false 是没跑起来 → "spawn failed"）；本桥接的诊断正文只需在脚本自身退出（如 broken.sh
// 的 exit 3）时报对数字，故统一报 `exit N`。
exit_desc :: proc(s: backend.Spawn_Result) -> string {
	if s.started {
		return fmt.tprintf("exit %d", s.code)
	}
	return "spawn failed"
}

// cgi_fail —— 桥接侧的错误：500 + text/plain，正文带结尾换行（对齐 Go 的 cgiFail）。
cgi_fail :: proc(res: ^http.Response, msg: string) {
	http.Respond(res, 500, fmt.tprintf("%s\n", msg), "text/plain; charset=utf-8")
}

// run_cgi —— 执行 --luci-cgi 命令，把它的 stdout 当响应回给客户端。
//   tree_path：菜单树路径（PATH_INFO 用它，非 URL；见 luci_tree_path）；
//   cmd：--luci-cgi 的值；ubus_socket：私有总线时给子进程的 MOLLY_UBUS_SOCKET；
//   prefix/strip：决定 SCRIPT_NAME（见 cgi_script_name）。
run_cgi :: proc(res: ^http.Response, req: ^http.Request, tree_path, docroot, cmd, ubus_socket, prefix, strip: string) {
	argv := split_command(cmd)
	if len(argv) == 0 {
		cgi_fail(res, "cgi command is empty")
		return
	}

	env := build_cgi_env(req, tree_path, docroot, ubus_socket, prefix, strip)

	// 请求体作子进程 stdin；stderr_capture=false → 子进程 stderr 直通 molly 的 fd 2。
	// 缓冲区落在 context.allocator（每请求 arena），随请求回收，无需显式 delete。
	sres := backend.spawn_run(argv[:], env[:], req.body, false)

	// ucode 的报错要能在 molly 日志里看到。linux 侧 stderr 已直通（sres.stderr 为空，跳过）；
	// darwin 宿主侧 spawn_run 仍捕获 stderr，这里转发一次。
	if len(sres.stderr) > 0 {
		_, _ = os.write(os.stderr, sres.stderr)
	}

	raw := string(sres.stdout)
	resp, ok := parse_cgi_response(raw)
	if ! ok {
		head := raw
		if len(head) > 200 {
			head = head[0:200]
		}
		// 带上子进程的退出情况：`exit N` + 空 stdout，最常见就是 --luci-cgi 指错了可执行文件
		// （典型：填成 uhttpd.uc 那种模板，它把语法错打到 stderr、stdout 什么都不给）。stderr 已转发到日志。
		msg := fmt.tprintf("invalid CGI response (%s): %q", exit_desc(sres), head)
		cgi_fail(res, msg)
		return
	}

	// Content-Type 恒由脚本给（parse 已保证非空）；其余响应头原样透传（Set-Cookie 的 path 已在
	// parse 阶段放宽）。Content-Length/Connection 在 parse 阶段已丢弃 → 由 Emit 按真实 body 重算。
	hdrs: [dynamic]http.Header
	defer delete(hdrs)
	append(&hdrs, http.Header{"Content-Type", resp.content_type})
	for e in resp.extra {
		append(&hdrs, http.Header{e.name, e.value})
	}
	http.Emit(res, resp.code, hdrs[:], resp.body)
}
