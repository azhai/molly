package backend

import "core:testing"

// event_bus 是进程级全局单例；并发跑两个会改它的测试会互相串扰，故合并成一条顺序测试。
@(test)
test_event_bus :: proc(t: ^testing.T) {
	// ---- 扇出 ----
	sub, ok := Subscribe("probe")
	testing.expect(t, ok, "Subscribe 应成功")
	testing.expect_value(t, Count(), 1)

	Publish("probe", "notify", `{"n":1}`)
	ev, more := Recv(sub)
	testing.expect(t, more, "Recv 应拿到事件")
	testing.expect_value(t, ev.object, "probe")
	testing.expect_value(t, ev.method, "notify")
	testing.expect_value(t, ev.data, `{"n":1}`)
	Free_Event(ev)

	// 无订阅者时发布不得炸（且不应误投到别的 path）
	Publish("nobody", "x", "y")

	Unsubscribe(sub)
	testing.expect_value(t, Count(), 0)

	// ---- 容量上限 ----
	subs: [dynamic]^Subscription
	defer delete(subs)

	n := 0
	for i := 0; i < EVENT_BUS_MAX; i += 1 {
		s, ok2 := Subscribe("cap")
		if !ok2 {
			break
		}
		append(&subs, s)
		n += 1
	}
	testing.expect_value(t, n, EVENT_BUS_MAX)

	_, over := Subscribe("cap2") // 满了：新订阅应失败
	testing.expect(t, !over, "超容量应 Subscribe=false")

	for s in subs {
		Unsubscribe(s)
	}
	testing.expect_value(t, Count(), 0)
}
