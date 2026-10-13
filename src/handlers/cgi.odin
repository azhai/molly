package handlers

// cgi —— /cgi-bin/luci → ucode 子进程的桥接里**纯决策**的那两半（对齐 internal/handlers/cgi.go 的
// buildCGIEnv / parseCGIResponse / cgiScriptName / 一堆小工具）。子进程 fork/execve 与流式回写属
// I/O（s4e 的 runCGI 半边，见本文件末尾注释）；这里只把「喂给脚本的环境」和「脚本 stdout 的解读」
// 抽成脱离套接字/进程、能在 host 单测的纯函数（对齐 cgi_test.go 逐条钉死的期望）。
//
// ADR 0003：--luci-cgi 填的是设备上的 CGI 兜底脚本（`/www/cgi-bin/luci`），不是 uhttpd 的进程内模板。

import "core:strings"
import "core:fmt"
import "core:sort"
import "molly:http"

// ExtraHeader 是要原样透传给客户端的一个响应头（CGI 响应头 + 登录提示页用）。
// 头名保留脚本给的大小写，值不得含 CRLF（按行切分时已剥）。
ExtraHeader :: struct {
	name:  string,
	value: string,
}

// cgi_response 是解析后的 CGI 响应。
cgi_response :: struct {
	code:         int,
	reason:       string,
	content_type: string,
	extra:        []ExtraHeader,
	body:         string,
}

// cgi_special_headers —— CGI 规范里由环境变量表达、不从请求头透传的头（对齐 cgiSpecialHeaders）。
cgi_special_headers := []string{"content-type", "content-length", "transfer-encoding", "connection"}

// cgi_script_name —— 交给子进程的 SCRIPT_NAME = 前缀去掉 --luci-strip 省掉的那一段（对齐 cgiScriptName）。
// ucode 的 build_url = SCRIPT_NAME + 树路径，而树顶层恒是那段 strip（admin）；不去掉就会 URL 双写。
// strip 空（上游默认）→ 逐字节等于 prefix。
cgi_script_name :: proc(prefix, strip: string) -> string {
	if strip == "" {
		return prefix
	}
	if _has_suffix(prefix, strip) {
		return prefix[0: len(prefix) - len(strip)]
	}
	return prefix // 配置不匹配：原样返回，退回旧写法
}

// build_cgi_env —— 构造 CGI 环境（每元素 "K=V"）。treePath 是**菜单树路径**（PATH_INFO 用它，
// 而非 URL：根给 "/" → 归空串）。prefix/strip 决定 SCRIPT_NAME。落 context.allocator（每请求 arena）。
build_cgi_env :: proc(req: ^http.Request, tree_path, docroot, ubus_socket, prefix, strip: string) -> [dynamic]string {
	env: [dynamic]string
	query := cgi_query_string(req.target)

	path_info := tree_path
	if path_info == "/" {
		path_info = "" // 根：上游是空路径（走菜单树 root 的 firstchild）
	}

	append(&env, "GATEWAY_INTERFACE=CGI/1.1")
	append(&env, "SERVER_SOFTWARE=molly")
	append(&env, build([]string{"SERVER_PROTOCOL=HTTP/", req.version}))
	append(&env, build([]string{"REQUEST_METHOD=", cgi_method_string(req.method)}))
	append(&env, build([]string{"REQUEST_URI=", req.target}))
	append(&env, build([]string{"SCRIPT_NAME=", cgi_script_name(prefix, strip)}))
	append(&env, build([]string{"PATH_INFO=", path_info}))
	append(&env, build([]string{"QUERY_STRING=", query}))
	append(&env, build([]string{"DOCUMENT_ROOT=", docroot}))
	append(&env, build([]string{"REMOTE_ADDR=", remote_host(req.remote)}))
	append(&env, fmt.tprintf("CONTENT_LENGTH=%d", len(req.body)))
	if ct, _ := http.Header_Get(req, "content-type"); ct != "" {
		append(&env, build([]string{"CONTENT_TYPE=", ct}))
	}

	// 会话 cookie 改名：molly 下发 sysauth_molly，设备原生 ucode dispatcher 只认 sysauth_http/https。
	// 把已解析的 sid 以那两个名字补进 HTTP_COOKIE，让两套实现共用同一条 rpcd 会话。
	cookie, _ := http.Header_Get(req, "cookie")
	if sid := sid_from_cookie(req); sid != "" {
		if cookie != "" {
			cookie = build([]string{cookie, "; "})
		}
		cookie = build([]string{cookie, "sysauth_http=", sid, "; sysauth_https=", sid})
	}

	// 请求头 → HTTP_*（排序：Odin headers 是原始顺序，排一下好复现）。特例头/Cookie/Host 各自处理。
	mapped: [dynamic]string
	defer delete(mapped)
	for h in req.headers {
		lname := strings.to_lower(h.name)
		if is_cgi_special_header(lname) || lname == "cookie" || lname == "host" {
			continue
		}
		append(&mapped, build([]string{"HTTP_", header_env_name(h.name), "=", h.value}))
	}
	sort.heap_sort(mapped[:])
	for e in mapped {
		append(&env, e)
	}

	if host, _ := http.Header_Get(req, "host"); host != "" {
		append(&env, build([]string{"HTTP_HOST=", host}))
	}
	if cookie != "" {
		append(&env, build([]string{"HTTP_COOKIE=", cookie}))
	}
	// 私有总线模式：ucode 靠 dispatcher.uc 读这个变量连到 molly 的总线（一行设备补丁）。
	if ubus_socket != "" {
		append(&env, build([]string{"MOLLY_UBUS_SOCKET=", ubus_socket}))
	}
	return env
}

// parse_cgi_response —— 头块（可含 Status:）+ 空行 + body。CRLFCRLF 优先、容忍 LFLF。
// Content-Type 缺失视为脚本错误 → ok=false（对齐 parseCGIResponse）。
parse_cgi_response :: proc(raw: string) -> (cgi_response, bool) {
	sep, sep_len := -1, 0
	if i := index_sub(raw, "\r\n\r\n"); i >= 0 {
		sep, sep_len = i, 4
	} else if i := index_sub(raw, "\n\n"); i >= 0 {
		sep, sep_len = i, 2
	}
	if sep < 0 {
		return cgi_response{}, false
	}

	resp := cgi_response{code = 200, reason = "OK", body = raw[sep + sep_len:]}

	extra: [dynamic]ExtraHeader
	defer delete(extra)

	rest := raw[0:sep]
	first := true
	for len(rest) > 0 {
		line := rest
		if i := index_sub(rest, "\r\n"); i >= 0 {
			line, rest = rest[0:i], rest[i + 2:]
		} else if i := byte_index(rest, '\n'); i >= 0 {
			line, rest = rest[0:i], rest[i + 1:]
		} else {
			rest = ""
		}
		if len(line) == 0 {
			continue
		}
		// 容忍非标准 "HTTP/1.1 200 OK" 起始行（规范要求用 Status:）。
		if first && strings.has_prefix(line, "HTTP/") {
			first = false
			if sp := byte_index(line, ' '); sp >= 0 {
				code_str := line[sp + 1:]
				if sp2 := byte_index(code_str, ' '); sp2 >= 0 {
					code_str = code_str[0:sp2]
				}
				if n, ok := parse_uint(code_str); ok {
					resp.code = n
					resp.reason = cgi_reason(n)
				}
			}
			continue
		}
		first = false

		colon := byte_index(line, ':')
		if colon <= 0 {
			continue
		}
		name := line[0:colon]
		value := strings.trim_space(line[colon + 1:])
		lname := strings.to_lower(name)

		if lname == "status" {
			code_str := value
			if sp := byte_index(value, ' '); sp >= 0 {
				code_str = value[0:sp]
				reason_phrase := strings.trim_space(value[sp + 1:])
				if n, ok := parse_uint(code_str); ok {
					resp.code = n
					resp.reason = reason_phrase != "" ? reason_phrase : cgi_reason(n)
				}
				continue
			}
			if n, ok := parse_uint(code_str); ok {
				resp.code = n
				resp.reason = cgi_reason(n)
			}
		} else if lname == "content-type" {
			resp.content_type = value
		} else if lname == "content-length" || lname == "connection" {
			// 由 molly 决定，不透传（避免脚本给的长度与真实 body 不一致）。
		} else if lname == "set-cookie" {
			// 会话 cookie 的 path 放宽到 "/"，两套界面共用同一 cookie 槽位。
			append(&extra, ExtraHeader{name, widen_session_cookie_path(value)})
		} else {
			append(&extra, ExtraHeader{name, value})
		}
	}

	if len(resp.content_type) == 0 {
		return cgi_response{}, false
	}
	resp.extra = clone_extra(extra)
	return resp, true
}

// widen_session_cookie_path —— 只把会话 cookie（名字以 sysauth 开头）的 path 属性放宽成 "/"，
// 其它 Set-Cookie 逐字节透传（对齐 widenSessionCookiePath）。
widen_session_cookie_path :: proc(v: string) -> string {
	eq := byte_index(v, '=')
	name := v
	if eq >= 0 {
		name = v[0:eq]
	}
	if ! strings.has_prefix(strings.trim_space(name), "sysauth") {
		return v
	}

	out: [dynamic]string
	defer delete(out)
	found_path := false
	i := 0
	for i <= len(v) {
		j := i
		for j < len(v) && v[j] != ';' {
			j += 1
		}
		seg := v[i:j]
		trimmed := strings.trim_space(seg)
		if len(trimmed) >= 5 && strings.to_lower(trimmed[0:5]) == "path=" {
			// 只换值：保留属性名大小写与其前的空白，尽量少动脚本给的东西。
			lead := 0
			for lead < len(seg) && (seg[lead] == ' ' || seg[lead] == '\t') {
				lead += 1
			}
			seg = build([]string{seg[0: lead + 5], "/"})
			found_path = true
		}
		append(&out, seg)
		i = j + 1
		if j >= len(v) {
			break
		}
	}
	if ! found_path {
		// 没写 path 的（罕见）：补一个，否则 cookie 作用域由浏览器按默认目录规则猜。
		append(&out, " path=/")
	}
	return join_strings(out[:], ";")
}

// ---- 小工具（对齐 cgi.go 的同名函数）----

cgi_query_string :: proc(target: string) -> string {
	for i := 0; i < len(target); i += 1 {
		if target[i] == '?' {
			rest := target[i + 1:]
			for j := 0; j < len(rest); j += 1 {
				if rest[j] == '#' {
					return rest[0:j]
				}
			}
			return rest
		}
		if target[i] == '#' {
			return ""
		}
	}
	return ""
}

cgi_method_string :: proc(m: string) -> string {
	switch m {
	case "GET", "HEAD", "POST", "PUT", "DELETE", "OPTIONS":
		return m
	}
	return "UNKNOWN"
}

is_cgi_special_header :: proc(lower: string) -> bool {
	for s in cgi_special_headers {
		if s == lower {
			return true
		}
	}
	return false
}

// header_env_name —— X-Forwarded-For → X_FORWARDED_FOR（ASCII 大写 + '-' → '_'）。
header_env_name :: proc(name: string) -> string {
	out: [dynamic]u8
	defer delete(out)
	for i := 0; i < len(name); i += 1 {
		c := name[i]
		if c == '-' {
			append(&out, u8('_'))
		} else if c >= 'a' && c <= 'z' {
			append(&out, c - 32)
		} else {
			append(&out, c)
		}
	}
	bs := make([]u8, len(out))
	copy(bs, out[:])
	return string(bs)
}

// remote_host —— req.remote 是 "host:port"，只要 host（IPv6 去方括号）。
remote_host :: proc(remote: string) -> string {
	if remote == "" {
		return ""
	}
	if len(remote) > 0 && remote[0] == '[' {
		if rb := byte_index(remote, ']'); rb >= 0 {
			return remote[1:rb]
		}
		return remote
	}
	if cl := last_index_byte(remote, ':'); cl >= 0 {
		return remote[0:cl]
	}
	return remote
}

parse_uint :: proc(s: string) -> (int, bool) {
	if len(s) == 0 {
		return 0, false
	}
	n := 0
	for i := 0; i < len(s); i += 1 {
		if s[i] < '0' || s[i] > '9' {
			return 0, false
		}
		n = n * 10 + int(s[i] - '0')
	}
	return n, true
}

cgi_reason :: proc(code: int) -> string {
	switch code {
	case 200: return "OK"
	case 201: return "Created"
	case 204: return "No Content"
	case 301: return "Moved Permanently"
	case 302: return "Found"
	case 303: return "See Other"
	case 304: return "Not Modified"
	case 307: return "Temporary Redirect"
	case 308: return "Permanent Redirect"
	case 400: return "Bad Request"
	case 401: return "Unauthorized"
	case 403: return "Forbidden"
	case 404: return "Not Found"
	case 405: return "Method Not Allowed"
	case 408: return "Request Timeout"
	case 411: return "Length Required"
	case 413: return "Payload Too Large"
	case 415: return "Unsupported Media Type"
	case 422: return "Unprocessable Entity"
	case 429: return "Too Many Requests"
	case 500: return "Internal Server Error"
	case 501: return "Not Implemented"
	case 502: return "Bad Gateway"
	case 503: return "Service Unavailable"
	case 504: return "Gateway Timeout"
	}
	return ""
}

// ---- 本地字符串小工具（避免依赖版本差异大的 core:strings 重载）----

_has_suffix :: proc(s, suf: string) -> bool {
	if len(suf) > len(s) {
		return false
	}
	return s[len(s) - len(suf):] == suf
}

index_sub :: proc(s, sub: string) -> int {
	if len(sub) == 0 || len(sub) > len(s) {
		return -1
	}
	for i := 0; i + len(sub) <= len(s); i += 1 {
		if s[i:i + len(sub)] == sub {
			return i
		}
	}
	return -1
}

last_index_byte :: proc(s: string, b: u8) -> int {
	for i := len(s) - 1; i >= 0; i -= 1 {
		if s[i] == b {
			return i
		}
	}
	return -1
}

join_strings :: proc(parts: []string, sep: string) -> string {
	buf: [dynamic]u8
	defer delete(buf)
	for i := 0; i < len(parts); i += 1 {
		if i > 0 {
			append(&buf, sep)
		}
		append(&buf, parts[i])
	}
	out := make([]u8, len(buf))
	copy(out, buf[:])
	return string(out)
}

clone_extra :: proc(src: [dynamic]ExtraHeader) -> []ExtraHeader {
	out := make([]ExtraHeader, len(src), context.allocator)
	copy(out, src[:])
	return out
}

// runCGI（s4e 的 I/O 半边，属阶段5/设备联调）：fork/execve --luci-cgi 命令、把 build_cgi_env
// 的产物作 env、req.body 写 stdin、读 stdout 交 parse_cgi_response、再 http.Emit 回客户端。
// 需要进程/管道系统调用（darwin 与 linux 各一份），与套接字写回耦合，故与 Serve_Luci 的接线一起落地。
