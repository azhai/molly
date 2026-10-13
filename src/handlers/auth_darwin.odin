package handlers

// auth_darwin —— 改密码的两个设备专属原语在开发机（macOS）上的桩。
//
// 设备改密依赖两样 macOS 上不存在/无意义的东西：设备形态的 /etc/shadow（molly 在 macOS 上没有
// 那套 rpcd 口令存储），以及 `openssl passwd -5`（macOS 的 openssl 是 LibreSSL，没有 passwd 子命令）。
// 所以这里让两个叶子直接回「不可用」，Serve_Auth 据此把改密请求导到 no_hasher —— 与 Go 版在
// 「设备上没有 openssl」那条路上的行为一致（宁可依赖现成实现，openssl 不在就明确报错，不留半截功能）。
//
// 真机（linux）用 auth_linux.odin 的真实实现；本文件只在 darwin target 参与编译（靠文件名后缀选中）。
//
// 因此改密的「成功路径」在 host 上不可达、也不该被单测断言——auth_test 只验到「无 openssl → no_hasher
// 的错误跳转」这条确定性分支（与 ubus handler 把成功路径交给阶段5 smoke 同一套门槛）。

// shadow_hash —— darwin 桩：不产 hash，恒回 no_hasher。
shadow_hash :: proc(password: string) -> (hash: string, code: string) {
	return "", "no_hasher"
}

// shadow_set_hash —— darwin 桩：不写 shadow，恒回 no_hasher。
shadow_set_hash :: proc(username, hash: string) -> (code: string) {
	return "no_hasher"
}
