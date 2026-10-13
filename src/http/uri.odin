package http

// URI 规范化 —— 本项目的安全边界。
//
// 请求目标完全由客户端控制，逃出 docroot 的可能（..、%2e%2e、NUL）必须在这里一次
// 性拦干净，后面的 handler 才能直接拼路径。语义等价 uhttpd 的 uh_http_decode + 路径检查：
// 百分号解码之后不允许出现 ".." 段。逐条对齐 internal/httpx/uri.go（后者又对齐原厂 Odin 版）。

URIState :: enum {
	Ok,       // 可安全拼到 docroot 后
	Bad,      // → 400：百分号编码非法，或解码出控制字符（含 NUL）
	Escaping, // → 403：解码后含 .. 段
}

// 约定：raw 必须以 '/' 开头（origin-form 目标）。
Normalize_Path :: proc(raw: string) -> (path: string, state: URIState) {
	if len(raw) == 0 || raw[0] != '/' {
		return "", .Bad
	}

	// 1. 剥掉查询串与片段。
	target := raw
	for i := 0; i < len(target); i += 1 {
		if target[i] == '?' || target[i] == '#' {
			target = target[:i]
			break
		}
	}

	// 2. 百分号解码；控制字符一律拒绝（NUL 会截断底层 C 路径 API，其余无正当用途）。
	buf: [dynamic]u8
	defer delete(buf)

	i := 0
	for i < len(target) {
		c := target[i]
		if c == '%' {
			if i+2 >= len(target) {
				return "", .Bad
			}
			hi, ok1 := hex_val(target[i+1])
			lo, ok2 := hex_val(target[i+2])
			if !ok1 || !ok2 {
				return "", .Bad
			}
			c = (hi << 4) | lo
			i += 2
		}
		if c < 0x20 || c == 0x7f {
			return "", .Bad
		}
		append(&buf, c)
		i += 1
	}
	decoded := buf[:]

	// 3. 按 '/' 切段：丢掉重复的 '/' 与 "."，遇到 ".." 判逃逸。
	out: [dynamic]u8
	defer delete(out)
	append(&out, '/')
	i = 1 // 开头的 '/' 已写
	for i < len(decoded) {
		j := i
		for j < len(decoded) && decoded[j] != '/' {
			j += 1
		}
		seg := decoded[i:j]
		if len(seg) == 0 || (len(seg) == 1 && seg[0] == '.') {
			// 重复的 / 与 "." 只是冗余写法，丢掉
		} else if len(seg) == 2 && seg[0] == '.' && seg[1] == '.' {
			return "", .Escaping
		} else {
			if len(out) > 1 {
				append(&out, '/')
			}
			for b in seg {
				append(&out, b)
			}
		}
		i = j + 1
	}

	// 交出堆上独立副本（out 随即被删）。
	result: []u8 = make([]u8, len(out))
	copy(result, out[:])
	return string(result), .Ok
}

hex_val :: proc(c: u8) -> (val: u8, ok: bool) {
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
