package handlers

// auth —— /auth 认证面：登录、退出、改密码（逐条对齐 internal/handlers/auth.go）。
//
// 两套界面**共用**这一处认证：此前登录/退出散在「简洁版自家 URL」与「专家版前缀表单」两处，
// 字段名与跳转各是一套。统一成三个 POST 端点后，谁的表单都往这里打：
//
//	POST /auth/login     用户名 + 密码        → 302 + 会话 cookie（Path=/）
//	POST /auth/logout    销毁会话 + 清 cookie  → 302
//	POST /auth/password  旧密码 + 新密码        → 改 /etc/shadow → 302
//
// 三件事都落在**同一个** ubus session 对象上（走 backend 接缝 Call_Object），于是「一处登录、
// 两套界面可用」是链路本身的结果，而非两套鉴权凑巧一致。
//
// 响应约定：成功与失败都回 **302** —— 成功跳 `next`（缺省 `/`），失败跳 `<next>?auth_error=<码>`。
// 这样无 JS 的原生表单也有合理落点，fetch 时能从 res.url 判成败。字段名兼容两套：LuCI 表单发
// luci_username/luci_password，自家表单发 username/password，两组都收。
//
// 与静态/ubus handler 同构：把「决策」（sanitize/取 next/错误跳转/cookie 串）抽成纯函数，host 能测；
// Serve_Auth 与其下的三个端点只做「读表单 + 调 backend + 发 302」的 I/O 粘合。改密码用到的
// openssl 口令 hash 与 /etc/shadow 写回是设备专属，按平台拆到 auth_linux.odin / auth_darwin.odin。

import "core:strings"
import "core:os"
import "core:encoding/json"
import "molly:http"
import "molly:backend"

// ---- 路径与常量（对齐 auth.go:34-49）----
AUTH_Prefix        :: "/auth"
auth_login_path    :: "/auth/login"
auth_logout_path   :: "/auth/logout"
auth_password_path :: "/auth/password"

// session_cookie_name 是**简洁版与专家版共用**的会话 cookie 名。
session_cookie_name :: "sysauth_molly"

// anon_sid 是 ubus 的匿名会话哨兵：只有 session.login 这类少数方法对它放行。
anon_sid :: "00000000000000000000000000000000"

// ---------------------------------------------------------------------------
// I/O 薄层：路由 + 三个端点
// ---------------------------------------------------------------------------

// Auth_Paths —— 该路径是否属于 /auth 面（router 据此决定是否交给 Serve_Auth）。
Auth_Paths :: proc(path: string) -> bool {
	return path == AUTH_Prefix || strings.has_prefix(path, AUTH_Prefix+"/")
}

// Serve_Auth —— /auth 入口。一律只接 POST（GET 会把口令留在 URL/Referer/日志里）；
// 裸 /auth、非 POST、未知子路径都 404。
Serve_Auth :: proc(res: ^http.Response, req: ^http.Request, path: string) {
	if path == AUTH_Prefix || path == AUTH_Prefix+"/" || req.method != "POST" {
		http.Not_Found(res, path)
		return
	}
	form := http.Parse_Form(req)
	switch path {
	case auth_login_path:
		auth_login(res, req, form)
	case auth_logout_path:
		auth_logout(res, req, form)
	case auth_password_path:
		auth_password(res, req, form)
	case:
		http.Not_Found(res, path)
	}
}

// auth_login —— 校验口令、建会话、下发两套界面共用的 cookie。
auth_login :: proc(res: ^http.Response, req: ^http.Request, form: []http.KV) {
	username := first_non_empty([]string{form_value(form, "username"), form_value(form, "luci_username")})
	password := first_non_empty([]string{form_value(form, "password"), form_value(form, "luci_password")})
	if username == "" || password == "" {
		auth_redirect(res, auth_error_redirect(form, "bad_request"), "")
		return
	}
	sid := session_login(login_params(username, password))
	if sid == "" {
		auth_redirect(res, auth_error_redirect(form, "bad_credentials"), "")
		return
	}
	ensure_session_token(sid)
	auth_redirect(res, auth_next(form), build_session_cookie(sid, false))
}

// auth_logout —— 销毁当前会话并清掉共用 cookie。销毁失败也照清：留一个已经不认的 cookie
// 只会让页面反复显示登录卡。
auth_logout :: proc(res: ^http.Response, req: ^http.Request, form: []http.KV) {
	sid := sid_from_cookie(req)
	if sid != "" {
		_ = backend.Call_Object("session", "destroy", "", sid, context.allocator)
	}
	auth_redirect(res, auth_next(form), build_session_cookie("", true))
}

// auth_password —— 改口令：**先验旧口令**（拿它走一次 session.login，成功才说明这串对得上这个
// 账号），再把新口令的 hash 写进 /etc/shadow。验旧口令不能省：否则任何拿到会话的人都能直接改 root 口令。
auth_password :: proc(res: ^http.Response, req: ^http.Request, form: []http.KV) {
	if sid_from_cookie(req) == "" {
		auth_redirect(res, auth_error_redirect(form, "no_session"), "")
		return
	}
	username := first_non_empty([]string{form_value(form, "username"), form_value(form, "luci_username")})
	old_password := first_non_empty([]string{
		form_value(form, "old"), form_value(form, "old_password"),
		form_value(form, "password"), form_value(form, "luci_password")})
	new_password := first_non_empty([]string{form_value(form, "new"), form_value(form, "new_password")})
	if username == "" || old_password == "" || new_password == "" {
		auth_redirect(res, auth_error_redirect(form, "bad_request"), "")
		return
	}
	if len(new_password) < 5 {
		auth_redirect(res, auth_error_redirect(form, "weak_password"), "")
		return
	}
	// 旧口令校验：登录成功即证明它对得上这个账号。
	if session_login(login_params(username, old_password)) == "" {
		auth_redirect(res, auth_error_redirect(form, "bad_credentials"), "")
		return
	}
	hash, code := shadow_hash(new_password)
	if code != "" {
		auth_redirect(res, auth_error_redirect(form, code), "")
		return
	}
	if wcode := shadow_set_hash(username, hash); wcode != "" {
		auth_redirect(res, auth_error_redirect(form, wcode), "")
		return
	}
	auth_redirect(res, auth_next(form), "")
}

// ---------------------------------------------------------------------------
// 会话与 cookie
// ---------------------------------------------------------------------------

// session_login —— 走 backend 接缝调 session.login 并取出 sid；任何失败回空串（调用方按登录失败处理）。
// 自己不实现鉴权：这就是专家版用的那一个对象。
session_login :: proc(params_json: string) -> string {
	res := backend.Call_Object("session", "login", params_json, anon_sid, context.allocator)
	if res.outcome != .Ok || res.ret != 0 {
		return ""
	}
	v, err := json.parse_string(res.reply, .JSON, true, context.allocator)
	if err != nil {
		return ""
	}
	o, is_obj := v.(json.Object)
	if ! is_obj {
		return ""
	}
	sv, has := o["ubus_rpc_session"]
	if ! has {
		return ""
	}
	s, is_str := sv.(json.String)
	if ! is_str {
		return ""
	}
	// 只接受合法形态的 sid（32 位 hex）：它随后要进 cookie 与页面，先收窄一次比到处转义省心。
	return sanitize_sid(string(s))
}

// login_params —— {"username":…,"password":…}，走 json 序列化保证引号等被正确转义（口令是自由文本）。
login_params :: proc(username, password: string) -> string {
	obj := make(json.Object)
	obj["username"] = json.String(username)
	obj["password"] = json.String(password)
	return json_unparse(json.Value(obj))
}

// ensure_session_token —— 给登录会话补一个 token：这是「一处登录、原版 :80 LuCI 也认」的关键。
// 桥接态下裸 session.login 只写 username，而设备 ucode dispatcher 判「已登录」要求会话里有一个字符串
// token；补上后 :80 原版 LuCI 才不把这 rpcd 会话判为未认证。内置态下自家 login 已写 token，覆盖一次无害。
ensure_session_token :: proc(sid: string) {
	if sid == "" {
		return
	}
	tok, ok := random_hex(32) // 16 字节 → 32 位十六进制，与 Go 的 rand.Read(16)+hex 同形
	if ! ok {
		return
	}
	inner := make(json.Object)
	inner["token"] = json.String(tok)
	obj := make(json.Object)
	obj["values"] = json.Value(inner)
	_ = backend.Call_Object("session", "set", json_unparse(json.Value(obj)), sid, context.allocator)
}

// build_session_cookie —— 下发/清除两套界面共用的会话 cookie 串。
// Path=/ 是关键（专家版与简洁版都要读得到）；HttpOnly 让脚本拿不到（页面用服务端注入的 sid）；
// SameSite=Strict 与上游一致，顺带挡跨站提交。clear=true 时清空值并加 Max-Age=-1。
// sid 已在 session_login 里收窄成 32 位 hex，无 CRLF / ';' 注入风险。
build_session_cookie :: proc(sid: string, clear: bool) -> string {
	if clear {
		return "sysauth_molly=; Path=/; HttpOnly; SameSite=Strict; Max-Age=-1"
	}
	return build([]string{session_cookie_name, "=", sid, "; Path=/; HttpOnly; SameSite=Strict"})
}

// sid_from_cookie —— 从 Cookie 头取会话 id（对齐 luci.go 的 luciSIDFromCookie）：先认 molly 专属名，
// 再认上游 LuCI 的两个名，于是两套界面共用一条会话。返回原值（不 sanitize：交给对象按 sid 自己判）。
sid_from_cookie :: proc(req: ^http.Request) -> string {
	h, ok := http.Header_Get(req, "cookie")
	if ! ok || len(h) == 0 {
		return ""
	}
	parts, _ := strings.split(h, ";")
	defer delete(parts)
	names := []string{session_cookie_name, "sysauth_https", "sysauth_http"}
	for name in names {
		for p in parts {
			part := strings.trim_space(p)
			eq := byte_index(part, '=')
			if eq <= 0 {
				continue
			}
			if strings.to_lower(strings.trim_space(part[0:eq])) == name {
				return strings.trim_space(part[eq+1:])
			}
		}
	}
	return ""
}

// ---------------------------------------------------------------------------
// 跳转决策（纯函数，host 可测）
// ---------------------------------------------------------------------------

// auth_redirect —— 302 + Location（+ 可选 Set-Cookie）。Content-Length 恒 0（空正文，Emit 自动算）；
// 不发 Date（与 Respond 一致，http 层本就从不发 Date）。
auth_redirect :: proc(res: ^http.Response, location, set_cookie: string) {
	hdrs: [dynamic]http.Header
	defer delete(hdrs)
	append(&hdrs, http.Header{"Location", location})
	if set_cookie != "" {
		append(&hdrs, http.Header{"Set-Cookie", set_cookie})
	}
	http.Emit(res, 302, hdrs[:], "")
}

// auth_next —— 取跳转目标：表单可带 next=，缺省回 `/`（`/` 再 302 到 /lite/，正好当落点）。
// 只接受**同源绝对路径**，挡掉 `//evil.com`、`http://…` 这类开放重定向——鉴权端点的跳转参数是经典入口。
auth_next :: proc(form: []http.KV) -> string {
	next := strings.trim_space(form_value(form, "next"))
	if next == "" || ! strings.has_prefix(next, "/") || strings.has_prefix(next, "//") {
		return "/"
	}
	return next
}

// auth_error_redirect —— 失败跳转：next 已含 '?' 则用 '&' 追加，否则 '?'，键固定 auth_error=<码>。
auth_error_redirect :: proc(form: []http.KV, code: string) -> string {
	next := auth_next(form)
	sep := "?"
	if strings.contains(next, "?") {
		sep = "&"
	}
	return build([]string{next, sep, "auth_error=", code})
}

// ---------------------------------------------------------------------------
// 表单与小工具
// ---------------------------------------------------------------------------

// form_value —— 取表单里某键的首个值（对齐 r.PostFormValue，只看正文、不看 query）。
form_value :: proc(form: []http.KV, key: string) -> string {
	v, ok := http.KV_Get(form, key)
	if ! ok {
		return ""
	}
	return v
}

// first_non_empty —— 返回第一个非空串（兼容 username/luci_username 两套字段名）。
first_non_empty :: proc(vals: []string) -> string {
	for v in vals {
		if v != "" {
			return v
		}
	}
	return ""
}

// sanitize_sid —— 只保留十六进制字符（会话 id 就是 32 位 hex）。是「白名单过滤」而非「转义」：
// 这个值来自客户端 Cookie，要拼进 HTML 里的 JS 字符串，任何引号/尖括号/反斜杠都可能变成脚本注入。
// 遇非 hex 字符**整串丢弃**（不做「截断到第一个非法字符」这种猜测），非法输入退化成空串 → 页面显示登录卡。
sanitize_sid :: proc(sid: string) -> string {
	if sid == "" {
		return ""
	}
	b: [dynamic]u8
	defer delete(b)
	for i := 0; i < len(sid); i += 1 {
		c := sid[i]
		if ! is_hex_byte(c) {
			return ""
		}
		append(&b, c)
		if len(b) == 32 {
			break
		}
	}
	return finalize_string(&b)
}

is_hex_byte :: proc(c: u8) -> bool {
	return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
}

// byte_index —— 字符串里首个字节 b 的下标；没有则 -1。
byte_index :: proc(s: string, b: u8) -> int {
	for i := 0; i < len(s); i += 1 {
		if s[i] == b {
			return i
		}
	}
	return -1
}

// random_hex —— 取 n 个十六进制字符（读 /dev/urandom，跨 darwin/linux 一致）。与 backend.session
// 的 sid 生成同源；刻意不复用那个私有函数，免得把「token 生成」塞进 backend↔handler 的窄接缝。
random_hex :: proc(n: int) -> (string, bool) {
	nbytes := (n + 1) / 2
	buf := make([]u8, nbytes)
	f, err := os.open("/dev/urandom")
	if err != nil {
		delete(buf)
		return "", false
	}
	defer os.close(f)
	got, rerr := os.read(f, buf)
	if rerr != nil || got < nbytes {
		delete(buf)
		return "", false
	}
	digits := "0123456789abcdef"
	out := make([]u8, n)
	for i := 0; i < n; i += 1 {
		bs := buf[i/2]
		if i%2 == 0 {
			out[i] = digits[int(bs >> 4)]
		} else {
			out[i] = digits[int(bs & 0x0f)]
		}
	}
	delete(buf)
	return string(out), true
}
