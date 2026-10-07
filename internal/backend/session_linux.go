//go:build linux

package backend

import "github.com/azhai/molly/internal/cbind"

// session 对象的密码校验（linux 真实现）。
//
// 对齐 Odin src/backend/linux.odin 的 session_verify_password（1088-1114）+ shadow_hash
// （1116-1142）+ libc.odin 的 crypt：C 侧在 cbind/shim.c 的 molly_verify_password 里，
// 这里只是薄封装（darwin.go 有同名同签名的假实现）。

func sessionVerifyPassword(hash, password string) bool {
	return cbind.VerifyPassword(hash, password)
}
