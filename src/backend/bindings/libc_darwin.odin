#+build darwin
package bindings

// darwin 侧的 libc 绑定。目前只有 realpath —— P3-4（file 对象）的符号链接复查要用它：
// 上游 file.c:261-359 在用文本路径做完 ACL 检查之后，还要用 realpath(3) 解析一次，
// 对**解析后的真实路径**再查一遍 ACL，否则「目录里放一个符号链接」就能绕过授权。
//
// 为什么不用 core:os：Odin 的 os 没有 realpath（get_absolute_path 只做文本规范化，
// 不解析符号链接）。

import "core:c"

foreign import libc "system:c"

foreign libc {
	// realpath(3)：resolved 必须是 PATH_MAX 字节的缓冲；返回 resolved 或 nil。
	@(link_name = "realpath")
	c_realpath :: proc(path: cstring, resolved: [^]u8) -> cstring ---
}
