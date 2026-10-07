// 一次性探针：确认 Odin 的 defer 是「块作用域」还是「函数作用域」。
// 结论决定 src/backend/linux.odin 四个 handler 里 `defer c_free(js)` 是否在
// `params = string(js)` 之后立刻触发（即 params 是否悬垂）。
package main

import "core:fmt"

main :: proc() {
	s := "outer"
	{
		js := "inner"
		defer fmt.println("[defer] 触发，js =", js)
		s = js
	}
	fmt.println("[main] 块结束后读 s =", s)
}