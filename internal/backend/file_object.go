package backend

// file 对象 —— molly 自持的 ubus 对象之一（对齐 Odin 版 src/backend/file_object.odin，
// 后者逐行对照 rpcd@e37ed9d8 的 file.c）。
//
// 8 个方法（file.c:1227-1234 的方法表）：read / write / list / lstat / stat / md5 /
// remove / exec。**平台无关**：只用 os / os/exec，无 build tag，darwin 与 linux 共用
// （与 Odin 版一致，file 不是平台 provider）。
//
// **权限名按方法各不相同**（上游照抄，改错一个 golden 就对不上）：
//
//	read/md5        → "read"
//	write/remove    → "write"
//	list/stat/lstat → "list"
//	exec            → "exec"
//
// 安全要点（务必照抄，别简化）：路径的 ACL 按**文本**匹配，所以 file.c:261-359 的顺序是
//   1) 先把路径规范化（file.c:189-248，折掉 `//`、`/./`、`/../` 与结尾的 `/`）；
//   2) 用规范化后的路径查 ACL（session.access("file", <path>, <perm>)）；
//   3) 再用 realpath(3) 解析一次符号链接；解析结果与文本路径不同就对**解析后**的路径
//      再查一遍 ACL，并把后续操作都改成对解析后的路径做。
// 不做第 3 步的话：「ACL 授权了 /tmp/x/、攻击者在 /tmp/x/ 里放一个指向 /etc/shadow 的
// 符号链接」就能读到 /etc/shadow。
//
// 偏离（与 Odin 版一致，见 docs/interfaces.md §9.3）：stat 回复省略 uid/gid/user/group
// （上游用 getpwuid/getgrgid 补用户名，Odin 的 File_Info 也不含 uid/gid）；atime/ctime/inode
// 照抄 Odin 一并回，平台字段名差异由 fileStatMeta 钩子吸收（darwin.go / linux.go 各一份）。
// exec 是同步实现（上游 uloop 异步回包，对调用方可观测行为一致）。

import (
	"context"
	"crypto/md5"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

const (
	// file.c:43-46
	fileMinSize = 4096
	fileMaxSize = 4096 * 64

	// RPC_EXEC_DEFAULT_TIMEOUT（exec.h:27）
	fileExecTimeout = 120 * time.Second
	// RPC_CMDLINE_MAX_SIZE（file.c:49）：整条命令行 ACL 对象的上限
	fileExecCmdlineMax = 1024
	// 参数个数上限（file.c:1073）
	fileExecMaxArgs = 255
	// 输出上限：上游是 ustream 缓冲（libubox 内部大小），满 → 8；这里取 64KB 近似
	fileExecOutputCap = 64 * 1024
)

// callFile 是 file 对象的调用入口（与 uci_call / session_call 同形）。
// status==0 成功，reply 是 JSON 文本（可为 ""）；status!=0 是 ubus 状态码。
func callFile(method, paramsJSON string) (string, int) {
	var params map[string]json.RawMessage
	if len(paramsJSON) > 0 {
		if err := json.Unmarshal([]byte(paramsJSON), &params); err != nil {
			params = nil
		}
	}
	sid, _ := paramStr(params, "ubus_rpc_session")

	switch method {
	case "read":
		return fileMethodRead(params, sid)
	case "write":
		return fileMethodWrite(params, sid)
	case "list":
		return fileMethodList(params, sid)
	case "lstat":
		return fileMethodLstat(params, sid)
	case "stat":
		return fileMethodStat(params, sid)
	case "md5":
		return fileMethodMd5(params, sid)
	case "remove":
		return fileMethodRemove(params, sid)
	case "exec":
		return fileMethodExec(params, sid)
	}
	return "", StatusMethodNotFound
}

// ---------------------------------------------------------------------------
// 路径与错误
// ---------------------------------------------------------------------------

// fileStatusOf 是 file.c:157-177 rpc_errno_status 的等价映射。
func fileStatusOf(err error) int {
	switch {
	case err == nil:
		return StatusOK
	case errors.Is(err, os.ErrNotExist):
		return StatusNotFound
	case errors.Is(err, os.ErrPermission):
		return StatusPermissionDenied
	case errors.Is(err, syscall.ENOTDIR), errors.Is(err, syscall.EINVAL):
		return StatusInvalidArgument
	}
	return StatusUnknownError
}

// fileCanonicalizePath 是 file.c:189-248 rpc_canonicalize_path（纯函数，可单测）。
// 只做**文本**折叠：重复的 `/`、`/./`、结尾的 `/`（根目录除外）。上游的 `/../` **只在
// `..` 之后是 `/` 或结尾时才折叠**（`..` 必须是完整片段）——安全靠后面的 realpath 复查兜底。
// 空路径 → false（上游返回 NULL → EINVAL → 2）。
func fileCanonicalizePath(path string) (string, bool) {
	if len(path) == 0 {
		return "", false
	}
	buf := make([]byte, len(path)+1)
	cp := 0
	p := 0
	for p < len(path) {
		if path[p] != '/' {
			buf[cp] = path[p]
			cp++
			p++
			continue
		}

		// 重复的 `/`
		if p+1 < len(path) && path[p+1] == '/' {
			p++
			continue
		}

		if p+1 < len(path) && path[p+1] == '.' {
			// `/./`
			if p+2 == len(path) || path[p+2] == '/' {
				p += 2
				continue
			}
			// `/../`：游标回退到上一个 `/`（停在那个 / 上，等着被下一个字符覆盖）
			if p+2 < len(path) && path[p+2] == '.' && (p+3 == len(path) || path[p+3] == '/') {
				for cp > 0 {
					cp--
					if buf[cp] == '/' {
						break
					}
				}
				p += 3
				continue
			}
		}

		buf[cp] = path[p]
		cp++
		p++
	}

	// 去掉结尾的 `/`（根目录除外）；空串补成 `/`
	if cp > 1 && buf[cp-1] == '/' {
		cp--
	} else if cp == 0 {
		buf[0] = '/'
		cp = 1
	}
	return string(buf[:cp]), true
}

// fileRealpath 是 realpath(3) 的等价物：解析符号链接后的绝对路径。失败返回 false。
func fileRealpath(path string) (string, bool) {
	abs, err := filepath.Abs(path)
	if err != nil {
		return "", false
	}
	resolved, err := filepath.EvalSymlinks(abs)
	if err != nil {
		return "", false
	}
	return resolved, true
}

// fileACLOk：file.c:180-187 rpc_file_access。sid 缺失（内部调用）不做访问控制。
func fileACLOk(sid, path, perm string) bool {
	if len(sid) == 0 {
		return true
	}
	return sessionAccess(sid, "file", path, perm)
}

// fileCheckSymlinkAccess：file.c:261-359 rpc_check_symlink_access。返回（可能被替换的路径,
// 挂起的状态码）：
//   - 没有符号链接（realpath 结果与文本路径相同）→ 原路径、0
//   - 有符号链接 → 对**解析后的路径**再查 ACL，通过就换成解析后的路径
//   - realpath 失败且路径本身是符号链接（悬空链接）→ 6
//   - realpath 失败（目标不存在）→ 解析父目录后拼回 basename 再查 ACL；父目录没变说明
//     目标确实不存在 → 4（路径仍被替换）
func fileCheckSymlinkAccess(sid, perm, path string) (string, int) {
	if resolved, ok := fileRealpath(path); ok {
		if resolved == path {
			return path, 0
		}
		if !fileACLOk(sid, resolved, perm) {
			return "", StatusPermissionDenied
		}
		return resolved, 0
	}

	// 悬空的符号链接：看起来「不存在」，但对 open(O_CREAT) 来说是必须拒绝的
	if _, err := os.Readlink(path); err == nil {
		return "", StatusPermissionDenied
	}

	slash := strings.LastIndexByte(path, '/')
	if slash < 0 {
		return "", StatusNotFound
	}

	dir := "/"
	if slash != 0 {
		dir = path[:slash]
	}
	base := path[slash+1:]

	resolvedDir, dirOK := fileRealpath(dir)
	if !dirOK {
		return "", StatusUnknownError
	}
	if resolvedDir == dir {
		// 父目录没变 → 目标确实不存在
		return path, StatusNotFound
	}

	newPath := resolvedDir + "/" + base
	if !fileACLOk(sid, newPath, perm) {
		return "", StatusPermissionDenied
	}
	return newPath, StatusNotFound
}

// fileCheckPath：file.c:361-416 __rpc_check_path。规范化 → ACL →（read/list/stat/md5）
// 符号链接复查 →（可选）stat。use_lstat=true 时不解析符号链接（lstat 看链接本身，
// remove 靠 unlink 的 no-follow）。
func fileCheckPath(sid, perm, raw string, needStat, useLstat bool) (string, os.FileInfo, int) {
	canon, ok := fileCanonicalizePath(raw)
	if !ok {
		return "", nil, StatusInvalidArgument
	}
	if !fileACLOk(sid, canon, perm) {
		return "", nil, StatusPermissionDenied
	}

	path := canon
	if !useLstat {
		newPath, pending := fileCheckSymlinkAccess(sid, perm, canon)
		if newPath == "" {
			return "", nil, pending
		}
		path = newPath
		// 挂起的 ENOENT：只有接下来要 stat 时才会变成错误（write 要 create，不能提前失败）
		if needStat && pending == StatusNotFound {
			return path, nil, pending
		}
	}

	if !needStat {
		return path, nil, StatusOK
	}

	var (
		info os.FileInfo
		err  error
	)
	if useLstat {
		info, err = os.Lstat(path)
	} else {
		info, err = os.Stat(path)
	}
	if err != nil {
		return path, info, fileStatusOf(err)
	}
	return path, info, StatusOK
}

// ---------------------------------------------------------------------------
// 类型 / mode / stat 回复
// ---------------------------------------------------------------------------

// file_type_str（file.c:145-154 d_types）。
func fileTypeStr(m os.FileMode) string {
	switch {
	case m&os.ModeDir != 0:
		return "directory"
	case m&os.ModeSymlink != 0:
		return "symlink"
	case m&os.ModeNamedPipe != 0:
		return "fifo"
	case m&os.ModeSocket != 0:
		return "socket"
	case m&os.ModeDevice != 0:
		if m&os.ModeCharDevice != 0 {
			return "char"
		}
		return "block"
	case m&os.ModeCharDevice != 0:
		return "char"
	}
	return "file"
}

// 上游回的 mode 是完整 st_mode（含类型位）。Go 的 FileMode 类型位与 unix 位不同，
// 这里把传统类型位拼回去，保证与真机 golden 一致（0o100644=33188）。
func fileTypeModeBits(m os.FileMode) uint32 {
	switch {
	case m&os.ModeDir != 0:
		return 0o040000
	case m&os.ModeSymlink != 0:
		return 0o120000
	case m&os.ModeNamedPipe != 0:
		return 0o010000
	case m&os.ModeSocket != 0:
		return 0o140000
	case m&os.ModeDevice != 0:
		if m&os.ModeCharDevice != 0 {
			return 0o020000
		}
		return 0o060000
	case m&os.ModeCharDevice != 0:
		return 0o020000
	}
	return 0o100000
}

// file_stat_dump_json 的等价回复（file.c:634-651 _rpc_file_add_stat；Odin
// file_object.odin:350-359）：type/size/mode/atime/mtime/ctime/inode。
// 偏离：省略 uid/gid/user/group（见文件头说明）。
func fileStatJSON(info os.FileInfo) map[string]any {
	m := info.Mode()
	atime, ctime, inode := fileStatMeta(info)
	return map[string]any{
		"type":  fileTypeStr(m),
		"size":  info.Size(),
		"mode":  int64(uint32(m.Perm()) | fileTypeModeBits(m)),
		"atime": atime,
		"mtime": info.ModTime().Unix(),
		"ctime": ctime,
		"inode": inode,
	}
}

// ---------------------------------------------------------------------------
// 方法
// ---------------------------------------------------------------------------

// file.c:418-497 rpc_file_read。params: path（必需）、base64?。
// 回复 {"data": "<内容或 base64>"}；空文件/读不到内容 → 5；文件 >= 256KB → 8。
func fileMethodRead(params map[string]json.RawMessage, sid string) (string, int) {
	raw, hasPath := paramStr(params, "path")
	if !hasPath {
		return "", StatusInvalidArgument
	}

	path, info, status := fileCheckPath(sid, "read", raw, true, false)
	if status != StatusOK {
		return "", status
	}
	if info.Size() >= int64(fileMaxSize) {
		return "", StatusNotSupported
	}

	data, err := os.ReadFile(path)
	if err != nil {
		return "", fileStatusOf(err)
	}
	// C 的 read() <= 0 → NO_DATA（空文件与空 sysfs 文件都走这条）
	if len(data) == 0 {
		return "", StatusNoData
	}

	text := string(data)
	if uciParamBool(params, "base64") {
		text = base64.StdEncoding.EncodeToString(data)
	}
	return marshalNoEscape(map[string]any{"data": text}), StatusOK
}

// file.c:726-746 rpc_file_stat。权限名是 **"list"**，走 stat（跟随符号链接）。
func fileMethodStat(params map[string]json.RawMessage, sid string) (string, int) {
	raw, hasPath := paramStr(params, "path")
	if !hasPath {
		return "", StatusInvalidArgument
	}

	path, info, status := fileCheckPath(sid, "list", raw, true, false)
	if status != StatusOK {
		return "", status
	}

	doc := fileStatJSON(info)
	doc["path"] = path
	return marshalNoEscape(doc), StatusOK
}

// file.c:748-768 rpc_file_lstat。权限名也是 "list"；**不解析符号链接**。
func fileMethodLstat(params map[string]json.RawMessage, sid string) (string, int) {
	raw, hasPath := paramStr(params, "path")
	if !hasPath {
		return "", StatusInvalidArgument
	}

	path, info, status := fileCheckPath(sid, "list", raw, true, true)
	if status != StatusOK {
		return "", status
	}

	doc := fileStatJSON(info)
	doc["path"] = path
	return marshalNoEscape(doc), StatusOK
}

// file.c:653-724 rpc_file_list。权限 "list"，目录本身要解析符号链接；每个条目用 lstat。
func fileMethodList(params map[string]json.RawMessage, sid string) (string, int) {
	raw, hasPath := paramStr(params, "path")
	if !hasPath {
		return "", StatusInvalidArgument
	}

	path, _, status := fileCheckPath(sid, "list", raw, false, false)
	if status != StatusOK {
		return "", status
	}

	infos, err := os.ReadDir(path)
	if err != nil {
		return "", fileStatusOf(err)
	}

	entries := make([]any, 0, len(infos))
	for _, e := range infos {
		name := e.Name()
		// 上游 readdir 后显式跳过 . / ..（os.ReadDir 本就不返回，保留判断对齐语义）
		if name == "." || name == ".." {
			continue
		}
		entryPath := path + "/" + name

		linfo, lerr := os.Lstat(entryPath)
		if lerr != nil {
			continue // 上游 lstat 失败的条目直接跳过（file.c:682）
		}

		doc := fileStatJSON(linfo)
		doc["name"] = name

		// 符号链接：嵌套 target = {name: 链接目标文本, ...目标 stat 或 type:"broken"}
		if linfo.Mode()&os.ModeSymlink != 0 {
			target := map[string]any{}
			if link, rerr := os.Readlink(entryPath); rerr == nil {
				target["name"] = link
			}
			if tinfo, terr := os.Stat(entryPath); terr == nil {
				for k, v := range fileStatJSON(tinfo) {
					target[k] = v
				}
			} else {
				target["type"] = "broken"
			}
			doc["target"] = target
		}

		entries = append(entries, doc)
	}
	return marshalNoEscape(map[string]any{"entries": entries}), StatusOK
}

// file.c:561-592 rpc_file_md5。权限 "read"；只对**普通文件**有效（其它 → 8）。
func fileMethodMd5(params map[string]json.RawMessage, sid string) (string, int) {
	raw, hasPath := paramStr(params, "path")
	if !hasPath {
		return "", StatusInvalidArgument
	}

	path, info, status := fileCheckPath(sid, "read", raw, true, false)
	if status != StatusOK {
		return "", status
	}
	if !info.Mode().IsRegular() {
		return "", StatusNotSupported
	}

	data, err := os.ReadFile(path)
	if err != nil {
		return "", fileStatusOf(err)
	}
	sum := md5.Sum(data)
	return marshalNoEscape(map[string]any{"md5": hex.EncodeToString(sum[:])}), StatusOK
}

// file.c:499-559 rpc_file_write。params: path（必需）、data（必需，缺 → 2）、append?/
// mode?/base64?。成功**不回数据**。默认 O_TRUNC；append=true → O_APPEND；mode 只在新建时生效。
func fileMethodWrite(params map[string]json.RawMessage, sid string) (string, int) {
	raw, hasPath := paramStr(params, "path")
	if !hasPath {
		return "", StatusInvalidArgument
	}
	dataRaw, hasData := params["data"]
	if !hasData {
		return "", StatusInvalidArgument
	}
	dataStr, isStr := rawStr(dataRaw)
	if !isStr {
		return "", StatusInvalidArgument
	}
	data := []byte(dataStr)

	path, _, status := fileCheckPath(sid, "write", raw, false, false)
	if status != StatusOK {
		return "", status
	}

	// 挂起的 ENOENT（父目录解析后目标不存在）：write 可以 create，照常往下走
	if uciParamBool(params, "base64") && len(data) > 0 {
		decoded, derr := base64.StdEncoding.DecodeString(string(data))
		if derr != nil {
			// 上游 b64_decode 失败 → UNKNOWN_ERROR
			return "", StatusUnknownError
		}
		data = decoded
	}

	flags := os.O_WRONLY | os.O_CREATE
	if uciParamBool(params, "append") {
		flags |= os.O_APPEND
	} else {
		flags |= os.O_TRUNC
	}

	// mode 只在创建时生效（& 0777，默认 0666）
	modeBits := uint32(0o666)
	if m, hasMode := paramInt(params, "mode"); hasMode {
		modeBits = uint32(m) & 0o777
	}

	f, oerr := os.OpenFile(path, flags, os.FileMode(modeBits))
	if oerr != nil {
		return "", fileStatusOf(oerr)
	}
	defer f.Close()

	if len(data) > 0 {
		if _, werr := f.Write(data); werr != nil {
			return "", fileStatusOf(werr)
		}
	}
	if serr := f.Sync(); serr != nil {
		return "", fileStatusOf(serr)
	}
	// 上游随后还调了全局 sync()；进程内等价物没有便携 API，省略（偏离已记文档）
	return "", StatusOK
}

// file.c:773-818 rpc_file_remove_recursive。**每个条目都要单独过 write ACL**。
func fileRemoveRecursive(sid, path string) int {
	infos, err := os.ReadDir(path)
	if err != nil {
		return fileStatusOf(err)
	}
	for _, e := range infos {
		name := e.Name()
		if name == "." || name == ".." {
			continue
		}
		entryPath := path + "/" + name
		if !fileACLOk(sid, entryPath, "write") {
			return StatusPermissionDenied
		}
		if e.IsDir() {
			if st := fileRemoveRecursive(sid, entryPath); st != StatusOK {
				return st
			}
		} else if rerr := os.Remove(entryPath); rerr != nil {
			return fileStatusOf(rerr)
		}
	}
	// POSIX 上 remove(3) 对空目录就是 rmdir
	if rerr := os.Remove(path); rerr != nil {
		return fileStatusOf(rerr)
	}
	return StatusOK
}

// file.c:820-844 rpc_file_remove。权限 "write"；**不解析符号链接**（unlink 的 no-follow）。
// 目录 → 递归删除（每个条目单独过 ACL）。
func fileMethodRemove(params map[string]json.RawMessage, sid string) (string, int) {
	raw, hasPath := paramStr(params, "path")
	if !hasPath {
		return "", StatusInvalidArgument
	}

	path, info, status := fileCheckPath(sid, "write", raw, true, true)
	if status != StatusOK {
		return "", status
	}

	if info.IsDir() {
		if st := fileRemoveRecursive(sid, path); st != StatusOK {
			return "", st
		}
		return "", StatusOK
	}
	if err := os.Remove(path); err != nil {
		return "", fileStatusOf(err)
	}
	return "", StatusOK
}

// ---------------------------------------------------------------------------
// exec（file.c:846-1203）
// ---------------------------------------------------------------------------

// file.c:846-885 rpc_file_exec_lookup：先试命令本身，再沿 PATH 找（无 PATH 用
// /bin:/usr/bin:/sbin:/usr/sbin）。找不到 → 4。
func fileExecLookup(cmd string) (string, int) {
	if info, err := os.Stat(cmd); err == nil && info.Mode().IsRegular() {
		return cmd, StatusOK
	}

	search := os.Getenv("PATH")
	if len(search) == 0 {
		search = "/bin:/usr/bin:/sbin:/usr/sbin"
	}
	for _, part := range strings.Split(search, ":") {
		cand := part + "/" + cmd
		if info, err := os.Stat(cand); err == nil && info.Mode().IsRegular() {
			return cand, StatusOK
		}
	}
	return "", StatusNotFound
}

// file.c:1055-1083 的 ACL 规则：① 可执行文件路径本身查 exec；② 没过就把**整条命令行**
// （"exe arg1 arg2…"，≤1024B、≤255 个参数）当作第二个 ACL 对象再查一次。两条都不过 → 6。
func fileExecCheckACL(sid, exe string, argv []string) int {
	if fileACLOk(sid, exe, "exec") {
		return StatusOK
	}

	argc := 1
	for i := 1; i < len(argv); i++ {
		if argc >= fileExecMaxArgs {
			return StatusPermissionDenied
		}
		argc++
	}
	cmdline := exe
	for i := 1; i < len(argv); i++ {
		cmdline += " " + argv[i]
		if len(cmdline) >= fileExecCmdlineMax {
			return StatusPermissionDenied
		}
	}
	if !fileACLOk(sid, cmdline, "exec") {
		return StatusPermissionDenied
	}
	return StatusOK
}

// fileExecSink 收集子进程输出，超过上限后只记录但不再增长（满 → 8）。
type fileExecSink struct {
	data []byte
	seen int
	over bool
}

func (s *fileExecSink) Write(p []byte) (int, error) {
	s.seen += len(p)
	if len(s.data) < fileExecOutputCap {
		room := fileExecOutputCap - len(s.data)
		if room > len(p) {
			room = len(p)
		}
		s.data = append(s.data, p[:room]...)
	}
	if s.seen > fileExecOutputCap {
		s.over = true
	}
	return len(p), nil
}

// fileExecEnv 合并 os.Environ() 与注入的 env 表（同键覆盖），对应上游子进程里的 setenv。
func fileExecEnv(obj map[string]json.RawMessage) []string {
	env := os.Environ()
	merged := make([]string, 0, len(env)+len(obj))
	index := make(map[string]int, len(env)+len(obj))
	for _, kv := range env {
		key := kv
		if i := strings.IndexByte(kv, '='); i >= 0 {
			key = kv[:i]
		}
		if _, seen := index[key]; seen {
			continue
		}
		index[key] = len(merged)
		merged = append(merged, kv)
	}
	for k, raw := range obj {
		v, isStr := rawStr(raw)
		if !isStr {
			continue
		}
		if i, seen := index[k]; seen {
			merged[i] = k + "=" + v
		} else {
			index[k] = len(merged)
			merged = append(merged, k+"="+v)
		}
	}
	return merged
}

// fileExecExitCode 把 Run 的返回变成退出码：正常退出用退出码，被信号杀给 0xff（上游
// WEXITSTATUS 在此处未定义，取一个稳定值），无法启动按 execv 失败的 127。
func fileExecExitCode(err error) int {
	if err == nil {
		return 0
	}
	var ee *exec.ExitError
	if errors.As(err, &ee) {
		if ws, ok := ee.Sys().(syscall.WaitStatus); ok {
			if ws.Exited() {
				return ws.ExitStatus()
			}
			if ws.Signaled() {
				return 0xff
			}
		}
		return 0
	}
	return 127
}

// file.c:1028-1203 rpc_file_exec_run 的**同步**版本（上游 uloop + ubus 延迟回复，对调用方
// 可观测行为一致）。不做 shell 拼接：argv 数组直接交给 os/exec（AGENTS.md §2.2）。
func fileMethodExec(params map[string]json.RawMessage, sid string) (string, int) {
	cmd, hasCmd := paramStr(params, "command")
	if !hasCmd {
		return "", StatusInvalidArgument
	}

	// file.c:1047-1048：带会话的调用不允许传 env（env 注入只留给内部路径）
	_, hasEnv := params["env"]
	if hasEnv && len(sid) > 0 {
		return "", StatusPermissionDenied
	}

	exe, st := fileExecLookup(cmd)
	if st != StatusOK {
		return "", st
	}
	exe2, ok := fileCanonicalizePath(exe)
	if !ok {
		return "", StatusUnknownError
	}
	exe = exe2

	// 参数：数组里的字符串才收（file.c:1070-1071 / :1130-1133 跳过其它类型）
	argv := []string{exe}
	if arr, hasParams := uciParamArray(params, "params"); hasParams {
		for _, v := range arr {
			if s, isStr := rawStr(v); isStr {
				argv = append(argv, s)
			}
		}
	}

	if st := fileExecCheckACL(sid, exe, argv); st != StatusOK {
		return "", st
	}

	ctx, cancel := context.WithTimeout(context.Background(), fileExecTimeout)
	defer cancel()

	outSink := &fileExecSink{}
	errSink := &fileExecSink{}
	c := exec.CommandContext(ctx, argv[0], argv[1:]...)
	c.Stdout = outSink
	c.Stderr = errSink
	if hasEnv {
		if envObj, isObj := paramObject(params, "env"); isObj {
			c.Env = fileExecEnv(envObj)
		}
	}
	runErr := c.Run()

	if outSink.over || errSink.over {
		// 输出超限 → 8（上游是 ustream 缓冲满）
		return "", StatusNotSupported
	}
	if ctx.Err() == context.DeadlineExceeded {
		// 超时：上游 SIGKILL → 7
		return "", StatusTimeout
	}

	doc := map[string]any{"code": fileExecExitCode(runErr)}
	if len(outSink.data) > 0 {
		doc["stdout"] = string(outSink.data)
	}
	if len(errSink.data) > 0 {
		doc["stderr"] = string(errSink.data)
	}
	return marshalNoEscape(doc), StatusOK
}
