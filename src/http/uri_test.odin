package http

import "core:mem"
import "core:testing"

// 单元测试：URI 规范化（本项目的安全边界，上游对应 uhttpd 的 uh_http_decode + 路径检查）。
//
// 运行：odin test -collection:molly=src src/http   （或 ./tests/unit.sh 一次跑全部包）
//
// 三类断言与 Uri_State 一一对应：Ok 看规范化结果，Bad 看 400，Escaping 看 403。
// 注意 normalize_path 只做「切段后的规范化」，不做 URL 语义（不还原 "." → 目录）。

// odin test 默认多线程跑用例，所以每个用例要**自己**一份 arena（共享全局会互相踩）。
// 用法：alloc, ar := mk_arena(); defer drop_arena(ar)
@(private)
mk_arena :: proc() -> (mem.Allocator, ^mem.Dynamic_Arena) {
	a := new(mem.Dynamic_Arena) // 零初始化
	mem.dynamic_arena_init(a)
	return mem.dynamic_arena_allocator(a), a
}

@(private)
drop_arena :: proc(a: ^mem.Dynamic_Arena) {
	mem.dynamic_arena_destroy(a)
	free(a)
}

@(test)
test_normalize_path_ok :: proc(t: ^testing.T) {
	alloc, ar := mk_arena()
	defer drop_arena(ar)
	Cases :: struct {
		raw, want: string,
	}
	cases := []Cases{
		{"/", "/"},
		{"/index.html", "/index.html"},
		{"/luci-static/x.css?v=1", "/luci-static/x.css"}, // 查询串被剥掉
		{"/a#frag", "/a"}, // 片段同理
		{"//a//b", "/a/b"}, // 空段被压掉
		{"/a/./b", "/a/b"}, // "." 段被压掉
		{"/a/b/", "/a/b"}, // 尾部空段被压掉
		{"/%69ndex.html", "/index.html"}, // 百分号解码（%69 = 'i'）
		{"/a%20b", "/a b"}, // 解码后是普通字符，放行
		{"/%2e/x", "/x"}, // %2e = "." → 单点段被压掉
		{"/admin/status/overview", "/admin/status/overview"}, // 深层目录原样
	}
	for c in cases {
		got, state := normalize_path(c.raw, alloc)
		testing.expectf(t, state == .Ok, "%q 应为 Ok，实际 %v", c.raw, state)
		testing.expectf(t, got == c.want, "%q 规范化后应为 %q，实际 %q", c.raw, c.want, got)
	}
}

@(test)
test_normalize_path_bad :: proc(t: ^testing.T) {
	alloc, ar := mk_arena()
	defer drop_arena(ar)
	cases := []string{
		"", // 空目标
		"index.html", // 不以 '/' 开头（parse_head 已保证，这里兜底）
		"/bad%zz", // 非法十六进制
		"/bad%2", // 编码被截断
		"/%00", // NUL：会在 C 文件 API 上截断路径
		"/a%1fb", // 解码出控制字符
		"/a\x7fb", // DEL 同样拒绝
	}
	for c in cases {
		got, state := normalize_path(c, alloc)
		testing.expectf(t, state == .Bad, "%q 应为 Bad，实际 %v（got=%q）", c, state, got)
		testing.expectf(t, got == "", "%q 为 Bad 时应回空串，实际 %q", c, got)
	}
}

@(test)
test_normalize_path_escaping :: proc(t: ^testing.T) {
	alloc, ar := mk_arena()
	defer drop_arena(ar)
	cases := []string{
		"/../etc/passwd",
		"/a/../../etc/passwd",
		"/%2e%2e/etc/passwd", // 解码后是 ".."
		"/a/%2E%2E/b", // 大写十六进制同样解码
		"/a/..%2f..", // 解码出 '/' 拼成 ".." 段
	}
	for c in cases {
		got, state := normalize_path(c, alloc)
		testing.expectf(t, state == .Escaping, "%q 应为 Escaping，实际 %v（got=%q）", c, state, got)
	}
}
