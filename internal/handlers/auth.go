package handlers

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"os"
	"os/exec"
	"strings"

	"github.com/azhai/molly/internal/backend"
)

// /auth —— 两套界面**共用**的认证面：登录、退出、改密码。
//
// 为什么收在一处：此前登录/退出散在「简洁版页面自己的 URL」（`POST /lite/`，带
// action=login|logout）和「专家版前缀」（`POST <luci-prefix>`，由 dispatcher 的主题表单
// 提供）两处，字段名与跳转行为各是一套。现在统一成三个端点，谁的表单都往这里打：
//
//	POST /auth/login     用户名 + 密码       → 302 + 会话 cookie（path=/）
//	POST /auth/logout    销毁会话 + 清 cookie → 302
//	POST /auth/password  旧密码 + 新密码      → 改 /etc/shadow → 302
//
// 三件事都落在**同一个** ubus session 对象上（专家版那条路本来就是它），所以「一处登录、
// 两套界面可用」是链路本身的结果，而不是两套鉴权凑巧一致。
//
// 响应约定：成功与失败都回 **302** —— 成功跳 `next`（缺省 `/`），失败跳
// `<next>?auth_error=<码>`。这样无 JS 的原生表单提交也有合理落点，页面用 fetch 时能从
// `res.url` 判断成败。
//
// 字段名兼容两套：LuCI 的表单发 `luci_username`/`luci_password`，自家表单发
// `username`/`password`，两组都收——把任一侧的表单切到 /auth/login 都不必改 HTML。
const (
	authPrefix = "/auth"

	// sessionCookie 是**简洁版与专家版共用**的会话 cookie 名。
	sessionCookie = "sysauth_molly"

	// anonSID 是 ubus 的匿名会话哨兵：只有 session.login / access 这类少数方法对它放行。
	anonSID = "00000000000000000000000000000000"

	// shadowFile 是口令 hash 所在处。LuCI 改密码也是写这个文件（file.write /etc/shadow），
	// 我们走同一条路，不引入第二套口令存储。
	shadowFile = "/etc/shadow"
	// shadowHashAlg 对应设备上 root 现有的 hash 前缀（$5$ = sha256-crypt），
	// 保持一致，免得同一台机器上两种算法混着。
	shadowHashAlg = "-5"
)

// AuthPaths 报告该路径是否属于 /auth 面。
func AuthPaths(path string) bool {
	return path == authPrefix || strings.HasPrefix(path, authPrefix+"/")
}

// ServeAuth 处理 /auth 下的三个端点。
//
// 一律只接 POST：登录/改密码都是带口令的表单，GET 会把口令留在地址栏、Referer 与日志里。
// /auth 下没有别的东西，路径不认识就 404。
func ServeAuth(w http.ResponseWriter, r *http.Request, path string, deps backend.Backend) {
	if !AuthPaths(path) {
		return
	}
	if path == authPrefix || path == authPrefix+"/" || r.Method != http.MethodPost {
		http.NotFound(w, r)
		return
	}
	if err := r.ParseForm(); err != nil {
		authRedirect(w, r, authErrorRedirect(r, "bad_request"))
		return
	}
	switch path {
	case authPrefix + "/login":
		authLogin(w, r, deps)
	case authPrefix + "/logout":
		authLogout(w, r, deps)
	case authPrefix + "/password":
		authPassword(w, r, deps)
	default:
		http.NotFound(w, r)
	}
}

// authLogin 校验口令、建立会话、下发**两套界面共用**的 cookie。
func authLogin(w http.ResponseWriter, r *http.Request, deps backend.Backend) {
	username := firstNonEmpty(r.PostFormValue("username"), r.PostFormValue("luci_username"))
	password := firstNonEmpty(r.PostFormValue("password"), r.PostFormValue("luci_password"))
	if username == "" || password == "" {
		authRedirect(w, r, authErrorRedirect(r, "bad_request"))
		return
	}
	params, _ := json.Marshal(map[string]string{"username": username, "password": password})
	sid := sessionLogin(deps, string(params))
	if sid == "" {
		authRedirect(w, r, authErrorRedirect(r, "bad_credentials"))
		return
	}
	ensureSessionToken(deps, sid)
	setSessionCookie(w, sid)
	authRedirect(w, r, authNext(r))
}

// ensureSessionToken 给登录会话补一个 token —— 这是「一处登录、原版 :80 LuCI 也认」的关键。
//
// 桥接态（方案 1）下 /auth/login 的会话经总线落在设备 rpcd：裸 session.login 只写 username，
// 而设备上 ucode dispatcher 判「已登录」要求会话里有一个字符串 token（它自己在 login 之后
// 额外 session.set 一个）。molly 转发登录后必须补上同样的 token，否则 :80 的原版 LuCI 会把
// 这条 rpcd 会话判为未认证（403）。内置态下 molly 自己的 login 已写 token，这里再覆盖一次无害。
func ensureSessionToken(deps backend.Backend, sid string) {
	if deps == nil || sid == "" {
		return
	}
	buf := make([]byte, 16)
	if _, err := rand.Read(buf); err != nil {
		return
	}
	token := hex.EncodeToString(buf)
	params, _ := json.Marshal(map[string]any{"values": map[string]string{"token": token}})
	deps.CallObject("session", "set", string(params), sid)
}

// authLogout 销毁当前会话并清掉共用 cookie。销毁失败也照清——留一个已经不认的 cookie
// 只会让页面反复显示登录卡。
func authLogout(w http.ResponseWriter, r *http.Request, deps backend.Backend) {
	if sid := luciSIDFromCookie(r); sid != "" && deps != nil {
		params, _ := json.Marshal(map[string]string{"ubus_rpc_session": sid})
		_ = deps.CallObject("session", "destroy", string(params), sid)
	}
	clearSessionCookie(w)
	authRedirect(w, r, authNext(r))
}

// authPassword 改口令：**先验旧口令**（拿它走一次 session login，成功才说明这串对得上
// 这个账号），再把新口令的 hash 写进 /etc/shadow。
//
// 验旧口令这步不能省：否则任何拿到会话的人都能直接改掉 root 口令。
func authPassword(w http.ResponseWriter, r *http.Request, deps backend.Backend) {
	if luciSIDFromCookie(r) == "" {
		authRedirect(w, r, authErrorRedirect(r, "no_session"))
		return
	}
	username := firstNonEmpty(r.PostFormValue("username"), r.PostFormValue("luci_username"))
	oldPassword := firstNonEmpty(r.PostFormValue("old"), r.PostFormValue("old_password"),
		r.PostFormValue("password"), r.PostFormValue("luci_password"))
	newPassword := firstNonEmpty(r.PostFormValue("new"), r.PostFormValue("new_password"))
	if username == "" || oldPassword == "" || newPassword == "" {
		authRedirect(w, r, authErrorRedirect(r, "bad_request"))
		return
	}
	if len(newPassword) < 5 {
		authRedirect(w, r, authErrorRedirect(r, "weak_password"))
		return
	}
	// 旧口令校验：登录成功即证明它对得上这个账号
	probe, _ := json.Marshal(map[string]string{"username": username, "password": oldPassword})
	if sessionLogin(deps, string(probe)) == "" {
		authRedirect(w, r, authErrorRedirect(r, "bad_credentials"))
		return
	}
	hash, herr := shadowHash(newPassword)
	if herr != nil {
		authRedirect(w, r, authErrorRedirect(r, hashErrCode(herr)))
		return
	}
	if werr := shadowSetHash(username, hash); werr != nil {
		authRedirect(w, r, authErrorRedirect(r, hashErrCode(werr)))
		return
	}
	authRedirect(w, r, authNext(r))
}

// shadowHash 生成 sha256-crypt（$5$）的 hash。
//
// 用设备上的 `openssl passwd -5 -stdin`：口令从 stdin 进，不进 argv（ps 里看不见），也不进
// 环境变量。算法与设备上现有的 $5$ 一致。
//
// 为什么不自己实现 sha256-crypt：它有一百多行位运算，写错不会报错、只会**静默产出一份
// 登不进去的 hash**——这种 bug 要在真机点一次「保存」之后才暴露。宁可依赖一个现成实现；
// openssl 不在时返回明确错误，而不是留一半功能。
func shadowHash(password string) (string, error) {
	path, err := exec.LookPath("openssl")
	if err != nil {
		return "", &authError{"no_hasher", "设备上没有 openssl passwd，无法生成口令 hash"}
	}
	cmd := exec.Command(path, "passwd", shadowHashAlg, "-stdin")
	cmd.Stdin = strings.NewReader(password + "\n")
	out, err := cmd.Output()
	if err != nil {
		return "", err
	}
	h := strings.TrimSpace(string(out))
	if !strings.HasPrefix(h, "$5$") && !strings.HasPrefix(h, "$6$") {
		return "", &authError{"hash_failed", "openssl 产出的 hash 形态不对"}
	}
	return h, nil
}

// shadowSetHash 把 /etc/shadow 里该用户那一行的第 2 个字段换成 hash。
//
// 与 LuCI 同一套做法（整行拼回去、其余行原样），只动 hash 字段。写临时文件 + rename 原子
// 替换：改口令写坏 shadow 的后果是**全设备都登不上**。
func shadowSetHash(username, hash string) error {
	data, err := os.ReadFile(shadowFile)
	if err != nil {
		return err
	}
	lines := strings.Split(string(data), "\n")
	prefix := username + ":"
	found := false
	for i, line := range lines {
		if !strings.HasPrefix(line, prefix) {
			continue
		}
		fields := strings.Split(line, ":")
		if len(fields) < 2 {
			return &authError{"malformed_shadow", "shadow 里该用户那一行字段数不对"}
		}
		fields[1] = hash
		lines[i] = strings.Join(fields, ":")
		found = true
		break
	}
	if !found {
		return &authError{"no_such_user", "shadow 里没有这个用户"}
	}
	tmp := shadowFile + ".molly.tmp"
	if werr := os.WriteFile(tmp, []byte(strings.Join(lines, "\n")), 0600); werr != nil {
		return werr
	}
	if rerr := os.Rename(tmp, shadowFile); rerr != nil {
		os.Remove(tmp)
		return rerr
	}
	return nil
}

// authError 是带机器可读码的失败原因（经 ?auth_error= 传回页面）。
type authError struct {
	code string
	msg  string
}

func (e *authError) Error() string { return e.code + ": " + e.msg }

// hashErrCode 把错误归成 URL 友好的短码（页面据此给中文提示；非 authError 归 write_failed）。
func hashErrCode(err error) string {
	if e, ok := err.(*authError); ok {
		return e.code
	}
	return "write_failed"
}

// sessionLogin 调 `session login` 并取出 sid；任何失败都回空串（调用方按登录失败处理）。
// 走 deps.CallObject 而不是自己实现鉴权：这就是专家版用的那一个对象。
func sessionLogin(deps backend.Backend, paramsJSON string) string {
	if deps == nil {
		return ""
	}
	res := deps.CallObject("session", "login", paramsJSON, anonSID)
	if res.Outcome != backend.OutcomeOk || res.Ret != 0 {
		return ""
	}
	var reply struct {
		SID string `json:"ubus_rpc_session"`
	}
	if err := json.Unmarshal([]byte(res.Reply), &reply); err != nil {
		return ""
	}
	// 只接受合法形态的 sid（32 位 hex）：它随后要进 cookie 与页面，收窄一次比到处转义省心。
	return sanitizeSID(reply.SID)
}

// setSessionCookie 下发**两套界面共用**的会话 cookie。
//
// path=/ 是关键：专家版前缀（`/admin/`）与简洁版（`/lite/`）都要能读到它，否则就是对不上号的
// 两条会话。HttpOnly 让页面脚本拿不到它（页面用的是服务端注入的 sid，不需要自己读）；
// SameSite=strict 与上游 dispatcher 一致，顺带挡掉跨站提交。
func setSessionCookie(w http.ResponseWriter, sid string) {
	http.SetCookie(w, &http.Cookie{
		Name:     sessionCookie,
		Value:    sid,
		Path:     "/",
		HttpOnly: true,
		SameSite: http.SameSiteStrictMode,
	})
}

func clearSessionCookie(w http.ResponseWriter) {
	http.SetCookie(w, &http.Cookie{
		Name:     sessionCookie,
		Value:    "",
		Path:     "/",
		HttpOnly: true,
		SameSite: http.SameSiteStrictMode,
		MaxAge:   -1,
	})
}

// sanitizeSID 只保留十六进制字符（会话 id 就是 32 位 hex）。
//
// 为什么不是「转义」而是「白名单过滤」：这个值来自客户端的 Cookie，而它要被拼进
// **HTML 里的 JavaScript 字符串**。任何引号/尖括号/反斜杠都可能变成脚本注入——
// 与其在两种上下文（HTML 与 JS）里各转义一遍，不如按已知形态收窄到「只可能是它」。
// 非法输入退化成空串，页面就显示登录卡，行为可预期。
// 按字节判即可：非 ASCII 字节必然不是 hex，直接整串丢弃。
func sanitizeSID(sid string) string {
	if sid == "" {
		return ""
	}
	buf := make([]byte, 0, 32)
	for i := 0; i < len(sid); i++ {
		c := sid[i]
		isHex := (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
		if !isHex {
			return "" // 出现非 hex 字符：整个丢弃，别做「截断到第一个非法字符」这种猜测
		}
		buf = append(buf, c)
		if len(buf) == 32 {
			break
		}
	}
	return string(buf)
}

// authNext 取跳转目标：表单可带 next=，缺省回 `/`（`/` 会再 302 到 /lite/，正好当落点）。
//
// 只接受**同源绝对路径**，挡掉 `//evil.com`、`http://…` 这类开放重定向——鉴权端点的跳转
// 参数是开放重定向的经典入口。
func authNext(r *http.Request) string {
	next := strings.TrimSpace(r.PostFormValue("next"))
	if next == "" || !strings.HasPrefix(next, "/") || strings.HasPrefix(next, "//") {
		return "/"
	}
	return next
}

func authErrorRedirect(r *http.Request, code string) string {
	next := authNext(r)
	sep := "?"
	if strings.Contains(next, "?") {
		sep = "&"
	}
	return next + sep + "auth_error=" + code
}

// authRedirect 回 302。与 Respond 一样不发 Date（net/http 默认会补，用置 nil 抑制），
// 保持与其它响应一致的头部行为。
func authRedirect(w http.ResponseWriter, r *http.Request, location string) {
	h := w.Header()
	h["Date"] = nil
	h.Set("Location", location)
	h.Set("Content-Length", "0")
	w.WriteHeader(http.StatusFound)
}

func firstNonEmpty(vals ...string) string {
	for _, v := range vals {
		if v != "" {
			return v
		}
	}
	return ""
}
