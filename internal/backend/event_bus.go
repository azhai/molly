package backend

import "sync"

// 事件总线（M4 / P3-7）：把 ubus 的对象通知扇出给 SSE 订阅者。
//
// 对应 Odin 版 src/backend/event_bus.odin。上游 uhttpd 是单线程事件循环，通知回调
// 直接在同一个线程里写回 HTTP 连接（ubus.c:373-424）；molly 是「一连接一线程」
// （ADR 0001），Odin 版用「每条订阅一根管道」在 ubus 线程与 HTTP 线程之间搭桥。
//
// Go 版用带缓冲的 channel 达到同一效果，且不需要平台文件描述符：HTTP 侧 select
// channel，事件源侧非阻塞投递（满了丢事件，等价于 Odin 写端的 O_NONBLOCK）。
//
// 事件源有两个：
//   linux（M5）：ubus 线程的订阅回调把通知投进来；
//   darwin（M4，测试用）：`molly.probe` 的 `notify` 直接 Publish（真机上没有该方法）。
//
// 容量与 HTTP 层的 32 连接上限对齐：订阅挂在一个连接上，满了订阅失败。

// Event 是一条通知（对应 Odin 总线里的 `<method>\t<data>` 记录）。
type Event struct {
	// Object 是通知来自的对象路径（Subscribe 时已按 path 过滤，这里冗余保存便于诊断）。
	Object string
	// Method 是事件名（ubus 通知的 method），SSE 里成为 `event: <method>`。
	Method string
	// Data 是事件体 JSON 文本，SSE 里成为 `data: <data>`。
	Data string
}

const (
	// eventBusMax 是最多同时存在的订阅数（与 Odin 的 EVENT_BUS_MAX 对齐）。
	eventBusMax = 32
	// eventBusBacklog 是单条订阅的缓冲深度。满了丢事件（SSE 是尽力而为的推送）。
	eventBusBacklog = 16
)

var (
	busMu   sync.Mutex
	busSubs = map[string]map[int]chan Event{}
	busNext int
)

// Subscribe 订阅某个对象路径的事件。返回值：
//
//	ch    只读事件通道（注销后会被关闭，读侧据此收尾）
//	unsub 注销函数，重复调用安全
//	ok    容量满时 false
//
// 第一条订阅某个 path 的连接会触发平台侧的 sseWatchStart（linux：真的去
// ubus_subscribe；darwin：空实现），最后一条离开时触发 sseWatchStop。
func Subscribe(path string) (<-chan Event, func(), bool) {
	busMu.Lock()
	defer busMu.Unlock()

	if busCountLocked() >= eventBusMax {
		return nil, nil, false
	}
	busNext++
	id := busNext
	ch := make(chan Event, eventBusBacklog)

	m, ok := busSubs[path]
	if !ok {
		m = map[int]chan Event{}
		busSubs[path] = m
	}
	m[id] = ch
	if len(m) == 1 {
		sseWatchStart(path)
	}

	unsub := func() {
		busMu.Lock()
		defer busMu.Unlock()
		m, ok := busSubs[path]
		if !ok {
			return
		}
		if _, ok := m[id]; !ok {
			return
		}
		delete(m, id)
		close(ch)
		if len(m) == 0 {
			delete(busSubs, path)
			sseWatchStop(path)
		}
	}
	return ch, unsub, true
}

// Publish 发布一条通知：扇给所有订阅了 path 的连接。非阻塞——某条订阅的缓冲满了
// 就丢这条事件，不拖住事件源线程。
func Publish(path, method, data string) {
	busMu.Lock()
	defer busMu.Unlock()
	for _, ch := range busSubs[path] {
		select {
		case ch <- Event{Object: path, Method: method, Data: data}:
		default:
		}
	}
}

// EventBusCount 当前订阅数（测试/诊断用）。
func EventBusCount() int {
	busMu.Lock()
	defer busMu.Unlock()
	return busCountLocked()
}

// busCountLocked 还在订阅的连接总数（调用方须持 busMu）。
func busCountLocked() int {
	n := 0
	for _, m := range busSubs {
		n += len(m)
	}
	return n
}
