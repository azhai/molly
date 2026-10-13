package main

// 阶段 0 工具链 spike：证明「Odin 用 extern "C" 声明的 C 符号」
// 能在两阶段构建里被解析——
//   1) odin build -build-mode:obj -target:linux_arm64 → .o
//   2) zig cc -target aarch64-linux-musl --sysroot=<OpenWrt sysroot> → 可执行
// 这里引用真实的 libuci（uci_alloc_context/uci_free_context）。
//
// 注意：本机是 macOS，没有 libuci，所以这个 spike 只在 target 模式验证；
// host 模式（假数据）留到阶段 1 绑定层再谈。

import "core:fmt"

// 声明外部库名（供 `foreign libuci {}` 引用）；交叉场景我们只到 .o，
// 真正链接由第二阶段 zig cc 用 -luci 完成，所以这里的 `system:uci` 不会真的让 odin 去链。
foreign import libuci "system:uci"

// libuci 里我们只要两个函数就够证明「外部 C 符号能链接」。
// 用 `---` 声明无体的外部过程（link name 默认 = 标识符名，按 C 约定）；
// 因为是 -build-mode:obj（只编不链），odin 不会真去系统链接，符号交给 zig cc 解析。
foreign libuci {
	uci_alloc_context :: proc() -> rawptr ---
	uci_free_context  :: proc(ctx: rawptr) ---
}

main :: proc() {
	ctx := uci_alloc_context()
	fmt.println("spike: uci_alloc_context ->", ctx)
	if ctx != nil {
		uci_free_context(ctx)
		fmt.println("spike: uci_free_context ok")
	} else {
		fmt.println("spike: 符号已链接（alloc 返回 nil 也无所谓，链接成功即达标）")
	}
}
