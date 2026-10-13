package handlers

// static_test —— resolve_static 的纯决策单测（host，真读写一个临时 docroot）。
// 覆盖 cgi-bin→403、非 GET/HEAD→405、缺失→404、目录→index.html、常规文件→200+按扩展名的 Content-Type。
// 单线程跑、且本包仅此一处碰文件系统，故用固定临时根（先清再建，defer 收尾）不与其它测冲突。

import "core:testing"
import "core:mem"
import "core:fmt"
import "core:os"

@(test)
test_static_resolve :: proc(t: ^testing.T) {
	backing: [262144]u8
	ar: mem.Arena
	mem.arena_init(&ar, backing[:])
	context.allocator = mem.arena_allocator(&ar)

	tmp, terr := os.temp_directory(context.allocator)
	testing.expect_value(t, terr, nil)
	root := fmt.tprintf("%s/molly_static_root", tmp)
	_ = os.remove_all(root) // 清掉上次残留
	testing.expect_value(t, os.make_directory_all(root), nil)
	defer os.remove_all(root)

	// 常规文件。
	hello := fmt.tprintf("%s/hello.txt", root)
	testing.expect_value(t, os.write_entire_file_from_string(hello, "hi"), nil)

	// 目录回落目标。
	site := fmt.tprintf("%s/site", root)
	testing.expect_value(t, os.make_directory_all(site), nil)
	idx := fmt.tprintf("%s/index.html", site)
	testing.expect_value(t, os.write_entire_file_from_string(idx, "<html>ok</html>"), nil)

	// 常规文件 → 200 + 正文 + 按扩展名 Content-Type（text/plain）。
	oc := resolve_static(root, "GET", "/hello.txt")
	testing.expect_value(t, oc.not_found, false)
	testing.expect_value(t, oc.code, 200)
	testing.expect_value(t, oc.body, "hi")
	testing.expect_value(t, oc.ct, "text/plain")

	// HEAD 同样解析到 200（正文抑制由 http.Respond 负责）。
	oc = resolve_static(root, "HEAD", "/hello.txt")
	testing.expect_value(t, oc.code, 200)

	// 目录 → index.html（text/html）。
	oc = resolve_static(root, "GET", "/site")
	testing.expect_value(t, oc.code, 200)
	testing.expect_value(t, oc.body, "<html>ok</html>")
	testing.expect_value(t, oc.ct, "text/html")

	// 不存在 → not_found（Serve_Static 据此走 http.Not_Found）。
	oc = resolve_static(root, "GET", "/nope.txt")
	testing.expect_value(t, oc.not_found, true)

	// cgi-bin → 403 策略拒绝（而非 404）。
	oc = resolve_static(root, "GET", "/cgi-bin/luci")
	testing.expect_value(t, oc.code, 403)
	testing.expect_value(t, oc.body, "forbidden\n")

	// 非 GET/HEAD → 405。
	oc = resolve_static(root, "POST", "/hello.txt")
	testing.expect_value(t, oc.code, 405)
}
