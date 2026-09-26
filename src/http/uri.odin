package http

import "core:mem"

// URI 路径规范化：把 origin-form 目标（如 "/luci-static/x.css?v=1"）变成可以
// 安全拼到 docroot 后面的绝对路径。
//
// 这是本项目的安全边界：请求目标完全由客户端控制，逃出 docroot 的可能性
// （..、%2e%2e、NUL）必须在这里一次性拦干净，后面的 handler 才可以直接拼路径。
// 上游对应物是 uhttpd 的 uh_http_decode + 路径检查；这里不复制它的具体实现，
// 只保证语义等价：百分号解码之后不允许出现 .. 段。
Uri_State :: enum {
	Ok,
	Bad,      // 400：百分号编码非法，或解码出控制字符（含 NUL）
	Escaping, // 403：解码后含 .. 段
}

// 约定：raw 必须以 '/' 开头（parse_head 已保证）。alloc 传每请求 arena，
// 返回的 string 指向该 arena，生命周期同本次请求。
normalize_path :: proc(raw: string, alloc: mem.Allocator) -> (string, Uri_State) {
	if len(raw) == 0 || raw[0] != '/' {
		return "", .Bad
	}

	// 1. 剥掉查询串与片段
	target := raw
	for i := 0; i < len(target); i += 1 {
		if target[i] == '?' || target[i] == '#' {
			target = target[:i]
			break
		}
	}

	// 2. 百分号解码。就地写进 buf，紧接着再就地压段，整个函数只分配一次。
	buf := make([]byte, len(target), alloc)
	if buf == nil {
		return "", .Bad
	}
	n := 0
	for i := 0; i < len(target); i += 1 {
		c := target[i]
		if c == '%' {
			if i + 2 >= len(target) {
				return "", .Bad
			}
			hi, ok1 := hex_val(target[i + 1])
			lo, ok2 := hex_val(target[i + 2])
			if !ok1 || !ok2 {
				return "", .Bad
			}
			c = hi << 4 | lo
			i += 2
		}
		// 控制字符一律拒绝：NUL 会在底层 C 文件 API 上截断路径，其余控制字符
		// 在路径里没有任何正当用途。
		if c < 0x20 || c == 0x7f {
			return "", .Bad
		}
		buf[n] = c
		n += 1
	}

	// 3. 按 / 切段：丢掉空段与 "."，遇到 ".." 直接判逃逸。
	//
	// 就地压缩是安全的：写入位置 w 始终不大于读取位置 i（被丢掉的段只可能让
	// w 落后），所以按字节向前复制不会踩到还没读的字节。
	w := 0
	buf[w] = '/'
	w += 1
	i := 1 // 开头的 '/' 已经写过了
	for i < n {
		j := i
		for j < n && buf[j] != '/' {
			j += 1
		}
		seg := buf[i:j]
		switch {
		case len(seg) == 0, len(seg) == 1 && seg[0] == '.':
			// 重复的 / 与 "." 都只是冗余写法，丢掉
		case len(seg) == 2 && seg[0] == '.' && seg[1] == '.':
			return "", .Escaping
		case:
			if w > 1 {
				buf[w] = '/'
				w += 1
			}
			for k := 0; k < len(seg); k += 1 {
				buf[w] = seg[k]
				w += 1
			}
		}
		i = j + 1
	}
	return transmute(string)(buf[:w]), .Ok
}

@(private)
hex_val :: proc(c: u8) -> (u8, bool) {
	switch {
	case c >= '0' && c <= '9':
		return c - '0', true
	case c >= 'a' && c <= 'f':
		return c - 'a' + 10, true
	case c >= 'A' && c <= 'F':
		return c - 'A' + 10, true
	}
	return 0, false
}