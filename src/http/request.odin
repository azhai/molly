package http

// Request —— 解析后的 HTTP 请求。I/O 解析在 server.odin；这里只放数据结构与访问器，
// 好让 handler 依赖的是「已就绪的视图」而非 socket。

import "core:strings"

Header :: struct {
	name:  string, // 原样保留（CGI 透传与 x509 类头名要区分大小写语义）
	value: string,
}

Request :: struct {
	method:  string,
	target:  string, // 原始 origin-form 目标（含 query/fragment），对应 Go r.RequestURI
	path:    string, // normalize 后的安全路径，对应 handler 拿到的 path
	version: string, // "1.0" / "1.1"
	headers: [dynamic]Header,
	body:    []u8, // 已按 Content-Length 读全
	remote:  string, // "ip:port"

	query:   []KV, // 解析自 target 的 '?' 之后
};

KV :: struct { key, value: string }

// 大小写不敏感取首个头。
Header_Get :: proc(r: ^Request, name: string) -> (string, bool) {
	want := strings.to_lower(name)
	for h in r.headers {
		if strings.to_lower(h.name) == want {
			return h.value, true
		}
	}
	return "", false
}

// 取 Content-Length（缺失返回 -1）。
Content_Length :: proc(r: ^Request) -> i64 {
	v, ok := Header_Get(r, "content-length")
	if !ok {
		return -1
	}
	n: i64 = 0
	if !parse_int(strings.trim_space(v), &n) {
		return -1
	}
	return n
}

// 是否 keep-alive：HTTP/1.1 默认长连，除非 Connection: close；HTTP/1.0 反之。
Keep_Alive :: proc(r: ^Request) -> bool {
	if v, ok := Header_Get(r, "connection"); ok {
		l := strings.to_lower(v)
		if strings.contains(l, "close") {
			return false
		}
		if strings.contains(l, "keep-alive") {
			return true
		}
	}
	return r.version == "1.1"
}

// query 取首个值。
Query_Get :: proc(r: ^Request, key: string) -> (string, bool) {
	return KV_Get(r.query, key)
}

// KV_Get —— 从一对 (key,value) 列表里取首个匹配 key 的值。query 与表单正文共用。
KV_Get :: proc(pairs: []KV, key: string) -> (string, bool) {
	for kv in pairs {
		if kv.key == key {
			return kv.value, true
		}
	}
	return "", false
}

// Parse_Form —— 把请求正文按 application/x-www-form-urlencoded 解析成 KV（对齐 Go 的
// r.ParseForm 里 body 那半边 + r.PostFormValue）。auth 的登录/改密表单调它取 username/password。
// 正文恒按 &/+% 规则解（本项目这些端点只接原生 urlencoded 表单）；正文非法不报错，最坏是取不到
// 键 → 上层判 bad_request。返回切片落在 context.allocator（每请求 arena），随请求回收。
Parse_Form :: proc(r: ^Request) -> []KV {
	return parse_pairs(string(r.body))
}

// parse_pairs —— 核心 pair 解析：按 '&' 切段，段内按首个 '=' 分 key/value，做 URL 解码。
// query（'?' 之后）与表单正文共用同一套解码，避免两份实现漂移。
parse_pairs :: proc(body: string) -> []KV {
	out: [dynamic]KV
	i := 0
	for i <= len(body) {
		// 取一段直到下一个 '&'
		j := i
		for j < len(body) && body[j] != '&' {
			j += 1
		}
		item := body[i:j]
		if len(item) > 0 {
			eq := index_byte(item, '=')
			k: string
			v: string
			if eq >= 0 {
				k, v = item[:eq], item[eq+1:]
			} else {
				k, v = item, ""
			}
			append(&out, KV{url_decode(k), url_decode(v)})
		}
		i = j + 1
		if j >= len(body) {
			break
		}
	}
	return out[:]
}

// 解析 target 的查询串：'?' 之后交给 parse_pairs（'&' 切、首个 '=' 分、URL 解码）。
// 与 Go url.Values 的行为对齐到本项目需要的程度。
parse_query :: proc(raw: string) -> []KV {
	qpos := -1
	for i := 0; i < len(raw); i += 1 {
		if raw[i] == '?' {
			qpos = i
			break
		}
		if raw[i] == '#' {
			break
		}
	}
	if qpos < 0 {
		return nil
	}
	return parse_pairs(raw[qpos+1:])
}

// URL 解码：'%XX' 转字节，'+' 转空格；非法 % 序列按原样保留（query 非安全边界，
// 路径才走 normalize_path 的严格校验）。
url_decode :: proc(s: string) -> string {
	if !strings.contains(s, "%") && !strings.contains(s, "+") {
		return s
	}
	out: [dynamic]u8
	defer delete(out)
	i := 0
	for i < len(s) {
		c := s[i]
		if c == '%' && i+2 < len(s) {
			hi, ok1 := hex_val(s[i+1])
			lo, ok2 := hex_val(s[i+2])
			if ok1 && ok2 {
				append(&out, (hi << 4) | lo)
				i += 3
				continue
			}
		}
		if c == '+' {
			append(&out, ' ')
			i += 1
			continue
		}
		append(&out, c)
		i += 1
	}
	bs: []u8 = make([]u8, len(out))
	copy(bs, out[:])
	return string(bs)
}

// 解析非负十进制整数（用于 Content-Length）。带空白/符号/非数字判失败。
parse_int :: proc(s: string, out: ^i64) -> bool {
	if len(s) == 0 {
		return false
	}
	neg := false
	i := 0
	if s[0] == '+' {
		i = 1
	} else if s[0] == '-' {
		neg = true
		i = 1
	}
	if i >= len(s) {
		return false
	}
	n: i64 = 0
	for ; i < len(s); i += 1 {
		c := s[i]
		if c < '0' || c > '9' {
			return false
		}
		n = n * 10 + i64(c - '0')
	}
	if neg {
		out^ = - n
	} else {
		out^ = n
	}
	return true
}

index_byte :: proc(s: string, b: u8) -> int {
	for i := 0; i < len(s); i += 1 {
		if s[i] == b {
			return i
		}
	}
	return -1
}
