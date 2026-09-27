package backend

import "core:c"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:sync"
import "core:sys/posix"

// ---------------------------------------------------------------------------
// 事件总线（P3-7）：把 ubus 的对象通知扇出给 SSE 订阅者
//
// 上游 uhttpd 的做法（`ubus.c:373-424`）：`GET /ubus/subscribe/<对象路径>` → ACL
// `:subscribe` → `ubus_register_subscriber` + `ubus_lookup_id` + `ubus_subscribe`，
// 通知回调在 **uloop 线程**里把 `event: <method>\ndata: <json>\n\n` 写回 HTTP 连接。
// uhttpd 是单线程事件循环，所以回调与写回在同一个线程里；molly 是**一连接一线程**，
// 回调发生在 ubus 线程（ADR 0001），写回必须在 HTTP 线程——中间用**每条订阅一根管道**
// 搭桥（ADR 0001 第 3 条）。
//
// 这个总线是**平台无关**的那一半：谁都可以往里发布（`event_bus_publish`），
// 真正的源头有两个：
//   linux（S2）：ubus 线程的订阅回调把通知发进来；
//   darwin（S1，测试用）：`molly.probe` 的 `emit` 方法（**测试专用，真机没有**）。
//
// 容量：与 HTTP 层的 32 连接上限对齐（订阅挂在一个连接上），满了就订阅失败。
// ---------------------------------------------------------------------------

// 一条订阅 = 一根管道。写端给事件源，读端给 HTTP 线程（它 poll 这根 fd）。
Subscription :: struct {
	id:     u64,
	path:   string,
	rfd:    posix.FD,
	wfd:    posix.FD,
	closed: bool,
}

// 管道里的一条记录（一次 write 写完，读侧按 '\n' 切）：
//   <method> "\t" <data json> "\n"
//
// 不用 JSON 包一层是为了让「事件源在 ubus 线程、只做一次 write」这件事保持无分配
// （发布路径上不该分配内存：它跑在事件回调里）。
EVENT_BUS_MAX :: 32

@(private)
g_bus_lock: sync.Mutex
@(private)
g_bus:      [EVENT_BUS_MAX]^Subscription
@(private)
g_bus_n:    int
@(private)
g_bus_next: u64

// 订阅一个对象路径。返回 nil 表示满了或管道建不起来。
event_bus_subscribe :: proc(path: string, alloc: mem.Allocator) -> (sub: ^Subscription, ok: bool) {
	fds: [2]posix.FD
	if posix.pipe(&fds) != .OK {
		return nil, false
	}
	// 两端都非阻塞：写端满了**丢事件**而不是把 ubus 线程卡死（上游在单线程里
	// 直接写 socket，写不进去也是同一个结局）；读端靠 poll 等，不需要阻塞。
	_ = posix.fcntl(fds[0], .SETFL, c.int(posix.O_NONBLOCK))
	_ = posix.fcntl(fds[1], .SETFL, c.int(posix.O_NONBLOCK))

	sub = new(Subscription, alloc)
	sub.path = strings.clone(path, alloc)
	sub.rfd = fds[0]
	sub.wfd = fds[1]

	sync.lock(&g_bus_lock)
	defer sync.unlock(&g_bus_lock)

	if g_bus_n >= EVENT_BUS_MAX {
		posix.close(sub.rfd)
		posix.close(sub.wfd)
		free(sub)
		return nil, false
	}
	g_bus_next += 1
	sub.id = g_bus_next
	g_bus[g_bus_n] = sub
	g_bus_n += 1

	// 第一条订阅这个 path 的连接 → 通知平台侧开始接收该对象的事件
	// （linux：ubus 线程里 register_subscriber + subscribe；darwin：无事可做）
	if bus_count_for(path) == 1 {
		sse_watch_start(path)
	}
	return sub, true
}

// 还在订阅 path 的连接数（调用方须持 g_bus_lock）。
@(private)
bus_count_for :: proc(path: string) -> int {
	n := 0
	for i in 0 ..< g_bus_n {
		if g_bus[i] != nil && !g_bus[i].closed && g_bus[i].path == path {
			n += 1
		}
	}
	return n
}

// 注销并关掉两端。重复调用是安全的（closed 记过了）。
event_bus_unsubscribe :: proc(sub: ^Subscription) {
	if sub == nil {
		return
	}
	sync.lock(&g_bus_lock)
	if !sub.closed {
		path := sub.path
		sub.closed = true
		for i in 0 ..< g_bus_n {
			if g_bus[i] == sub {
				g_bus[i] = g_bus[g_bus_n - 1]
				g_bus_n -= 1
				break
			}
		}
		// 最后一条订阅这个 path 的连接走了 → 平台侧可以停掉订阅
		if bus_count_for(path) == 0 {
			sse_watch_stop(path)
		}
		posix.close(sub.wfd)
		posix.close(sub.rfd)
	}
	sync.unlock(&g_bus_lock)
}

// ---------------------------------------------------------------------------
// 平台侧的「开始/停止接收某个对象的通知」
//
// linux：把命令排进 ubus 线程（所有 ctx/循环改动都在那个线程里做，ADR 0001），
//        由它在 uloop 里 `ubus_register_subscriber` + `ubus_subscribe`；
//        通知到达时调 `event_bus_publish`。
// darwin：没有 ubus，事件是 `molly.probe/emit` 直接推进来的，所以是空实现。
// ---------------------------------------------------------------------------

// 发布一条通知：扇给所有订阅了 path 的连接。
//
// 只做一次 write（记录本身小于 PIPE_BUF 时是原子的）；写端非阻塞，满了就丢
// ——SSE 是尽力而为的推送，丢一条事件比把事件源线程卡住好。
event_bus_publish :: proc(path, method, data_json: string, alloc: mem.Allocator) {
	record := fmt.aprintf("%s\t%s\n", method, data_json, allocator = alloc)
	defer delete(record)

	buf := transmute([]byte)(record)
	sync.lock(&g_bus_lock)
	defer sync.unlock(&g_bus_lock)

	for i in 0 ..< g_bus_n {
		sub := g_bus[i]
		if sub == nil || sub.closed || sub.path != path {
			continue
		}
		_ = posix.write(sub.wfd, &buf[0], c.size_t(len(buf)))
	}
}

// 当前订阅数（测试/诊断用）。
event_bus_count :: proc() -> int {
	sync.lock(&g_bus_lock)
	defer sync.unlock(&g_bus_lock)
	return g_bus_n
}
