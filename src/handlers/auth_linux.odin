package handlers

// auth_linux —— 改密码的两个设备专属原语在真机（linux）上的实现（逐条对齐 auth.go:180-235）。
//
// 与 backend 里其它「linux-only」实现（uci 写路径、luci-rpc 的 netlink/ifaddrs）走同一套验收：
// host 只做交叉编译保证（obj），真机验证归阶段6 的 device 断言。原因见下——这两步都紧贴设备的
// 口令存储，开发机上要么没有、要么形态不同。

import "core:os"
import "core:strings"
import "molly:backend"

// shadow_file 是口令 hash 所在处。LuCI 改密码也是写这个文件（file.write /etc/shadow），
// 我们走同一条路，不引入第二套口令存储。
shadow_file :: "/etc/shadow"

// shadow_hash —— 生成 sha256-crypt（$5$）hash，用设备上的 `openssl passwd -5 -stdin`：
// 口令从 stdin 进（不进 argv/env，ps 里看不见），算法与设备上现有的 $5$ 一致。
//
// 为什么不自己实现 sha256-crypt：它有一百多行位运算，写错不会报错、只会**静默产出一份登不进去的
// hash**——这种 bug 要在真机点一次「保存」之后才暴露。宁可依赖现成实现：openssl 不在（进程起不来）
// 回 no_hasher，产出形态不对回 hash_failed，而不是留半截功能。
shadow_hash :: proc(password: string) -> (hash: string, code: string) {
	// 口令从 stdin 进（不进 argv/env，ps 里看不见），走统一的 spawn_run（linux 侧 shim.c
	// 的 molly_spawn；避开 core:os process_exec 在服务线程下的 SIGTRAP 陷阱）。
	// command[0]="openssl"：molly_spawn 会在 PATH 里找它；找不到 → 启动失败 → no_hasher。
	input := build([]string{password, "\n"})
	res := backend.spawn_run([]string{"openssl", "passwd", "-5", "-stdin"}, nil, transmute([]u8)(input), true)
	if ! res.started || ! res.exited || res.code != 0 {
		return "", "no_hasher"
	}
	h := strings.trim_space(string(res.stdout))
	if ! strings.has_prefix(h, "$5$") && ! strings.has_prefix(h, "$6$") {
		return "", "hash_failed"
	}
	return h, ""
}

// shadow_set_hash —— 把 /etc/shadow 里该用户那一行的第 2 个字段换成 hash，其余字段/其余行原样
// （与 LuCI 同一套做法）。写临时文件（0600）+ rename 原子替换：改坏 shadow 的后果是**全设备都登不上**。
shadow_set_hash :: proc(username, hash: string) -> (code: string) {
	data, rerr := os.read_entire_file(shadow_file, context.allocator)
	if rerr != nil {
		return "write_failed"
	}
	lines, _ := strings.split(string(data), "\n")
	defer delete(lines)

	prefix := build([]string{username, ":"})
	found := false
	for i := 0; i < len(lines); i += 1 {
		line := lines[i]
		if ! strings.has_prefix(line, prefix) {
			continue
		}
		fields, _ := strings.split(line, ":")
		if len(fields) < 2 {
			delete(fields)
			return "malformed_shadow"
		}
		fields[1] = hash
		joined, _ := strings.join(fields, ":")
		lines[i] = joined
		delete(fields)
		found = true
		break
	}
	if ! found {
		return "no_such_user"
	}

	joined_all, _ := strings.join(lines, "\n")
	tmp := build([]string{shadow_file, ".molly.tmp"})
	if werr := os.write_entire_file_from_string(tmp, joined_all, {.Read_User, .Write_User}); werr != nil {
		return "write_failed"
	}
	if os.rename(tmp, shadow_file) != nil {
		_ = os.remove(tmp)
		return "write_failed"
	}
	return ""
}
