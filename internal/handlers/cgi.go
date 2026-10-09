package handlers

import (
	"bytes"
	"errors"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/exec"
	"sort"
	"strings"
	"syscall"
)

// ---------------------------------------------------------------------------
// /cgi-bin/luci → 子进程的桥接（ADR `.ai-agents/adr/0003-keep-ucode-faithful-luci2.md`）
//
// 上游 uhttpd 有两种形态，**只有第二种能从子进程跑**：
//  1. 进程内 ucode **模板**（uhttpd 的默认形态）：那个文件首行是 `{%`，定义
//     `global.handle_request(env)`、收发走 uhttpd 注入的 `uhttpd.recv` / `uhttpd.send`
//     ——必须在 uhttpd 进程里按模板编译；单独 execve 它必然语法错。
//  2. **CGI 兜底**：`/www/cgi-bin/luci`，LuCI 装的 `#!/usr/bin/env ucode` 脚本。
// `--luci-cgi` 要填的是 **2**。设备上的等价验收：把 --luci-cgi 换成 "/www/cgi-bin/luci"。
//
// Go 侧用 os/exec：Stdin / Stdout 是 io.Reader / io.Writer 时，cmd 会自动用 goroutine
// 拷贝，等价于 Odin 版为「请求体写管道」单开的短命线程（避免子进程先回响应再读 body
// 时在管道缓冲上死锁），且不需要手写 fork/execve 的 async-signal-safe 约束。
// 子进程 stderr 继承 molly 的 stderr，ucode 的报错要能在日志里看到。
// ---------------------------------------------------------------------------

// cgiSpecialHeaders 是 CGI 规范里由环境变量表达、不能从请求头透传的头。
var cgiSpecialHeaders = []string{"content-type", "content-length", "transfer-encoding", "connection"}

// buildCGIEnv 构造一份 CGI 环境（每个元素是 "K=V"）。
//   - treePath —— **菜单树路径**（已去掉专家版前缀、并补回 LuciStripSegment 省掉的那段，
//     见 LuciTreePath）。PATH_INFO 用它而不是 URL 路径：前缀那一段归 SCRIPT_NAME，
//     而 URL 上省掉的那段必须补回来，否则 ucode dispatcher 会从树根去找 `status`
//     （它挂在 admin 下面）→ 每个页面都 404。根按上游约定给空串。
//   - docroot  —— --docroot 的值，供脚本拼绝对路径
//
// 取值全部来自已解析的请求。
func buildCGIEnv(r *http.Request, treePath, peerHost, docroot, ubusSocket string, body []byte) []string {
	env := make([]string, 0, 16)

	query := r.URL.RawQuery
	pathInfo := treePath
	if pathInfo == "/" {
		pathInfo = "" // 根：上游是空路径（走菜单树 root 的 firstchild）
	}

	env = append(env, "GATEWAY_INTERFACE=CGI/1.1")
	env = append(env, "SERVER_SOFTWARE=molly")
	env = append(env, fmt.Sprintf("SERVER_PROTOCOL=HTTP/1.%d", r.ProtoMinor))
	env = append(env, "REQUEST_METHOD="+cgiMethodString(r.Method))
	env = append(env, "REQUEST_URI="+r.RequestURI)
	env = append(env, "SCRIPT_NAME="+cgiScriptName())
	env = append(env, "PATH_INFO="+pathInfo)
	env = append(env, "QUERY_STRING="+query)
	env = append(env, "DOCUMENT_ROOT="+docroot)
	env = append(env, "REMOTE_ADDR="+peerHost)
	// CONTENT_LENGTH 恒给（GET 时是 0）：上游 uhttpd 也总是设置它，脚本会直接 +
	env = append(env, fmt.Sprintf("CONTENT_LENGTH=%d", len(body)))
	if ct := r.Header.Get("Content-Type"); ct != "" {
		env = append(env, "CONTENT_TYPE="+ct)
	}

	// 头名排序：Go 的 r.Header 是 map，遍历顺序随机；Odin 版吃的是请求里的原始顺序。
	names := make([]string, 0, len(r.Header))
	for name := range r.Header {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		if isCGISpecialHeader(name) {
			continue
		}
		envName := "HTTP_" + headerEnvName(name)
		for _, v := range r.Header.Values(name) {
			env = append(env, envName+"="+v)
		}
	}
	// Host 不在 r.Header 里（Go 把它单独放在 r.Host，且不含端口以外的处理），单独补。
	if r.Host != "" {
		env = append(env, "HTTP_HOST="+r.Host)
	}

	// 私有总线模式（--ubus-socket）下，CGI 子进程（ucode LuCI）必须连到 molly 那条
	// 总线，否则它看不到 molly 的 session。libubus 本身不认环境变量，靠设备上 LuCI 的
	// dispatcher.uc 读这个变量（一行补丁）。
	if ubusSocket != "" {
		env = append(env, "MOLLY_UBUS_SOCKET="+ubusSocket)
	}
	return env
}

// cgiScriptName 给出交给 CGI 子进程（ucode dispatcher）的 SCRIPT_NAME。
//
// 它是「专家版前缀」减去 `--luci-strip` 省掉的那一段菜单路径。为什么不是直接用 LuciPrefix：
//
// ucode 的 build_url（dispatcher.uc）与前端 luci.js 的 url() 都是 `SCRIPT_NAME + 菜单树路径`
// 来拼每一条页面链接，而菜单树的顶层恒有一段 `admin`（URL 上被 --luci-strip 省掉的那一段）。
// 若把 SCRIPT_NAME 直接设成前缀 `/admin`，拼出来就是 `/admin/admin/status/overview`——前缀名
// 与树首段名撞车，URL 里 `admin` 双写。
//
// 把 SCRIPT_NAME 里那段尾缀（= strip 段）去掉，`build_url = SCRIPT_NAME + 树路径` 正好落回
// 单段 `/admin/status/overview`；而入站侧 LuciTreePath 依旧按前缀折算、把省掉的段补回树里，
// 两边对得上。strip 为空（上游默认）时本函数即返回 LuciPrefix，与改动前逐字节一致。
func cgiScriptName() string {
	if LuciStripSegment == "" {
		return LuciPrefix
	}
	// 只在前缀字面以 strip 段收尾时才去掉它；否则（配置不匹配）原样返回，行为退回旧写法。
	return strings.TrimSuffix(LuciPrefix, LuciStripSegment)
}

// cgiResponse 是解析后的 CGI 响应。
type cgiResponse struct {
	code        int
	reason      string
	contentType string
	extra       []ExtraHeader
	body        string
}

// parseCGIResponse：头块（可含 `Status: <code> <reason>`）+ 空行 + body。
// 规范要求 CRLFCRLF 分隔，这里同时容忍 LF LF（桩程序与手写脚本常用）。
// Content-Type 缺失视为脚本错误（CGI 规范的要求），返回 ok = false。
func parseCGIResponse(raw string) (cgiResponse, bool) {
	sep, sepLen := -1, 0
	if i := strings.Index(raw, "\r\n\r\n"); i >= 0 {
		sep, sepLen = i, 4
	} else if i := strings.Index(raw, "\n\n"); i >= 0 {
		sep, sepLen = i, 2
	}
	if sep < 0 {
		return cgiResponse{}, false
	}

	resp := cgiResponse{code: 200, reason: "OK", body: raw[sep+sepLen:]}

	rest := raw[:sep]
	first := true
	for len(rest) > 0 {
		line := rest
		if i := strings.Index(rest, "\r\n"); i >= 0 {
			line, rest = rest[:i], rest[i+2:]
		} else if i := strings.IndexByte(rest, '\n'); i >= 0 {
			line, rest = rest[:i], rest[i+1:]
		} else {
			rest = ""
		}
		if len(line) == 0 {
			continue
		}
		// 容忍非标准的 "HTTP/1.1 200 OK" 起始行（CGI 规范要求用 Status:）
		if first && strings.HasPrefix(line, "HTTP/") {
			first = false
			if sp := strings.IndexByte(line, ' '); sp >= 0 {
				codeStr := line[sp+1:]
				if sp2 := strings.IndexByte(codeStr, ' '); sp2 >= 0 {
					codeStr = codeStr[:sp2]
				}
				if n, ok := parseUint(codeStr); ok {
					resp.code = n
					resp.reason = cgiReason(n)
				}
			}
			continue
		}
		first = false

		colon := strings.IndexByte(line, ':')
		if colon <= 0 {
			continue
		}
		name := line[:colon]
		value := strings.TrimSpace(line[colon+1:])

		switch {
		case strings.EqualFold(name, "Status"):
			codeStr, reasonPhrase := value, ""
			if sp := strings.IndexByte(value, ' '); sp >= 0 {
				codeStr, reasonPhrase = value[:sp], strings.TrimSpace(value[sp+1:])
			}
			if n, ok := parseUint(codeStr); ok {
				resp.code = n
				if len(reasonPhrase) > 0 {
					resp.reason = reasonPhrase
				} else {
					resp.reason = cgiReason(n)
				}
			}
		case strings.EqualFold(name, "Content-Type"):
			resp.contentType = value
		case strings.EqualFold(name, "Content-Length"), strings.EqualFold(name, "Connection"):
			// 由 molly 决定，避免脚本给的长度与真实 body 不一致把 keep-alive 搞坏
		case strings.EqualFold(name, "Set-Cookie"):
			// 会话 cookie 的 path 放宽到 `/`：专家版前缀（`/admin/`）与简洁版（`/lite/`）必须
			// 读写同一个 cookie 槽位，否则各有一条会话。见 widenSessionCookiePath。
			resp.extra = append(resp.extra, ExtraHeader{Name: name, Value: widenSessionCookiePath(value)})
		default:
			resp.extra = append(resp.extra, ExtraHeader{Name: name, Value: value})
		}
	}

	if len(resp.contentType) == 0 {
		return cgiResponse{}, false
	}
	return resp, true
}

// runCGI 执行 --luci-cgi 指定的命令，把它的 stdout 当成响应回给客户端。
// path 是已规范化的完整路径；cmd 是 --luci-cgi 的值。
func runCGI(w http.ResponseWriter, r *http.Request, treePath, docroot, cmd, ubusSocket string, body []byte) {
	argv := splitCommand(cmd)
	if len(argv) == 0 {
		cgiFail(w, r, "cgi command is empty")
		return
	}

	env := buildCGIEnv(r, treePath, remoteHost(r.RemoteAddr), docroot, ubusSocket, body)

	c := exec.Command(argv[0], argv[1:]...)
	c.Env = env
	c.Stderr = os.Stderr
	if len(body) > 0 {
		c.Stdin = bytes.NewReader(body)
	}
	var out bytes.Buffer
	c.Stdout = &out
	err := c.Run()

	raw := out.String()
	resp, ok := parseCGIResponse(raw)
	if !ok {
		head := raw
		if len(head) > 200 {
			head = head[:200]
		}
		// 正文带上子进程的退出情况：`exit 1` + stdout 为空，最常见的原因就是 --luci-cgi
		// 指错了可执行文件（典型：填成 uhttpd.uc——那是模板不是脚本，它把语法错打到 stderr、
		// stdout 什么都不给）。stderr 继承 molly 的 stderr，细节在 molly 的日志里。
		cgiFail(w, r, fmt.Sprintf("invalid CGI response (%s): %q", exitDesc(err), head))
		return
	}

	// Content-Type 只在脚本没给时才由我们兜底（parse 已保证给了）
	headers := make([]ExtraHeader, 0, len(resp.extra)+1)
	headers = append(headers, ExtraHeader{Name: "Content-Type", Value: resp.contentType})
	headers = append(headers, resp.extra...)

	RespondFull(w, r, resp.code, headers, resp.body)
}

func cgiFail(w http.ResponseWriter, r *http.Request, msg string) {
	Respond(w, r, http.StatusInternalServerError, msg+"\n", "text/plain; charset=utf-8")
}

// exitDesc：子进程是怎么结束的 —— `exit N` / `signal N`。只写进 500 的正文与 molly
// 的日志，用来区分「脚本自己退出（通常是配置或语法问题）」和「被信号杀掉（崩溃/超时）」。
func exitDesc(err error) string {
	if err == nil {
		return "exit 0"
	}
	var ee *exec.ExitError
	if errors.As(err, &ee) {
		if st, ok := ee.Sys().(syscall.WaitStatus); ok {
			switch {
			case st.Exited():
				return fmt.Sprintf("exit %d", st.ExitStatus())
			case st.Signaled():
				return fmt.Sprintf("signal %d", int(st.Signal()))
			}
		}
	}
	return "unknown exit status"
}

// splitCommand：命令按空白切分（不接受引号与转义）——--luci-cgi 是管理员配置的固定命令。
// 只切空格与制表符，对齐 Odin 版 split_command（strings.Fields 会多切一堆 unicode 空白）。
func splitCommand(cmd string) []string {
	return strings.FieldsFunc(cmd, func(r rune) bool { return r == ' ' || r == '\t' })
}

// remoteHost：r.RemoteAddr 是 "host:port"，CGI 的 REMOTE_ADDR 只要 host。
func remoteHost(remoteAddr string) string {
	if remoteAddr == "" {
		return ""
	}
	if h, _, err := net.SplitHostPort(remoteAddr); err == nil {
		return h
	}
	return remoteAddr
}

// cgiMethodString 对齐 Odin 版 method_str：只认六个标准方法，其余一律 "UNKNOWN"。
func cgiMethodString(m string) string {
	switch m {
	case http.MethodGet, http.MethodHead, http.MethodPost,
		http.MethodPut, http.MethodDelete, http.MethodOptions:
		return m
	}
	return "UNKNOWN"
}

func isCGISpecialHeader(name string) bool {
	for _, s := range cgiSpecialHeaders {
		if strings.EqualFold(name, s) {
			return true
		}
	}
	return false
}

// headerEnvName：X-Forwarded-For → HTTP_X_FORWARDED_FOR（ASCII 大写 + '-' → '_'）
func headerEnvName(name string) string {
	out := make([]byte, len(name))
	for i := 0; i < len(name); i++ {
		c := name[i]
		switch {
		case c == '-':
			out[i] = '_'
		case c >= 'a' && c <= 'z':
			out[i] = c - 32
		default:
			out[i] = c
		}
	}
	return string(out)
}

func parseUint(s string) (int, bool) {
	if len(s) == 0 {
		return 0, false
	}
	n := 0
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return 0, false
		}
		n = n*10 + int(s[i]-'0')
	}
	return n, true
}

// cgiReason：CGI 常见状态码的原因短语。表外的码不带短语（`HTTP/1.1 418 \r\n` 仍是合法状态行）。
func cgiReason(code int) string {
	switch code {
	case 200:
		return "OK"
	case 201:
		return "Created"
	case 204:
		return "No Content"
	case 301:
		return "Moved Permanently"
	case 302:
		return "Found"
	case 303:
		return "See Other"
	case 304:
		return "Not Modified"
	case 307:
		return "Temporary Redirect"
	case 308:
		return "Permanent Redirect"
	case 400:
		return "Bad Request"
	case 401:
		return "Unauthorized"
	case 403:
		return "Forbidden"
	case 404:
		return "Not Found"
	case 405:
		return "Method Not Allowed"
	case 408:
		return "Request Timeout"
	case 411:
		return "Length Required"
	case 413:
		return "Payload Too Large"
	case 415:
		return "Unsupported Media Type"
	case 422:
		return "Unprocessable Entity"
	case 429:
		return "Too Many Requests"
	case 500:
		return "Internal Server Error"
	case 501:
		return "Not Implemented"
	case 502:
		return "Bad Gateway"
	case 503:
		return "Service Unavailable"
	case 504:
		return "Gateway Timeout"
	}
	return ""
}

// widenSessionCookiePath 把**会话 cookie** 的 path 属性放宽成 `/`，其余 Set-Cookie 原样返回。
//
// 为什么：上游 dispatcher 用 `path=${build_url()}` 下发会话 cookie，也就是**专家版前缀**
// （本站 `/admin/`）。在「LuCI 独占整个站点」时这没问题，但本站 `/lite` 上还有一套简洁版，而
// cookie 的作用域是**按 path** 判定的——`/admin/` 作用域的 cookie 浏览器根本不会在 `/lite` 上
// 发回来。结果是两套界面各自登录、各有一条会话（用户报的「session 不统一」）。
//
// 放宽到 `/` 之后，两套界面读写的是**同一个 cookie 槽位**，也就是同一条会话：在哪边登录
// 都行，另一边刷新即可用。
//
// 只动会话 cookie（名字以 `sysauth` 开头，与上游 dispatcher 的命名一致），其它 cookie
// 逐字节透传——别把 CGI 脚本自己的 cookie 改坏。
func widenSessionCookiePath(v string) string {
	name, _, _ := strings.Cut(v, "=")
	if !strings.HasPrefix(strings.TrimSpace(name), "sysauth") {
		return v
	}
	parts := strings.Split(v, ";")
	for i, p := range parts {
		t := strings.TrimSpace(p)
		if len(t) >= 5 && strings.EqualFold(t[:5], "path=") {
			// 只换值：保留上游写的属性名大小写与前面那段空白，尽量少动 CGi 给的东西。
			lead := len(p) - len(strings.TrimLeft(p, " \t"))
			parts[i] = p[:lead+5] + "/"
			return strings.Join(parts, ";")
		}
	}
	// 没写 path 的（罕见）：补一个，否则 cookie 的作用域由浏览器按默认目录规则猜。
	return strings.Join(append(parts, " path=/"), ";")
}
