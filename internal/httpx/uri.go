// Package httpx —— URI 规范化与 MIME 判定。
//
// 逐条复刻 Odin 版 molly 的 src/http/uri.odin 与 src/http/mime.odin：
// 这两件事都是纯函数、且是安全边界，必须与 Odin 版行为一致。
package httpx

// URIState 是 NormalizePath 的判定结果。
type URIState int

const (
	// URIOk 可以安全地把返回值拼到 docroot 后面。
	URIOk URIState = iota
	// URIBad → 400：百分号编码非法，或解码出控制字符（含 NUL）。
	URIBad
	// URIEscaping → 403：解码后含 .. 段。
	URIEscaping
)

// NormalizePath 把 origin-form 目标（如 "/luci-static/x.css?v=1"）变成可以
// 安全拼到 docroot 后面的绝对路径。
//
// 这是本项目的安全边界：请求目标完全由客户端控制，逃出 docroot 的可能性
// （..、%2e%2e、NUL）必须在这里一次性拦干净，后面的 handler 才可以直接拼路径。
// 语义与 uhttpd 的 uh_http_decode + 路径检查等价：百分号解码之后不允许出现 .. 段。
//
// 约定：raw 必须以 '/' 开头。
func NormalizePath(raw string) (string, URIState) {
	if len(raw) == 0 || raw[0] != '/' {
		return "", URIBad
	}

	// 1. 剥掉查询串与片段
	target := raw
	for i := 0; i < len(target); i++ {
		if target[i] == '?' || target[i] == '#' {
			target = target[:i]
			break
		}
	}

	// 2. 百分号解码。控制字符一律拒绝：NUL 会在底层 C 文件 API 上截断路径，
	//    其余控制字符在路径里没有任何正当用途。
	buf := make([]byte, 0, len(target))
	for i := 0; i < len(target); i++ {
		c := target[i]
		if c == '%' {
			if i+2 >= len(target) {
				return "", URIBad
			}
			hi, ok1 := hexVal(target[i+1])
			lo, ok2 := hexVal(target[i+2])
			if !ok1 || !ok2 {
				return "", URIBad
			}
			c = hi<<4 | lo
			i += 2
		}
		if c < 0x20 || c == 0x7f {
			return "", URIBad
		}
		buf = append(buf, c)
	}

	// 3. 按 / 切段：丢掉重复的 / 与 "."，遇到 ".." 直接判逃逸。
	out := make([]byte, 0, len(buf)+1)
	out = append(out, '/')
	i := 1 // 开头的 '/' 已经写过了
	for i < len(buf) {
		j := i
		for j < len(buf) && buf[j] != '/' {
			j++
		}
		seg := buf[i:j]
		switch {
		case len(seg) == 0, len(seg) == 1 && seg[0] == '.':
			// 重复的 / 与 "." 都只是冗余写法，丢掉
		case len(seg) == 2 && seg[0] == '.' && seg[1] == '.':
			return "", URIEscaping
		default:
			if len(out) > 1 {
				out = append(out, '/')
			}
			out = append(out, seg...)
		}
		i = j + 1
	}
	return string(out), URIOk
}

func hexVal(c byte) (byte, bool) {
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
