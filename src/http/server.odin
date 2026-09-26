package http

import "core:fmt"
import "core:mem"
import "core:net"
import "core:sync"
import "core:thread"

// 一条已接受的连接。只在处理它的工作线程内有效。
Connection :: struct {
	socket: net.TCP_Socket,
	peer:   net.Endpoint,

	// 每请求 arena：请求开始前 reset，用来放请求体、以及后续步骤里生成的
	// 路径/JSON/渲染结果。一连接一线程，所以不需要加锁。
	// R6：回收是否真的发生只能靠真机 RSS 曲线验证，不能只看代码。
	arena:    mem.Dynamic_Arena,

	// 未消费的入站字节。用 context.allocator（工作线程上是堆），生命周期跟随连接；
	// keep-alive 下这里可能已经含着下一个请求的开头。
	inbox:    [dynamic]byte,
	// 上一个请求吃掉多少字节。延到下一次 read_request 开头才真正 remove_range，
	// 因为 handler 还持有指向 inbox 的 string（见 read_request）。
	consumed: int,
}

// 处理一个已解析的请求，把响应写出去。返回值是「这条连接还能继续用吗」，
// 与 req.keep_alive 相与后决定是否关闭。
//
// 错误响应的生成留在 http 层（协议问题），业务状态码由 handler 自己回。
Handler :: proc(s: ^Server, conn: ^Connection, req: ^Request) -> bool

Server :: struct {
	listener: net.TCP_Socket,
	handler:  Handler,
	docroot:  string,
	// LuCI 菜单目录（menu.d），由 main 从 --menu-dir 传入、去掉尾部 '/'。
	// http 包不解释它，只是转交给 handler——与 docroot 同样的处理方式。
	menu_dir: string,

	// /cgi-bin/luci 的子进程命令（--luci-cgi）。空串表示用内置的 Odin dispatcher
	// （P2 的形态，`src/luci`）；非空则按 ADR 0003 的 T1 桥接给设备上的 ucode。
	// 同样只是转交给 handler，http 包不解释它。
	luci_cgi: string,

	// 活跃连接数。只能通过 sync.atomic_* 访问：accept 循环与工作线程同时读写。
	live:     i32,
}

// 阻塞式 accept 循环。正常情况不返回（返回即 listener 失效）。
serve :: proc(s: ^Server) {
	for {
		client, source, err := net.accept_tcp(s.listener)
		if err != nil {
			// accept 失败通常是 ECONNABORTED / EMFILE 这类可恢复错误，
			// 让它杀掉整个服务是过度反应。
			fmt.eprintln("[molly] accept 失败:", err)
			continue
		}
		_ = source

		if sync.atomic_add(&s.live, 1) > MAX_CONNECTIONS {
			sync.atomic_sub(&s.live, 1)
			// 明确告诉客户端关连接，避免它以为是临时拥塞而重试
			busy := Connection {
				socket = client,
			}
			_ = respond(&busy, .Service_Unavailable, "server is busy\n")
			net.close(client)
			continue
		}

		// self_cleanup = true：线程结束时自动释放 Thread 结构，否则每来一个连接
		// 就漏一个 Thread。
		if thread.create_and_start_with_poly_data2(s, client, conn_thread, self_cleanup = true) == nil {
			fmt.eprintln("[molly] 创建线程失败，拒绝连接")
			sync.atomic_sub(&s.live, 1)
			net.close(client)
		}
	}
}

@(private)
conn_thread :: proc(s: ^Server, client: net.TCP_Socket) {
	// 新线程的默认 context 用的是堆分配器，temp_allocator 是线程私有的默认实现；
	// 这里只用自己的 arena，所以退出时不需要 default_temp_allocator_destroy。
	conn := Connection {
		socket = client,
		peer   = net.peer_endpoint(client) or_else net.Endpoint{},
	}
	mem.dynamic_arena_init(&conn.arena)
	conn.inbox = make([dynamic]byte, 0, READ_BUF_SIZE)

	defer {
		delete(conn.inbox)
		mem.dynamic_arena_destroy(&conn.arena)
		sync.atomic_sub(&s.live, 1)
		net.close(client)
	}

	_ = net.set_option(client, .Receive_Timeout, READ_TIMEOUT)
	_ = net.set_option(client, .Send_Timeout, WRITE_TIMEOUT)

	serve_connection(s, &conn)
}

// keep-alive 循环。协议层的错误（400/411/413）在这里回并关连接；
// 请求解析成功后才交给 handler。
@(private)
serve_connection :: proc(s: ^Server, conn: ^Connection) {
	req: Request
	for {
		// 上一轮的请求体、渲染结果等都在这里一次性回收
		mem.dynamic_arena_reset(&conn.arena)

		switch read_request(conn, &req) {
		case .Ok:
			// 继续往下
		case .Closed:
			return
		case .Bad_Request:
			_ = respond(conn, .Bad_Request, "bad request\n")
			return
		case .Head_Too_Large:
			_ = respond(conn, .Payload_Too_Large, "request header too large\n")
			return
		case .Length_Required:
			_ = respond(conn, .Length_Required, "length required\n")
			return
		case .Payload_Too_Large:
			_ = respond(conn, .Payload_Too_Large, "payload too large\n")
			return
		}

		if !s.handler(s, conn, &req) || !req.keep_alive {
			return
		}
	}
}