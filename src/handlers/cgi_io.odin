package handlers

// cgi_io —— fs.exec_direct / read_direct / ui.uploadFile 三件套 + 专家版 cgi-backup 的 HTTP 侧
// （对齐 internal/handlers/cgi_io.go）。执行/鉴权落在 molly:backend（CGI_Exec/CGI_Download/CGI_Backup）。
//
// 前端把三件套挂在 `<cgi_base>/cgi-exec`、`cgi-download`、`cgi-upload`、`cgi-backup`；本部署
// cgi_base=""（SCRIPT_NAME 去最后一段为空）→ 裸 /cgi-exec 等。会话来自 **POST 表单里的 sessionid
// 字段**（不是 cookie）；命令/路径能不能过由 backend 的 file.* ACL 兜底（fail-closed）。
//
// 响应形态（对齐前端 handleCgiIoReply）：
//   - exec/download/backup：成功 200 + application/octet-stream 原始字节（无 Content-Length，
//     connection-close 分帧）；失败在**未发出响应头前**按 ubus 码映射 HTTP（400/403/404/504/500）。
//   - upload：恒 200 + JSON，成功 {name,size,checksum,sha256sum}、失败 {failure:true,message}。

import "core:strings"
import "core:fmt"
import "core:time"
import "core:c"
import "core:encoding/json"
import "core:encoding/hex"
import "core:crypto/legacy/md5"
import "core:crypto/sha2"
import "core:sys/posix"
import "molly:http"
import "molly:backend"

// cgi_io_stream_ct —— exec/download/backup 流式输出的响应类型（上游 cgi-io 用八位字节流）。
cgi_io_stream_ct :: "application/octet-stream"

// CGIIO_Endpoint 标识命中的四端点之一。
CGIIO_Endpoint :: enum { exec, download, upload, backup }

// cgi_base_of —— 复现前端 luci.js 的 `cgi_base = scriptname.replace(/\/[^/]+$/, "")`：把 SCRIPT_NAME
// （cgi_script_name）去掉最后一段路径。main 与路由共用这一个值（cgi-io 拦截与 SCRIPT_NAME 必须同源）。
cgi_base_of :: proc(prefix, strip: string) -> string {
	s := cgi_script_name(prefix, strip)
	if i := strings.last_index_byte(s, '/'); i >= 0 {
		return s[0:i]
	}
	return ""
}

// cgi_io_endpoint_of —— path 是否正好命中四端点之一（cgi_base+名字的全等，不做前缀匹配，避免吃掉
// /cgi-exec/anything）。命中返回端点与 true。
cgi_io_endpoint_of :: proc(path, base: string) -> (CGIIO_Endpoint, bool) {
	if path == build([]string{base, "/cgi-exec"}) {
		return .exec, true
	}
	if path == build([]string{base, "/cgi-download"}) {
		return .download, true
	}
	if path == build([]string{base, "/cgi-upload"}) {
		return .upload, true
	}
	if path == build([]string{base, "/cgi-backup"}) {
		return .backup, true
	}
	return .exec, false
}

// Is_CGI_IO_Path —— 供路由判定：path 是否是 cgi-io 端点之一（在 Serve_Static 之前拦截）。
Is_CGI_IO_Path :: proc(path, base: string) -> bool {
	_, ok := cgi_io_endpoint_of(path, base)
	return ok
}

// Serve_CGI_IO —— 处理四端点。path 必须是 Normalize_Path 产物；只有 POST 有意义（前端三件套都
// request.post），其余方法回 405（与 uhttpd 对非 GET 静态路径一致）。
Serve_CGI_IO :: proc(res: ^http.Response, req: ^http.Request, path, base: string) {
	if req.method != "POST" {
		http.Respond(res, 405, "method not allowed\n", "text/plain; charset=utf-8")
		return
	}
	ep, ok := cgi_io_endpoint_of(path, base)
	if ! ok {
		http.Not_Found(res, path)
		return
	}
	switch ep {
	case .exec:    serve_cgi_exec(res, req)
	case .download: serve_cgi_download(res, req)
	case .upload:   serve_cgi_upload(res, req)
	case .backup:   serve_cgi_backup(res, req)
	}
}

serve_cgi_exec :: proc(res: ^http.Response, req: ^http.Request) {
	form := http.Parse_Form(req)
	sid, _ := http.KV_Get(form, "sessionid")
	command, _ := http.KV_Get(form, "command")
	want_stderr, _ := http.KV_Get(form, "stderr")
	data, st := backend.CGI_Exec(sid, command, want_stderr == "1")
	if st != backend.Status_OK {
		cgi_io_error(res, st)
		return
	}
	cgi_io_stream(res, data, nil)
}

serve_cgi_download :: proc(res: ^http.Response, req: ^http.Request) {
	form := http.Parse_Form(req)
	sid, _ := http.KV_Get(form, "sessionid")
	p, _ := http.KV_Get(form, "path")
	data, st := backend.CGI_Download(sid, p)
	if st != backend.Status_OK {
		cgi_io_error(res, st)
		return
	}
	cgi_io_stream(res, data, nil)
}

serve_cgi_backup :: proc(res: ^http.Response, req: ^http.Request) {
	form := http.Parse_Form(req)
	sid, _ := http.KV_Get(form, "sessionid")
	data, st := backend.CGI_Backup(sid)
	if st != backend.Status_OK {
		cgi_io_error(res, st)
		return
	}
	// 归档以附件下载（Content-Disposition）。文件名对齐 Go cgiBackupDownloadHeader：
	// backup-<hostname>-<yyyymmdd-hhmm>.tar.gz（此前硬编码 backup.tar.gz，丢了日期/主机名）。
	name := cgi_backup_name(cgi_backup_hostname(), time.now())
	disp := build([]string{"attachment; filename=\"", name, "\""})
	extra := []http.Header{http.Header{"Content-Disposition", disp}}
	cgi_io_stream(res, data, extra)
}

// cgi_backup_hostname —— posix gethostname（对齐 Go os.Hostname）：返回原始主机名，
// 调用失败或为空时回退 "backup"。清洗在 cgi_backup_name 里做（与 Go 先 sanitize 再拼接同序）。
cgi_backup_hostname :: proc() -> string {
	buf: [256]c.char
	out: [dynamic]u8
	defer delete(out)
	if posix.gethostname(cast([^]c.char)&buf[0], cast(c.size_t)size_of(buf)) == .OK {
		for i := 0; i < len(buf); i += 1 {
			b := cast(u8)buf[i]
			if b == 0 {
				break
			}
			append(&out, b)
		}
		if len(out) > 0 {
			return finalize_string(&out)
		}
	}
	return "backup"
}

// cgi_backup_name —— 归档下载文件名：backup-<hostname>-<yyyymmdd-hhmm>.tar.gz（对齐 Go
// cgiBackupDownloadHeader）。host 里不适合文件名的字符转下划线，空/失败回退 "backup"。
// 时间戳按 UTC 取（time.date/clock_from_time 走裸 Unix 时间）：设备无 /etc/localtime 时
// Go 的 time.Now() 同样是 UTC，二者在真机上逐字节一致。
cgi_backup_name :: proc(host: string, t: time.Time) -> string {
	h := sanitize_filename_token(host)
	if h == "" {
		h = "backup"
	}
	y, mo, d := time.date(t)
	hh, mi, _ := time.clock_from_time(t)
	stamp := fmt.tprintf("%04d%02d%02d-%02d%02d", y, int(mo), d, hh, mi)
	return build([]string{"backup-", h, "-", stamp, ".tar.gz"})
}

// serve_cgi_upload —— ui.uploadFile 的完整实现（对齐 Go serveCGIUpload）：解析 multipart/form-data，
// 取 sessionid / filename（目标路径）/ filedata（文件本体），落盘后对 filedata 全量算 size/MD5/SHA256，
// 恒 200 + JSON（成功 {name,size,checksum,sha256sum}、失败 {failure:true,message}）。
serve_cgi_upload :: proc(res: ^http.Response, req: ^http.Request) {
	ct, _ := http.Header_Get(req, "Content-Type")
	boundary := multipart_boundary(ct)
	if ! strings.has_prefix(strings.to_lower(ct), "multipart/") || boundary == "" {
		upload_reply_failure(res, "invalid or missing multipart body")
		return
	}
	form := parse_multipart(req.body, boundary)
	if ! form.has_file {
		upload_reply_failure(res, "missing file field")
		return
	}
	if st := backend.CGI_Upload(form.sessionid, form.filename, form.filedata); st != backend.Status_OK {
		upload_reply_failure(res, cgi_io_word_for(st))
		return
	}
	// Go 用 TeeReader 边写边累计；此处 filedata 已整段缓冲在 req.body，等价地全量哈希。
	mctx: md5.Context
	md5.init(&mctx)
	md5.update(&mctx, form.filedata)
	msum: [md5.DIGEST_SIZE]u8
	md5.final(&mctx, msum[:])
	sctx: sha2.Context_256
	sha2.init_256(&sctx)
	sha2.update(&sctx, form.filedata)
	ssum: [sha2.DIGEST_SIZE_256]u8
	sha2.final(&sctx, ssum[:])
	mb := hex.encode(msum[:])
	sb := hex.encode(ssum[:])
	upload_reply_success(res, form.filename, len(form.filedata), string(mb), string(sb))
}

// Upload_Form —— multipart 里三件套的抽取结果。filedata 是指向 req.body 的零拷贝切片。
Upload_Form :: struct {
	sessionid: string,
	filename:  string, // 目标路径（前端 filename 字段，非文件部件自带的 filename）
	filedata:  []u8,
	has_file:  bool,
}

// multipart_boundary —— 从 Content-Type 头取 boundary= 值（保留原始大小写；支持带引号，
// 未加引号则读到 ';' / 空白 / CRLF 为止）。
multipart_boundary :: proc(ct: string) -> string {
	i := strings.index(strings.to_lower(ct), "boundary=")
	if i < 0 {
		return ""
	}
	v := ct[i + len("boundary="):]
	for len(v) > 0 && v[0] == ' ' {
		v = v[1:]
	}
	if len(v) > 0 && v[0] == '"' {
		q := v[1:]
		if e := strings.index_byte(q, '"'); e >= 0 {
			return q[:e]
		}
		return q
	}
	e := 0
	for e < len(v) && v[e] != ';' && v[e] != ' ' && v[e] != '\t' && v[e] != '\r' && v[e] != '\n' {
		e += 1
	}
	return v[:e]
}

// multipart_find —— 在 hay[from:] 里找 nee 的首个下标（按字节比，对二进制安全、不假设 UTF-8）。
multipart_find :: proc(hay: []u8, nee: []u8, from_in: int) -> int {
	from := from_in
	if from < 0 {
		from = 0
	}
	if len(nee) == 0 || from + len(nee) > len(hay) {
		return -1
	}
	i := from
	for i + len(nee) <= len(hay) {
		match := true
		for j := 0; j < len(nee); j += 1 {
			if hay[i+j] != nee[j] {
				match = false
				break
			}
		}
		if match {
			return i
		}
		i += 1
	}
	return -1
}

// multipart_field_name —— 从部件头部块取 Content-Disposition 的 name= 值（跳过 filename= 的子串）。
multipart_field_name :: proc(hdrs: []u8) -> string {
	hs := string(hdrs)
	off := 0
	for {
		r := strings.index(hs[off:], "name=")
		if r < 0 {
			return ""
		}
		k := off + r
		if k > 0 {
			p := hs[k-1]
			is_alnum := (p >= 'a' && p <= 'z') || (p >= 'A' && p <= 'Z') || (p >= '0' && p <= '9')
			if is_alnum { // 命中 filename= 里的 name=，继续往后找
				off = k + len("name=")
				continue
			}
		}
		rest := hs[k + len("name="):]
		for len(rest) > 0 && rest[0] == ' ' {
			rest = rest[1:]
		}
		if len(rest) == 0 {
			return ""
		}
		if rest[0] == '"' {
			q := rest[1:]
			if e := strings.index_byte(q, '"'); e >= 0 {
				return q[:e]
			}
			return ""
		}
		e := 0
		for e < len(rest) && rest[e] != ';' && rest[e] != ' ' && rest[e] != '\r' && rest[e] != '\n' {
			e += 1
		}
		return rest[:e]
	}
}

// parse_multipart —— 按 boundary 切部件，抽取 sessionid / filename / filedata（对齐 Go 的
// ParseMultipartForm + FormValue("filename") + FormFile("filedata")）。分隔符假设不出现在内容里
// （浏览器生成随机 boundary，上游 Go 同样依赖此假设）。
parse_multipart :: proc(body: []u8, boundary: string) -> Upload_Form {
	f: Upload_Form
	dd := build([]string{"--", boundary})
	delim := transmute([]u8)(dd)
	blank_str := "\r\n\r\n"
	blank := transmute([]u8)(blank_str)
	pos := multipart_find(body, delim, 0)
	if pos < 0 {
		return f
	}
	for {
		next := pos + len(delim)
		if next + 2 <= len(body) && body[next] == '-' && body[next+1] == '-' {
			break // 闭合分隔符 --BOUNDARY--
		}
		if next + 2 <= len(body) && body[next] == '\r' && body[next+1] == '\n' {
			next += 2 // 跳过分隔符后的 CRLF
		}
		after := multipart_find(body, delim, next)
		seg_end := len(body)
		if after >= 0 {
			seg_end = after
		}
		hi := seg_end
		if hi >= 2 && body[hi-2] == '\r' && body[hi-1] == '\n' {
			hi -= 2 // 紧邻下一分隔符前的 CRLF 属于分隔符，不属于内容
		}
		seg := body[next:hi]
		sep := multipart_find(seg, blank, 0)
		if sep >= 0 {
			data := seg[sep + 4:]
			name := multipart_field_name(seg[:sep])
			if name == "sessionid" {
				f.sessionid = string(data)
			} else if name == "filename" {
				f.filename = string(data)
			} else if name == "filedata" {
				f.filedata = data
				f.has_file = true
			}
		}
		if after < 0 {
			break
		}
		pos = after
	}
	return f
}

// upload_reply_success —— 200 + {name,size,checksum,sha256sum}（与 Go writeUploadReply 的成功形同一 JSON）。
upload_reply_success :: proc(res: ^http.Response, name: string, size: int, md5_hex: string, sha_hex: string) {
	obj := make(json.Object)
	obj["name"] = json.String(name)
	obj["size"] = json.Integer(size)
	obj["checksum"] = json.String(md5_hex)
	obj["sha256sum"] = json.String(sha_hex)
	http.Respond(res, 200, json_unparse(json.Value(obj)), "application/json")
}

// cgi_io_stream —— 未发头前成功产出：200 + octet-stream + 可选额外头，再刷原始字节。零字节也回
// 规整 200（八位字节流空体）。Write_Head 不带 Content-Length → connection-close 分帧。
cgi_io_stream :: proc(res: ^http.Response, data: []u8, extra: []http.Header) {
	hdrs: [dynamic]http.Header
	defer delete(hdrs)
	for h in extra {
		append(&hdrs, h)
	}
	append(&hdrs, http.Header{"Content-Type", cgi_io_stream_ct})
	http.Write_Head(res, 200, hdrs[:])
	if len(data) > 0 {
		http.Write_Chunk(res, data)
	}
}

// cgi_io_error —— 把 backend 的 ubus 码映射成 handleCgiIoReply 认识的 HTTP 码 + 文本正文。
cgi_io_error :: proc(res: ^http.Response, st: i32) {
	code := 500
	switch st {
	case backend.Status_Invalid_Argument:  code = 400
	case backend.Status_Permission_Denied: code = 403
	case backend.Status_Not_Found:         code = 404
	case backend.Status_Timeout:           code = 504
	}
	http.Respond(res, code, build([]string{cgi_io_word_for(st), "\n"}), "text/plain; charset=utf-8")
}

upload_reply_failure :: proc(res: ^http.Response, message: string) {
	obj := make(json.Object)
	obj["failure"] = json.Boolean(true)
	obj["message"] = json.String(message)
	http.Respond(res, 200, json_unparse(json.Value(obj)), "application/json")
}

// cgi_io_word_for —— 给状态码一个人类可读的词（upload message 与 exec/download 错误正文共用）。
cgi_io_word_for :: proc(st: i32) -> string {
	switch st {
	case backend.Status_Invalid_Argument:  return "invalid argument"
	case backend.Status_Permission_Denied: return "permission denied"
	case backend.Status_Not_Found:         return "not found"
	case backend.Status_Timeout:           return "timeout"
	}
	return "internal error"
}

// sanitize_filename_token —— 主机名里不适合出现在文件名/头部的字符换成下划线。
sanitize_filename_token :: proc(s: string) -> string {
	b: [dynamic]u8
	defer delete(b)
	for i := 0; i < len(s); i += 1 {
		c := s[i]
		ok := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
			c == '.' || c == '-' || c == '_'
		if ok {
			append(&b, c)
		} else {
			append(&b, '_')
		}
	}
	return finalize_string(&b)
}
