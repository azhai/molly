package backend

import "core:crypto/legacy/md5"
import "core:mem"
import "core:os"
import "core:testing"

@(test)
test_file_canonicalize_path :: proc(t: ^testing.T) {
	alloc, ar := mk_arena()
	defer drop_arena(ar)

	cases := []struct {
		path, want: string,
		ok:          bool,
	}{
		{"", "", false},            // 空路径 → 失败（上游 EINVAL）
		{"/", "/", true},           // 根目录
		{"//", "/", true},          // 重复 /
		{"/./", "/", true},         // /./ 折叠
		{"/a/./b", "/a/b", true},   // 中间的 ./ 折叠
		{"/a/../b", "/b", true}, // `..` 后接 `/` → 折叠
		{"/a/b/../c", "/a/c", true},
		{"/a/b/../../c", "/c", true},
		{"/a//b", "/a/b", true},    // 重复 /
		{"/a/", "/a", true},        // 结尾 / 去掉
		{"a/b", "a/b", true},       // 相对路径保持
		{"/x/./y/../../z", "/z", true},
		// 下面的才是真正会折叠的：.. 在结尾或后接 /
		{"/a/..", "/", true},       // 结尾 .. 折叠
		{"/a/b/..", "/a", true},
		{"/..", "/", true},         // 根之上的 .. 不越界
		{"/a/../", "/", true},      // 后接 / 也折叠
	}
	for c in cases {
		got, ok := file_canonicalize_path(c.path, alloc)
		testing.expectf(
			t,
			ok == c.ok && got == c.want,
			"canonicalize(%q) = (%q, %v)，期望 (%q, %v)",
			c.path, got, ok, c.want, c.ok,
		)
	}
}

@(test)
test_file_status_of_errno :: proc(t: ^testing.T) {
	// ENOENT → 4（NOT_FOUND）：打开一个确定不存在的路径
	if _, err := os.open("/this/path/cannot/possibly/exist_xyz"); err != nil {
		testing.expectf(
			t,
			file_status_of(err) == FILE_STATUS_NOT_FOUND,
			"打开不存在路径应映射到 4，实际 %d（%v）",
			file_status_of(err), err,
		)
	}
	// 成功路径不进 file_status_of；这里只验证「错误能映射到已知码」，具体权限码由 smoke 覆盖
}

@(test)
test_file_type_str :: proc(t: ^testing.T) {
	testing.expect(t, file_type_str(.Regular) == "file")
	testing.expect(t, file_type_str(.Directory) == "directory")
	testing.expect(t, file_type_str(.Symlink) == "symlink")
	testing.expect(t, file_type_str(.Named_Pipe) == "fifo")
	testing.expect(t, file_type_str(.Socket) == "socket")
	testing.expect(t, file_type_str(.Block_Device) == "block")
	testing.expect(t, file_type_str(.Character_Device) == "char")
	testing.expect(t, file_type_str(.Undetermined) == "unknown")
}

@(test)
test_file_md5_rfc1321 :: proc(t: ^testing.T) {
	vectors := []struct {
		input, want: string,
	}{
		{"", "d41d8cd98f00b204e9800998ecf8427e"},
		{"abc", "900150983cd24fb0d6963f7d28e17f72"},
		{"message digest", "f96b697d7cb7938d525a2f31aaf161d0"},
		{"abcdefghijklmnopqrstuvwxyz", "c3fcd3d76192e4007dfb496cca67e13b"},
	}
	for c in vectors {
		ctx: md5.Context
		md5.init(&ctx)
		md5.update(&ctx, transmute([]byte)(c.input))
		digest: [16]u8
		md5.final(&ctx, digest[:])

		// 栈上定长 32 字节（hex 输出）：不往堆上分配，免得测试收尾报 `leak`
		got: [32]u8
		digits := "0123456789abcdef"
		for b, i in digest {
			got[i * 2] = digits[b >> 4]
			got[i * 2 + 1] = digits[b & 15]
		}
		testing.expectf(t, string(got[:]) == c.want, "md5(%q) = %s，期望 %s", c.input, string(got[:]), c.want)
	}
}
