package backend

// platform_hooks_linux —— session 三个平台钩子里「密码校验」与「acl.d 目录」的
// linux 真实现（对齐 internal/backend/linux.go 的 sessionVerifyPassword / sessionACLDir）。
//
// uci 数据源那份钩子（hook_uci_sections）在 uci_provider_linux.odin 里装，本文件补齐另外两个。
// 三者都由 @(init) 早于 main 覆盖包级钩子变量；darwin 上本文件被平台文件名（_linux）排除，
// session_ensure_store 的 nil 守卫会退化成 platform_hooks.odin 里的宿主假实现，互不干扰。
//
// 密码：C 侧 molly_verify_password（shim.c）已含全部语义——空 hash → 通过；"$p$xxx" 前缀
// → 查 /etc/shadow 里用户 xxx 的 hash 递归比对；否则 crypt(3) 比对。本层只做 string→cstring
// 转换与返回值判定，**不**在 Odin 侧重复那些分支（保持与 Go 版一样的薄封装）。
//
// acl.d：真机是 /usr/share/rpcd/acl.d（session.h 的 RPC_SESSION_ACL_DIR）；MOLLY_ACL_DIR
// 可覆盖（与宿主实现同一变量名，方便测试与设备冒烟指到别处）。

import "core:os"
import "core:strings"

import "bindings"

// linux_verify_password —— crypt(3) + /etc/shadow 比对。入参 cstring 用
// strings.clone_to_cstring（落 context.allocator，随请求 arena 回收），**不能** molly_free
//（那是 C 的 free，分配器不匹配）；与 uci_provider_linux 的 uci_cstr 入参约定一致。
linux_verify_password :: proc(hash, password: string) -> bool {
	chash := strings.clone_to_cstring(hash)
	cpass := strings.clone_to_cstring(password)
	return bindings.molly_verify_password(chash, cpass) != 0
}

// linux_acl_dir —— acl.d 目录；env 覆盖优先，否则设备默认路径。
linux_acl_dir :: proc() -> string {
	if d := os.get_env("MOLLY_ACL_DIR", context.allocator); d != "" {
		return d
	}
	return "/usr/share/rpcd/acl.d"
}

@(init)
install_linux_session_hooks :: proc "contextless" () {
	hook_verify_password = linux_verify_password
	hook_acl_dir         = linux_acl_dir
}
