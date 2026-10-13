package backend

// event_bus —— 把 ubus 的对象通知扇出给 SSE 订阅者（逐条对齐 internal/backend/event_bus.go）。
//
// 模型：一连接一线程（HTTP 侧）↔ ubus 事件线程之间，每条订阅一根有缓冲的 chan。
//   - Subscribe：分配一根 backlog 深度的通道；首条订阅某 path 触发 watch_start（平台侧真去
//     ubus_subscribe；darwin/未接是空实现），末条离开触发 watch_stop。
//   - Publish  ：非阻塞 try_send，某订阅缓冲满就丢这条事件（SSE 尽力而为，不拖住事件源线程）。
//   - Recv     ：HTTP 侧阻塞读，直到通道被 close（注销后 ok=false 收尾）。
//
// 跨线程字符串所有权：Event 的三段文本共用一块 b.alloc 分配的后备 buf（Publish 造，消费方
// Recv 后必须 Free_Event 一次回收）；try_send 失败（满）则由发布方就地回收，绝不泄漏。
//
// 有界：订阅上限与 HTTP 层 32 连接对齐，满了 Subscribe 返回 ok=false。

import "core:sync"
import "core:sync/chan"
import "core:mem"
import "base:runtime"

Event :: struct {
	object: string, // 通知来源对象路径（已按 path 过滤，冗余保存便于诊断）
	method: string, // 事件名 → SSE `event:`
	data:   string, // 事件体 JSON → SSE `data:`
	buf:    []byte, // 上面三段的后备存储；Free_Event 统一释放
}

Subscription :: struct {
	id:       int,
	path:     string, // = path_buf 的视图
	path_buf: []byte, // Subscribe 分配，Unsubscribe 释放
	watched:  bool,   // 本订阅是否触发了 watch_start（用于末条 watch_stop）
	ch:       chan.Chan(Event),
}

EVENT_BUS_MAX     :: 32
EVENT_BUS_BACKLOG :: 16

Event_Key :: struct { path: string, id: int }

bus_state :: struct {
	alloc: mem.Allocator, // 常驻分配器（进程默认），绝不能是某请求的 arena
	mu:    sync.Mutex,
	subs:  map[Event_Key]^Subscription,
	next:  int,
	count: int,
	// 平台侧的订阅/watch 钩子（linux 接 ubus_subscribe；darwin 置空）。
	watch_start: proc(path: string),
	watch_stop:  proc(path: string),
}

b: bus_state

// ensure_bus —— 首次用到时绑常驻堆分配器并建 map（调用方持 b.mu，且在有 context 的正常过程里）。
// 事件总线跨线程、长生命周期 → 绑常驻分配器，绝不能是某请求的 arena（handler 里 context.allocator 会被临时切走）。
ensure_bus :: proc() {
	if b.subs != nil {
		return
	}
	b.alloc = runtime.default_allocator()
	b.subs  = make(map[Event_Key]^Subscription, 0, b.alloc)
}

// Set_Watch_Hooks —— 平台层注册首/末订阅的 watch 回调（未设则不触发）。
Set_Watch_Hooks :: proc(start, stop: proc(path: string)) {
	b.watch_start = start
	b.watch_stop  = stop
}

// Subscribe —— 订阅某对象路径。返回堆上的 Subscription（用完务必 Unsubscribe）；容量满 ok=false。
Subscribe :: proc(path: string) -> (sub: ^Subscription, ok: bool) {
	sync.mutex_lock(&b.mu)
	defer sync.mutex_unlock(&b.mu)

	ensure_bus()
	if b.count >= EVENT_BUS_MAX {
		return nil, false
	}

	c, cerr := chan.create_buffered(chan.Chan(Event), EVENT_BUS_BACKLOG, b.alloc)
	if cerr != nil {
		return nil, false
	}

	pb := make([]byte, len(path), b.alloc)
	copy(pb, path)

	sub = new(Subscription, b.alloc)
	if sub == nil {
		chan.destroy(c)
		delete(pb, b.alloc)
		return nil, false
	}
	sub^ = Subscription{
		id       = b.next + 1,
		path     = string(pb),
		path_buf = pb,
		ch       = c,
	}

	// 该 path 之前有没有别的订阅？没有 → 本条是首条，触发 watch_start。
	first := true
	for key, _ in b.subs {
		if key.path == path {
			first = false
			break
		}
	}
	if first && b.watch_start != nil {
		b.watch_start(path)
		sub.watched = true
	}

	b.next += 1
	b.subs[Event_Key{string(pb), sub.id}] = sub
	b.count += 1
	return sub, true
}

// Unsubscribe —— 注销并关闭通道（重复调用安全：已注销则静默返回）。
Unsubscribe :: proc(sub: ^Subscription) {
	if sub == nil {
		return
	}
	sync.mutex_lock(&b.mu)
	defer sync.mutex_unlock(&b.mu)

	key := Event_Key{sub.path, sub.id}
	if _, has := b.subs[key]; !has {
		return // 已注销
	}
	delete_key(&b.subs, key)

	// 末条离开该 path？（注销本条后再无同 path 的订阅）
	last := true
	for k, _ in b.subs {
		if k.path == sub.path {
			last = false
			break
		}
	}
	if sub.watched && last && b.watch_stop != nil {
		b.watch_stop(sub.path)
	}

	chan.close(sub.ch)   // 唤醒 Recv → ok=false
	chan.destroy(sub.ch) // 释放通道缓冲（b.alloc）
	delete(sub.path_buf, b.alloc)
	free(sub, b.alloc)
	b.count -= 1
}

// Publish —— 扇给所有订阅了 path 的连接；缓冲满则丢（并就地回收该副本）。
Publish :: proc(path, method, data: string) {
	sync.mutex_lock(&b.mu)
	defer sync.mutex_unlock(&b.mu)

	any := false
	for _, sub in b.subs {
		if sub.path != path {
			continue
		}
		any = true
		ev := build_event(path, method, data)
		if ! chan.try_send(sub.ch, ev) {
			Free_Event(ev) // 满了：发送失败，发布方回收
		}
	}
	_ = any
}

// Recv —— 阻塞取一条事件；通道关闭后返回 ok=false。取到的事件用完后必须 Free_Event。
Recv :: proc(sub: ^Subscription) -> (ev: Event, ok: bool) {
	return chan.recv(sub.ch)
}

// Try_Recv —— 非阻塞取一条事件：有则 (ev,true)，缓冲空/未就绪则 (空,false)。供 SSE 轮询（配合
// 心跳与断开检测，不像 Recv 那样死等）。取到 (ev,true) 后同样须 Free_Event。
Try_Recv :: proc(sub: ^Subscription) -> (ev: Event, ok: bool) {
	return chan.try_recv(sub.ch)
}

// Free_Event —— 回收一条事件的后备缓冲（所有权转移的终点）。
Free_Event :: proc(ev: Event) {
	if len(ev.buf) > 0 {
		delete(ev.buf, b.alloc)
	}
}

// Count —— 当前订阅数（测试/诊断）。
Count :: proc() -> int {
	sync.mutex_lock(&b.mu)
	defer sync.mutex_unlock(&b.mu)
	return b.count
}

// build_event —— 把三段文本拷进一块 b.alloc 缓冲，字段是其切片视图。
build_event :: proc(path, method, data: string) -> Event {
	n := len(path) + len(method) + len(data) + 3
	buf := make([]byte, n, b.alloc)
	i := 0
	write_field :: proc(dst: []byte, at: int, s: string) -> int {
		copy(dst[at:], s)
		dst[at + len(s)] = 0
		return at + len(s) + 1
	}
	i = write_field(buf, i, path)
	m0 := i
	i = write_field(buf, i, method)
	d0 := i
	i = write_field(buf, i, data)
	_ = i
	return Event{
		object = string(buf[0 : len(path)]),
		method = string(buf[m0 : m0 + len(method)]),
		data   = string(buf[d0 : d0 + len(data)]),
		buf    = buf,
	}
}
