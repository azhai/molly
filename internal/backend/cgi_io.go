package backend

// cgi-io —— LuCI `fs.exec_direct` / `fs.read_direct` / `ui.uploadFile` 三件套的服务端。
//
// 上游由 `/usr/libexec/cgi-io` 这个 CGI 二进制提供，uhttpd 把它挂在 `<cgi_base>/cgi-exec`、
// `cgi-download`、`cgi-upload` 上（`cgi_base` 由前端从 scriptname 推得，见 handlers/cgi.go 的
// cgiBaseFromScriptName）。molly 不 fork 那个二进制（它依赖 uhttpd 塞的一堆环境，直接 execve
// 拿不到正确输入），而是在 Go 侧原生实现同一个 HTTP 契约——这也是「替换 uhttpd」这一目标形态的
// 应有之义。
//
// **安全模型（关键）**：`/cgi-exec` 能跑的命令，与 `ubus file.exec` 能跑的**完全一致**——两者走
// 同一道 ACL 判定（fileExecCheckACL：先按可执行文件路径查 exec，再按整条命令行查 exec；桥接态下
// 这道判定转问总线上的 rpcd，与原厂 cgi-io 的 file-exec ACL 同源同判）。所以本端点**不会**比
// 既有的 `ubus file.exec` 多放行任何命令，不构成新的执行面。
//
// 刻意偏离（记 docs/interfaces.md）：原厂 cgi-io 还会额外要求会话带 `cgi-io:[exec]` 这道闸；
// rpcd 的 `session.access` 并不把 `cgi-io` 作为一个可查询 scope 暴露（实测对 root 会话也回
// access:false），无法在此忠实复刻。改为只按 `file.exec` 白名单把关——这是真正限制「能跑哪条命令」
// 的那道 ACL，且已足够：命令不在白名单里就一律拒绝。
//
// 与 `ubus file.exec` 的差别只在**回包形态**：file.exec 把输出包成 JSON 且限 64KB；cgi-io 直接
// 流式吐原始 stdout（软件包列表这类大输出靠它）。所以这里不复用 callFile，而是复用它的 ACL 原语
// （fileExecLookup / fileCanonicalizePath / fileExecCheckACL / fileCheckPath）后自行流式执行。
//
// 返回码用 ubus 状态码（与 file_object.go 同族），由 handler 映射成 HTTP：
//   StatusOK→200、StatusInvalidArgument→400、StatusPermissionDenied→403、StatusNotFound→404、
//   其余→500。out 只在 StatusOK 时被写入（流式响应体）。

import (
	"context"
	"io"
	"os"
	"os/exec"
)

// cgiioMaxArgs 与 file.exec 一致（file.c:1073）：整条命令行的参数个数上限。
const cgiioMaxArgs = 255

// cgiioTokenize 把 cgi-io 的 `command` 串还原成 argv。前端 fs.js 的 exec_direct 对每个 token
// 先 `\`→`\\`、再把空白 `\s`→`\<空白>`，然后用单个空格连接、最后整体 URL 编码（body 已由
// ParseForm 解好码）。这里做逆运算：反斜杠转义下一个字符（`\\`→`\`、`\ `→空格、`\t`→`t`），
// 未转义的空格是分隔符。空 token 丢弃。
func cgiioTokenize(commandLine string) []string {
	var (
		argv []string
		cur  []byte
		has  bool // 当前是否有一个正在累积的 token（区分「空 token」与「无 token」）
	)
	flush := func() {
		if has {
			argv = append(argv, string(cur))
			cur = cur[:0]
			has = false
		}
	}
	for i := 0; i < len(commandLine); i++ {
		switch c := commandLine[i]; c {
		case '\\':
			has = true
			if i+1 < len(commandLine) {
				i++
				cur = append(cur, commandLine[i])
			} else {
				cur = append(cur, '\\') // 结尾孤立反斜杠：按字面保留
			}
		case ' ':
			flush()
		default:
			has = true
			cur = append(cur, c)
		}
	}
	flush()
	return argv
}

// cgiioRequireSession：cgi-io 的三件套都要求一个**已认证**会话（匿名/默认会话一律拒绝）。
// 命令/路径本身能不能过，另由 file.exec / file.read ACL 判定兜底（fail-closed）。
func cgiioRequireSession(sid string) bool {
	return len(sid) > 0 && sid != SessionDefaultID
}

// CGIExec 执行 `command`（cgi-io 串），把原始 stdout（wantStderr 时并入 stderr）流式写入 out。
// commandLine 是**已 URL 解码**的串（含反斜杠转义）。
func CGIExec(sid, commandLine string, wantStderr bool, out io.Writer) int {
	if !cgiioRequireSession(sid) {
		return StatusPermissionDenied
	}

	argv := cgiioTokenize(commandLine)
	if len(argv) == 0 || len(argv) > cgiioMaxArgs+1 {
		return StatusInvalidArgument
	}

	exe, st := fileExecLookup(argv[0])
	if st != StatusOK {
		return st // 找不到可执行 → StatusNotFound
	}
	exeCanon, ok := fileCanonicalizePath(exe)
	if !ok {
		return StatusUnknownError
	}
	full := append([]string{exeCanon}, argv[1:]...)

	// 与 ubus file.exec 同一道 ACL：路径或整条命令行必须被会话的 file.exec 白名单放行。
	if st := fileExecCheckACL(sid, exeCanon, full); st != StatusOK {
		return st // 拒 → StatusPermissionDenied
	}

	ctx, cancel := context.WithTimeout(context.Background(), fileExecTimeout)
	defer cancel()

	c := exec.CommandContext(ctx, full[0], full[1:]...)
	c.Stdout = out
	if wantStderr {
		c.Stderr = out // 2>&1 语义：stderr 也并进同一输出流
	}
	if err := c.Run(); err != nil && ctx.Err() == context.DeadlineExceeded {
		return StatusTimeout
	}
	// cgi-io 语义：无论命令退出码，都把已流式写出的 stdout 当 200 回吐（软件包列表这类
	// 正是靠大输出 + 非零退出）。ACL 已放行且 fileExecLookup 找到了可执行文件，启动失败
	// 只是罕见边角——照旧把 out 里已产生的内容回给前端即可。
	return StatusOK
}

// cgiBackupExe / cgiBackupArgs 是 cgi-backup 唯一会跑的命令：`/sbin/sysupgrade -b -`。
// 无用户输入、只读（把 /etc 配置打包成 tar.gz 写 stdout，不改系统任何状态）。上游 LuCI 的
// cgi-backup 是独立 CGI、不经 file.exec；molly 把它收进 cgi-io 同一道白名单模型——这条命令
// 必须显式出现在会话的 file.exec 白名单里（tools/molly-acl.json 的 molly-expert-ui 组授予），
// 于是鉴权与 cgi-exec 完全同源，不新开泛化执行面。
var (
	cgiBackupExe  = "/sbin/sysupgrade"
	cgiBackupArgs = []string{"-b", "-"}
)

// CGIBackup 跑固定的 `/sbin/sysupgrade -b -`，把生成的归档（tar.gz）流式写入 out。
// 与 CGIExec 同一道闸：先 cgiioRequireSession，再 file.exec ACL（可执行路径或整条命令行被
// 白名单放行）——命令不在白名单里一律 StatusPermissionDenied。ACL 通过前不向 out 写任何字节，
// 好让 handler 在未发出响应头时把失败映射成 HTTP 错误码。
func CGIBackup(sid string, out io.Writer) int {
	if !cgiioRequireSession(sid) {
		return StatusPermissionDenied
	}

	exe, st := fileExecLookup(cgiBackupExe)
	if st != StatusOK {
		return st // 找不到 sysupgrade → StatusNotFound
	}
	exeCanon, ok := fileCanonicalizePath(exe)
	if !ok {
		return StatusUnknownError
	}
	full := append([]string{exeCanon}, cgiBackupArgs...)

	if st := fileExecCheckACL(sid, exeCanon, full); st != StatusOK {
		return st // 白名单没放行 → StatusPermissionDenied
	}

	ctx, cancel := context.WithTimeout(context.Background(), fileExecTimeout)
	defer cancel()

	c := exec.CommandContext(ctx, full[0], full[1:]...)
	c.Stdout = out
	if err := c.Run(); err != nil && ctx.Err() == context.DeadlineExceeded {
		return StatusTimeout
	}
	return StatusOK
}

// CGIDownload 把 path 指向的文件内容流式写入 out。权限名 "read"（与 file.read 同），含符号链接复查。
func CGIDownload(sid, path string, out io.Writer) int {
	if !cgiioRequireSession(sid) {
		return StatusPermissionDenied
	}

	resolved, _, st := fileCheckPath(sid, "read", path, true, false)
	if st != StatusOK {
		return st
	}

	f, err := os.Open(resolved)
	if err != nil {
		return fileStatusOf(err)
	}
	defer f.Close()

	if _, err := io.Copy(out, f); err != nil {
		return StatusUnknownError
	}
	return StatusOK
}

// CGIUpload 把 reader 的内容写到目标路径 filename（file.write ACL + 符号链接复查，与 file.write 同）。
// 返回 ubus 状态码；成功时 handler 回 {"name": filename}。
func CGIUpload(sid, filename string, reader io.Reader) int {
	if !cgiioRequireSession(sid) {
		return StatusPermissionDenied
	}

	resolved, _, st := fileCheckPath(sid, "write", filename, false, false)
	if st != StatusOK {
		return st
	}

	f, err := os.OpenFile(resolved, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o644)
	if err != nil {
		return fileStatusOf(err)
	}
	if _, err := io.Copy(f, reader); err != nil {
		f.Close()
		return StatusUnknownError
	}
	if err := f.Sync(); err != nil {
		f.Close()
		return StatusUnknownError
	}
	if err := f.Close(); err != nil {
		return StatusUnknownError
	}
	return StatusOK
}
