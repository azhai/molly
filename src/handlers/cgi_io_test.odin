package handlers

// cgi_io_test —— cgi-io HTTP 侧纯决策 host 单测（对齐 internal/handlers/cgi_io_test.go 的决策部分）。

import "core:testing"
import "core:mem"
import "core:time"
import "molly:backend"

// 内联 arena：backing/ar 必须是每个 @(test) 过程的局部（不能经 helper 返回，否则 arena 随
// 助手栈帧失效 → 分配落在悬垂内存）。

@(test)
test_cgi_base_of :: proc(t: ^testing.T) {
	backing: [8192]u8
	ar: mem.Arena
	mem.arena_init(&ar, backing[:])
	context.allocator = mem.arena_allocator(&ar)
	// 本部署：prefix=/admin、strip=/admin → SCRIPT_NAME=""→ cgi_base=""。
	testing.expect_value(t, cgi_base_of("/admin", "/admin"), "")
	// 上游默认：prefix=/cgi-bin/luci、strip=""→ SCRIPT_NAME=/cgi-bin/luci → cgi_base=/cgi-bin。
	testing.expect_value(t, cgi_base_of("/cgi-bin/luci", ""), "/cgi-bin")
}

@(test)
test_cgi_io_endpoint_of :: proc(t: ^testing.T) {
	backing: [8192]u8
	ar: mem.Arena
	mem.arena_init(&ar, backing[:])
	context.allocator = mem.arena_allocator(&ar)
	ep, ok := cgi_io_endpoint_of("/cgi-exec", "")
	testing.expect_value(t, ok, true)
	testing.expect_value(t, ep, .exec)
	_, ok2 := cgi_io_endpoint_of("/cgi-exec/x", "")
	testing.expect_value(t, ok2, false) // 边界：不吞 /cgi-exec/anything
	_, ok3 := cgi_io_endpoint_of("/cgi-upload", "/cgi-bin")
	testing.expect_value(t, ok3, false) // base=/cgi-bin 时裸 /cgi-upload 不匹配（需 /cgi-bin/cgi-upload）
	ep4, ok4 := cgi_io_endpoint_of("/cgi-bin/cgi-backup", "/cgi-bin")
	testing.expect_value(t, ok4, true)
	testing.expect_value(t, ep4, .backup)
	testing.expect_value(t, Is_CGI_IO_Path("/cgi-download", ""), true)
	testing.expect_value(t, Is_CGI_IO_Path("/nope", ""), false)
}

@(test)
test_cgi_io_word_and_sanitize :: proc(t: ^testing.T) {
	backing: [8192]u8
	ar: mem.Arena
	mem.arena_init(&ar, backing[:])
	context.allocator = mem.arena_allocator(&ar)
	testing.expect_value(t, cgi_io_word_for(backend.Status_Invalid_Argument), "invalid argument")
	testing.expect_value(t, cgi_io_word_for(backend.Status_Permission_Denied), "permission denied")
	testing.expect_value(t, cgi_io_word_for(backend.Status_Not_Found), "not found")
	testing.expect_value(t, cgi_io_word_for(backend.Status_Timeout), "timeout")
	testing.expect_value(t, cgi_io_word_for(backend.Status_Unknown_Error), "internal error")

	testing.expect_value(t, sanitize_filename_token("ho:st/name.1-2_3"), "ho_st_name.1-2_3")
	testing.expect_value(t, sanitize_filename_token(""), "")
}

@(test)
test_cgi_backup_name :: proc(t: ^testing.T) {
	backing: [8192]u8
	ar: mem.Arena
	mem.arena_init(&ar, backing[:])
	context.allocator = mem.arena_allocator(&ar)

	// 固定 UTC 时刻 2026-01-02 03:04（components_to_time 与 date/clock_from_time 同为 UTC，可回环）。
	tm, ok := time.components_to_time(2026, 1, 2, 3, 4, 5)
	testing.expect(t, ok)
	testing.expect_value(t, cgi_backup_name("OpenWrt", tm), "backup-OpenWrt-20260102-0304.tar.gz")
	// 主机名里不适合文件名的字符转下划线（对齐 Go sanitizeFilenameToken 语义）。
	testing.expect_value(t, cgi_backup_name("ho:st/nm", tm), "backup-ho_st_nm-20260102-0304.tar.gz")
	// 空主机名回退 backup。
	testing.expect_value(t, cgi_backup_name("", tm), "backup-backup-20260102-0304.tar.gz")
}

@(test)
test_multipart_boundary :: proc(t: ^testing.T) {
	backing: [8192]u8
	ar: mem.Arena
	mem.arena_init(&ar, backing[:])
	context.allocator = mem.arena_allocator(&ar)
	// 未加引号：读到 ';' / 空白 止。
	testing.expect_value(t, multipart_boundary("multipart/form-data; boundary=XBOUND"), "XBOUND")
	testing.expect_value(t, multipart_boundary("multipart/form-data; boundary=abc; charset=utf-8"), "abc")
	// 带引号：取引号内原文（保留大小写）。
	testing.expect_value(t, multipart_boundary(`multipart/form-data; boundary="Aa-Bb"`), "Aa-Bb")
	// boundary= 大小写不敏感匹配，但值保留原始大小写。
	testing.expect_value(t, multipart_boundary("Multipart/Form-Data; BOUNDARY=MiXeD"), "MiXeD")
	// 缺失 → 空串。
	testing.expect_value(t, multipart_boundary("application/json"), "")
}

@(test)
test_multipart_field_name :: proc(t: ^testing.T) {
	backing: [8192]u8
	ar: mem.Arena
	mem.arena_init(&ar, backing[:])
	context.allocator = mem.arena_allocator(&ar)
	// 普通 name=。
	h1 := "Content-Disposition: form-data; name=\"sessionid\""
	testing.expect_value(t, multipart_field_name(transmute([]u8)(h1)), "sessionid")
	// 带 filename= 时不能误取 filename 里的 name 子串。
	h2 := "Content-Disposition: form-data; name=\"filedata\"; filename=\"x.bin\""
	testing.expect_value(t, multipart_field_name(transmute([]u8)(h2)), "filedata")
	// 未加引号。
	h3 := "Content-Disposition: form-data; name=filename;"
	testing.expect_value(t, multipart_field_name(transmute([]u8)(h3)), "filename")
	// 无 name → 空串。
	h4 := "Content-Type: text/plain"
	testing.expect_value(t, multipart_field_name(transmute([]u8)(h4)), "")
}

@(test)
test_parse_multipart :: proc(t: ^testing.T) {
	backing: [16384]u8
	ar: mem.Arena
	mem.arena_init(&ar, backing[:])
	context.allocator = mem.arena_allocator(&ar)
	// 构造 boundary=XBOUND 的三段 multipart（sessionid / filename / filedata）。
	body_str := "--XBOUND\r\nContent-Disposition: form-data; name=\"sessionid\"\r\n\r\nSID123\r\n--XBOUND\r\nContent-Disposition: form-data; name=\"filename\"\r\n\r\n/tmp/upl.bin\r\n--XBOUND\r\nContent-Disposition: form-data; name=\"filedata\"; filename=\"orig.bin\"\r\nContent-Type: application/octet-stream\r\n\r\n\x00\x01\x02\xff\r\n--XBOUND--\r\n"
	body := transmute([]u8)(body_str)
	f := parse_multipart(body, "XBOUND")
	testing.expect_value(t, f.has_file, true)
	testing.expect_value(t, f.sessionid, "SID123")
	testing.expect_value(t, f.filename, "/tmp/upl.bin") // 取字段 filename，非文件部件自带 orig.bin
	testing.expect_value(t, len(f.filedata), 4)
	if len(f.filedata) == 4 {
		testing.expect_value(t, f.filedata[0], 0x00)
		testing.expect_value(t, f.filedata[1], 0x01)
		testing.expect_value(t, f.filedata[2], 0x02)
		testing.expect_value(t, f.filedata[3], 0xff) // 二进制内容不被截断（CRLF 前的 \xff）
	}
	// 缺文件部件 → has_file false。
	only := "--XBOUND\r\nContent-Disposition: form-data; name=\"sessionid\"\r\n\r\nS\r\n--XBOUND--\r\n"
	g := parse_multipart(transmute([]u8)(only), "XBOUND")
	testing.expect_value(t, g.has_file, false)
	testing.expect_value(t, g.sessionid, "S")
}
