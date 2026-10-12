package handlers

// cgi-io —— fs.exec_direct / fs.read_direct / ui.uploadFile 三件套，外加专家版备份 cgi-backup。
//
// 前端把这些挂在 `<cgi_base>/cgi-exec`、`cgi-download`、`cgi-upload`、`cgi-backup` 上（cgi_base 由
// luci.js 从 scriptname 去掉最后一段推得），上游由 /usr/libexec/cgi-io 这个 CGI 二进制提供。
// molly 在 Go 侧原生实现同一个 HTTP 契约（替换 uhttpd 的应有之义），执行/鉴权落在
// backend/cgi_io.go：exec 走与 ubus file.exec 同源的 file.exec 白名单，download 走 file.read
// ACL，upload 走 file.write ACL。安全边界与既有 file.exec 一致，不新开执行面。
//
// 会话来自 **POST 表单里的 sessionid 字段**（fs.js 明确 `sessionid=encodeURIComponent(L.env.sessionid)`），
// 不是 cookie；命令/路径本身能不能过由 backend 的 file.* ACL 兜底（fail-closed）。
//
// 响应形态（对齐前端 handleCgiIoReply / ui.js 的 res.json()）：
//   - exec / download：**流式**吐原始输出（200，无 Content-Length），出错时按 ubus 码映射 HTTP
//     （400/403/404/504/500），前端据此还原 InvalidArgument/Permission/NotFound 错误名。
//   - upload：恒 200 + JSON。成功 `{name,size,checksum,sha256sum}`；失败 `{failure:true,message}`
//     （JS 直接 res.json() 再看 reply.failure，所以错误也用 200 承载）。

import (
	"crypto/md5"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/azhai/molly/internal/backend"
)

// cgiIOStreamContentType 是 exec/download 流式输出的响应类型（上游 cgi-io 用八位字节流）。
const cgiIOStreamContentType = "application/octet-stream"

// cgiIOEndpoint 标识命中的三件套之一。
type cgiIOEndpoint int

const (
	cgiIOExec cgiIOEndpoint = iota
	cgiIODownload
	cgiIOUpload
	cgiIOBackup
)

// cgiBasePrefix 复现前端 luci.js 的 `cgi_base = scriptname.replace(/\/[^/]+$/,”)`：把
// SCRIPT_NAME（cgiScriptName）去掉最后一段路径。
//
// 本部署（--luci-prefix /admin、--luci-strip admin）SCRIPT_NAME="" → cgi_base=""，于是三件套
// 落在裸 /cgi-exec、/cgi-download、/cgi-upload。上游默认（--luci-prefix /cgi-bin/luci、不 strip）
// → cgi_base="/cgi-bin"，与 uhttpd 把 cgi-io 挂在 /cgi-bin/cgi-* 的位置逐字一致。
func cgiBasePrefix() string {
	s := cgiScriptName()
	if i := strings.LastIndexByte(s, '/'); i >= 0 {
		return s[:i]
	}
	return ""
}

// cgiIOEndpointOf 判定 path 是否是三件套之一（含 cgi_base 前缀）；命中返回端点与 true。
// 只在 path **正好等于** base+名字时命中，不做前缀匹配（避免吃掉 /cgi-exec/anything）。
func cgiIOEndpointOf(path string) (cgiIOEndpoint, bool) {
	base := cgiBasePrefix()
	for _, e := range []struct {
		name string
		ep   cgiIOEndpoint
	}{
		{"/cgi-exec", cgiIOExec},
		{"/cgi-download", cgiIODownload},
		{"/cgi-upload", cgiIOUpload},
		{"/cgi-backup", cgiIOBackup},
	} {
		if path == base+e.name {
			return e.ep, true
		}
	}
	return 0, false
}

// IsCGIIOPath 供路由判定：path 是否是 cgi-io 端点之一（用于在 ServeStatic 之前拦截）。
func IsCGIIOPath(path string) bool {
	_, ok := cgiIOEndpointOf(path)
	return ok
}

// ServeCGIIO 处理 cgi-io 三件套。path 必须是 NormalizePath 的产物；只有 POST 有意义
// （前端三件套都 request.post），其余方法回 405（与 uhttpd 对非 GET 静态路径一致）。
func ServeCGIIO(w http.ResponseWriter, r *http.Request, path string) {
	if r.Method != http.MethodPost {
		Respond(w, r, http.StatusMethodNotAllowed, "method not allowed\n", "text/plain; charset=utf-8")
		return
	}
	ep, ok := cgiIOEndpointOf(path)
	if !ok {
		notFound(w, r, path)
		return
	}
	switch ep {
	case cgiIOExec:
		serveCGIExec(w, r)
	case cgiIODownload:
		serveCGIDownload(w, r)
	case cgiIOUpload:
		serveCGIUpload(w, r)
	case cgiIOBackup:
		serveCGIBackup(w, r)
	}
}

// serveCGIExec：application/x-www-form-urlencoded，字段 sessionid / command / stderr(0|1)。
// command 是前端做完反斜杠转义 + URL 编码的整串；ParseForm 解掉 URL 编码后交 backend 反分词。
func serveCGIExec(w http.ResponseWriter, r *http.Request) {
	if err := r.ParseForm(); err != nil {
		writeCGIIOError(w, r, backend.StatusInvalidArgument)
		return
	}
	sid := r.FormValue("sessionid")
	command := r.FormValue("command")
	wantStderr := r.FormValue("stderr") == "1"

	sw := &streamWriter{w: w}
	if st := backend.CGIExec(sid, command, wantStderr, sw); st != backend.StatusOK {
		// 一旦流式写过输出，HTTP 状态已定（200），只能在流末尾收场（cgi-io 语义）。
		if !sw.headerSent {
			writeCGIIOError(w, r, st)
		}
		return
	}
	sw.finish() // 命令零输出也回一个规整的 200（八位字节流，空体）
}

// serveCGIDownload：urlencoded，字段 sessionid / path。流式吐文件内容。
func serveCGIDownload(w http.ResponseWriter, r *http.Request) {
	if err := r.ParseForm(); err != nil {
		writeCGIIOError(w, r, backend.StatusInvalidArgument)
		return
	}
	sid := r.FormValue("sessionid")
	p := r.FormValue("path")

	sw := &streamWriter{w: w}
	if st := backend.CGIDownload(sid, p, sw); st != backend.StatusOK {
		if !sw.headerSent {
			writeCGIIOError(w, r, st)
		}
		return
	}
	sw.finish()
}

// serveCGIUpload：multipart/form-data，字段 sessionid / filename（目标路径）/ filedata（文件本体）。
// 用 TeeReader 边写边累计 size + MD5 + SHA256，成功/失败都以 200+JSON 承载（见文件头）。
func serveCGIUpload(w http.ResponseWriter, r *http.Request) {
	if err := r.ParseMultipartForm(32 << 20); err != nil {
		writeUploadReply(w, r, map[string]any{"failure": true, "message": "invalid or missing multipart body"})
		return
	}
	defer r.MultipartForm.RemoveAll()

	sid := r.FormValue("sessionid")
	filename := r.FormValue("filename")

	file, _, err := r.FormFile("filedata")
	if err != nil {
		writeUploadReply(w, r, map[string]any{"failure": true, "message": "missing file field"})
		return
	}
	defer file.Close()

	counter := &byteCounter{}
	md, sha := md5.New(), sha256.New()
	src := io.TeeReader(file, counter)
	src = io.TeeReader(src, io.MultiWriter(md, sha))

	if st := backend.CGIUpload(sid, filename, src); st != backend.StatusOK {
		writeUploadReply(w, r, map[string]any{"failure": true, "message": cgiIOWordFor(st)})
		return
	}
	writeUploadReply(w, r, map[string]any{
		"name":      filename,
		"size":      counter.n,
		"checksum":  hex.EncodeToString(md.Sum(nil)),
		"sha256sum": hex.EncodeToString(sha.Sum(nil)),
	})
}

// serveCGIBackup：urlencoded，字段 sessionid。跑固定的 `/sbin/sysupgrade -b -`，把归档
// 以附件流式下载（Content-Disposition）。与上游 cgi-backup 一致：会话必须是已登录的，
// 具体能不能跑由 file.exec 白名单兜底（fail-closed）。
//
// 响应头必须等 backend 确认 ACL 通过、即将产出第一个字节时才发出（未发头前可把失败映射成
// 4xx）；sysupgrade 在 ACL 通过前不向 out 写，故 headerSent 为假即代表尚未提交状态码。
func serveCGIBackup(w http.ResponseWriter, r *http.Request) {
	if err := r.ParseForm(); err != nil {
		writeCGIIOError(w, r, backend.StatusInvalidArgument)
		return
	}
	sid := r.FormValue("sessionid")

	sw := &streamWriter{
		w:      w,
		header: cgiBackupDownloadHeader(),
	}
	if st := backend.CGIBackup(sid, sw); st != backend.StatusOK {
		if !sw.headerSent {
			writeCGIIOError(w, r, st)
		}
		return
	}
	// 归档零字节（不应发生）仍补一个规整的 200 下载头。
	sw.finish()
}

// cgiBackupDownloadHeader 构造下载归档所需的额外响应头（八位字节流 + 带文件名的附件）。
// 文件名形如 backup-<hostname>-<yyyymmdd-hhmm>.tar.gz，与上游习惯一致。
func cgiBackupDownloadHeader() http.Header {
	h := http.Header{}
	host, err := os.Hostname()
	if err != nil || host == "" {
		host = "backup"
	}
	host = sanitizeFilenameToken(host)
	name := "backup-" + host + "-" + time.Now().Format("20060102-1504") + ".tar.gz"
	h.Set("Content-Disposition", `attachment; filename="`+name+`"`)
	return h
}

// sanitizeFilenameToken 把主机名里不适合出现在文件名/头部的字符换成下划线。
func sanitizeFilenameToken(s string) string {
	b := []byte(s)
	for i, c := range b {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '.' || c == '-' || c == '_') {
			b[i] = '_'
		}
	}
	return string(b)
}

// streamWriter 把 backend 的流式输出直接接到 http.ResponseWriter：首次 Write 前补发
// 200 响应头（此后无法再改状态码）。headerSent 让 handler 判断「还没发出响应头」
// 时才好把 ACL/校验失败映射成错误状态。header 非 nil 时并入（如 cgi-backup 的下载头）。
type streamWriter struct {
	w          http.ResponseWriter
	header     http.Header // 额外响应头（可空）；Content-Type 固定为八位字节流
	headerSent bool
}

func (s *streamWriter) Write(p []byte) (int, error) {
	if !s.headerSent {
		s.sendHeader()
	}
	return s.w.Write(p)
}

func (s *streamWriter) sendHeader() {
	h := s.w.Header()
	h["Date"] = nil // 与本项目其余响应一致：抑制 net/http 自动补的 Date
	for k, vs := range s.header {
		for _, v := range vs {
			h.Add(k, v)
		}
	}
	h.Set("Content-Type", cgiIOStreamContentType)
	s.w.WriteHeader(http.StatusOK)
	s.headerSent = true
}

// finish：成功但一个字节都没写出（命令无输出 / 空文件）时，仍补一个规整的 200 头。
func (s *streamWriter) finish() {
	if !s.headerSent {
		s.sendHeader()
	}
}

// byteCounter 统计写过的字节数（upload 回复里的 size）。
type byteCounter struct{ n int64 }

func (c *byteCounter) Write(p []byte) (int, error) { c.n += int64(len(p)); return len(p), nil }

// writeCGIIOError：把 backend 的 ubus 状态码映射成 handleCgiIoReply 认识的 HTTP 码
// （400→InvalidArgument、403→Permission、404→NotFound，其余→通用 Error）。
func writeCGIIOError(w http.ResponseWriter, r *http.Request, st int) {
	code := http.StatusInternalServerError
	switch st {
	case backend.StatusInvalidArgument:
		code = http.StatusBadRequest
	case backend.StatusPermissionDenied:
		code = http.StatusForbidden
	case backend.StatusNotFound:
		code = http.StatusNotFound
	case backend.StatusTimeout:
		code = http.StatusGatewayTimeout
	}
	Respond(w, r, code, cgiIOWordFor(st)+"\n", "text/plain; charset=utf-8")
}

// writeUploadReply 以 200 + application/json 回一个对象（成功或 {failure,message}）。
func writeUploadReply(w http.ResponseWriter, r *http.Request, obj map[string]any) {
	body, err := json.Marshal(obj)
	if err != nil {
		body = []byte("{}")
	}
	Respond(w, r, http.StatusOK, string(body), "application/json")
}

// cgiIOWordFor 给状态码一个人类可读的词（upload 的 message、exec/download 错误正文共用）。
func cgiIOWordFor(st int) string {
	switch st {
	case backend.StatusInvalidArgument:
		return "invalid argument"
	case backend.StatusPermissionDenied:
		return "permission denied"
	case backend.StatusNotFound:
		return "not found"
	case backend.StatusTimeout:
		return "timeout"
	default:
		return "internal error"
	}
}
