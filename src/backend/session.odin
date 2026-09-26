package backend

import "base:runtime"
import "core:encoding/json"
import "core:mem"
import "core:strings"
import "core:os"
import "core:sync"
import "core:time"

// ---------------------------------------------------------------------------
// session 对象（P3-2）
//
// 依据：rpcd 提交 e37ed9d8（ImmortalWrt 25.12.2 的 base feed 钉点）的 `session.c`。
// 行号写在每处实现旁，改语义前先回去看那一行。
//
// 十个方法（session.c:1355-1366 的方法表）：create / list / grant / revoke /
// access / set / get / unset / destroy / login。
//
// 回复形状（session.c:224-244 rpc_session_to_blob）：
//   { "ubus_rpc_session": <32 hex>, "timeout": <int32 秒>, "expires": <int64 秒>,
//     "acls": { <scope>: { <object>: [<function>…] } },   // 只有 dump(acls=true) 才有
//     "data": { <key>: <任意 JSON> } }
//
// 本文件是**平台无关**的逻辑；两个平台特有的东西由 provider 提供同名 proc：
//   session_verify_password(hash, password, alloc) -> bool   （linux: shadow+crypt；darwin: 测试替身）
// ACL 的来源（acl.d/*.json）与 uhttpd 侧的前置校验属 P3-6：本轮 login 只建立会话与
// data.username，acls 只有 grant/revoke 与后续 P3-6 填。
// ---------------------------------------------------------------------------

// session.h:27-31 的常量
SESSION_SID_LEN :: 32
SESSION_DEFAULT_TIMEOUT :: 300
SESSION_DEFAULT_ID :: "00000000000000000000000000000000"
SESSION_DIRECTORY :: "/var/run/rpcd/sessions"
SESSION_ACL_DIR :: "/usr/share/rpcd/acl.d"

// libubus 的状态码（取值与 backend.ubus_error_message 的表一致）
SESSION_STATUS_OK :: 0
SESSION_STATUS_INVALID_ARGUMENT :: 2
SESSION_STATUS_METHOD_NOT_FOUND :: 3
SESSION_STATUS_NOT_FOUND :: 4
SESSION_STATUS_PERMISSION_DENIED :: 6
SESSION_STATUS_UNKNOWN_ERROR :: 9

// session.c:432-480 的 ACL 条目：一个 scope 下一组 (object, function)。
// sort_len = 前缀长度（到第一个通配符为止，session.c:426-429 uh_id_len），
// 匹配时用于快速剪枝（session.c:137-147 的 uh_foreach_matching_acl）。
Acl_Entry :: struct {
	object:   string,
	function: string,
	sort_len: int,
}

Session :: struct {
	id:         string,
	timeout:    int, // 秒；<= 0 表示不过期（session.c:278-283 只在 > 0 时 touch）
	expires_at: time.Time,
	data:       map[string]string, // key → 该值的 JSON 文本（保类型）
	acls:       map[string][dynamic]Acl_Entry, // scope → entries
}

@(private)
g_sessions: map[string]^Session

// 会话数据（store / id / data / acls）的生命周期必须长于请求：darwin 下调用方传进来的是
// **每请求 arena**，linux 下是 ubus 线程的上下文分配器。所以这几样一律用默认堆分配器，
// 与上游的 calloc/free 对应；只有回复 JSON 用调用方给的 alloc。
@(private)
session_store_allocator :: proc() -> mem.Allocator {
	return runtime.default_context().allocator
}

// ubus 服务线程是单线程的，但 darwin 下 `/ubus` 由多个连接线程调用 session_call，
// 所以 store 必须加锁（linux 上多一层无竞争的锁，代价可忽略）。
@(private)
g_session_lock: sync.Mutex

// ---------------------------------------------------------------------------
// 入口：一个方法调用（params 是 JSON 文本，reply 也是 JSON 文本）
//   reply == "" 表示上游「不回数据」（set / unset / destroy 三种）
//   status != 0 时 reply 无效，调用方按 ubus 状态码回错误
// ---------------------------------------------------------------------------
session_call :: proc(method: string, params_json: string, alloc: mem.Allocator) -> (reply: string, status: int) {
	params := make(json.Object, 0, alloc)
	if len(params_json) > 0 {
		doc: json.Value
		if err := json.unmarshal(transmute([]byte)(params_json), &doc, .JSON, alloc); err == nil {
			if obj, is_obj := doc.(json.Object); is_obj {
				params = obj
			}
		}
	}

	sync.lock(&g_session_lock)
	defer sync.unlock(&g_session_lock)

	session_ensure_default()
	prune_expired()

	switch method {
	case "create":
		return session_do_create(params, alloc)
	case "list":
		return session_do_list(params, alloc)
	case "get":
		return session_do_get(params, alloc)
	case "set":
		return session_do_set(params, alloc)
	case "unset":
		return session_do_unset(params, alloc)
	case "destroy":
		return session_do_destroy(params, alloc)
	case "access":
		return session_do_access(params, alloc)
	case "login":
		return session_do_login(params, alloc)
	case "grant", "revoke":
		return session_do_grant_revoke(method, params, alloc)
	}
	return "", SESSION_STATUS_METHOD_NOT_FOUND
}

// ---------------------------------------------------------------------------
// create / list / destroy（session.c:380-423、794-816）
// ---------------------------------------------------------------------------

@(private)
session_do_create :: proc(params: json.Object, alloc: mem.Allocator) -> (string, int) {
	timeout := SESSION_DEFAULT_TIMEOUT
	if v, ok := param_int(params, "timeout"); ok {
		timeout = int(v)
	}
	ses := session_new(timeout)
	if ses == nil {
		return "", SESSION_STATUS_UNKNOWN_ERROR
	}
	return session_dump(ses, true, alloc), SESSION_STATUS_OK
}

// list：给 sid 回该会话；不给 sid 时上游对每个会话各回一条（session.c:410-414）。
// HTTP/JSON-RPC 信封只能装一条结果，这里回**数组**——molly 的偏离，真机 golden 时要核对。
@(private)
session_do_list :: proc(params: json.Object, alloc: mem.Allocator) -> (string, int) {
	if sid, ok := param_str(params, "ubus_rpc_session"); ok {
		ses := session_get(sid)
		if ses == nil {
			return "", SESSION_STATUS_NOT_FOUND
		}
		return session_dump(ses, true, alloc), SESSION_STATUS_OK
	}

	arr := make([dynamic]json.Value, 0, len(g_sessions), alloc)
	for _, ses in g_sessions {
		dump := session_dump(ses, true, alloc)
		doc: json.Value
		if err := json.unmarshal(transmute([]byte)(dump), &doc, .JSON, alloc); err == nil {
			append(&arr, doc)
		}
	}
	return session_marshal(json.Value(json.Array(arr)), alloc), SESSION_STATUS_OK
}

@(private)
session_do_destroy :: proc(params: json.Object, alloc: mem.Allocator) -> (string, int) {
	sid, ok := param_str(params, "ubus_rpc_session")
	if !ok {
		return "", SESSION_STATUS_INVALID_ARGUMENT
	}
	// 默认会话不可销毁（session.c:806-807）
	if sid == SESSION_DEFAULT_ID {
		return "", SESSION_STATUS_PERMISSION_DENIED
	}
	ses := session_get(sid)
	if ses == nil {
		return "", SESSION_STATUS_NOT_FOUND
	}
	session_destroy(ses)
	return "", SESSION_STATUS_OK
}

// ---------------------------------------------------------------------------
// get / set / unset（session.c:657-791）
// ---------------------------------------------------------------------------

@(private)
session_do_get :: proc(params: json.Object, alloc: mem.Allocator) -> (string, int) {
	sid, ok := param_str(params, "ubus_rpc_session")
	if !ok {
		return "", SESSION_STATUS_INVALID_ARGUMENT
	}
	ses := session_get(sid)
	if ses == nil {
		return "", SESSION_STATUS_NOT_FOUND
	}

	values := json.Object{}
	if keys, has_keys := params["keys"]; has_keys {
		// 只挑 keys 里出现的、且值类型是字符串的键（session.c:729-742）
		if arr, is_arr := keys.(json.Array); is_arr {
			for el in arr {
				key, is_str := el.(json.String)
				if !is_str {
					continue
				}
				if text, found := ses.data[string(key)]; found {
					values[string(key)] = parse_json_value(text, alloc)
				}
			}
		}
	} else {
		for key, text in ses.data {
			values[key] = parse_json_value(text, alloc)
		}
	}

	doc := make(json.Object, 0, alloc)
	doc["values"] = values
	return session_marshal(json.Value(doc), alloc), SESSION_STATUS_OK
}

@(private)
session_do_set :: proc(params: json.Object, alloc: mem.Allocator) -> (string, int) {
	sid, ok := param_str(params, "ubus_rpc_session")
	if !ok {
		return "", SESSION_STATUS_INVALID_ARGUMENT
	}
	values, has_values := param_obj(params, "values")
	if !has_values {
		return "", SESSION_STATUS_INVALID_ARGUMENT
	}
	ses := session_get(sid)
	if ses == nil {
		return "", SESSION_STATUS_NOT_FOUND
	}
	store := session_store_allocator()
	for key, val in values {
		if len(key) == 0 {
			continue // 匿名条目跳过（session.c:696-697）
		}
		// 键与值都要进 store：入参的 string 指向请求 arena，请求一结束就是悬垂指针
		text := session_marshal(val, store)
		ses.data[strings.clone(key, store)] = text
	}
	return "", SESSION_STATUS_OK
}

@(private)
session_do_unset :: proc(params: json.Object, alloc: mem.Allocator) -> (string, int) {
	sid, ok := param_str(params, "ubus_rpc_session")
	if !ok {
		return "", SESSION_STATUS_INVALID_ARGUMENT
	}
	ses := session_get(sid)
	if ses == nil {
		return "", SESSION_STATUS_NOT_FOUND
	}
	keys, has_keys := params["keys"]
	if !has_keys {
		clear(&ses.data) // 不给 keys → 清空（session.c:772-776）
		return "", SESSION_STATUS_OK
	}
	if arr, is_arr := keys.(json.Array); is_arr {
		for el in arr {
			if key, is_str := el.(json.String); is_str {
				delete_key(&ses.data, string(key))
			}
		}
	}
	return "", SESSION_STATUS_OK
}

// ---------------------------------------------------------------------------
// access（session.c:598-654）
// ---------------------------------------------------------------------------

@(private)
session_do_access :: proc(params: json.Object, alloc: mem.Allocator) -> (string, int) {
	sid, ok := param_str(params, "ubus_rpc_session")
	if !ok {
		return "", SESSION_STATUS_INVALID_ARGUMENT
	}
	ses := session_get(sid)
	if ses == nil {
		return "", SESSION_STATUS_NOT_FOUND
	}

	object, has_obj := param_str(params, "object")
	function, has_fun := param_str(params, "function")
	if has_obj && has_fun {
		scope := "ubus"
		if s, has_scope := param_str(params, "scope"); has_scope {
			scope = s
		}
		allowed := session_acl_allowed(ses, scope, object, function)
		doc := make(json.Object, 0, alloc)
		doc["access"] = json.Boolean(allowed)
		return session_marshal(json.Value(doc), alloc), SESSION_STATUS_OK
	}

	// 不给 object/function → 回整个 ACL 表（session.c:646-649）
	return session_dump_acls_json(ses, alloc), SESSION_STATUS_OK
}

// ---------------------------------------------------------------------------
// grant / revoke（session.c:432-595）
//   params: { ubus_rpc_session, scope?（默认 "ubus"）, objects?: [[object, function], …] }
//   objects 缺失：revoke 清空整个 scope；grant 是 INVALID_ARGUMENT
// ---------------------------------------------------------------------------

@(private)
session_do_grant_revoke :: proc(method: string, params: json.Object, alloc: mem.Allocator) -> (string, int) {
	sid, ok := param_str(params, "ubus_rpc_session")
	if !ok {
		return "", SESSION_STATUS_INVALID_ARGUMENT
	}
	ses := session_get(sid)
	if ses == nil {
		return "", SESSION_STATUS_NOT_FOUND
	}
	scope := "ubus"
	if s, has_scope := param_str(params, "scope"); has_scope {
		scope = s
	}

	objects, has_objects := params["objects"]
	if !has_objects {
		if method == "grant" {
			return "", SESSION_STATUS_INVALID_ARGUMENT
		}
		session_acl_clear_scope(ses, scope)
		return "", SESSION_STATUS_OK
	}

	if arr, is_arr := objects.(json.Array); is_arr {
		for entry in arr {
			inner, is_inner := entry.(json.Array)
			if !is_inner {
				continue
			}
			object, function := "", ""
			taken := 0
			for el in inner {
				if s, is_str := el.(json.String); is_str {
					if taken == 0 {
						object = string(s)
					} else if taken == 1 {
						function = string(s)
					}
					taken += 1
				}
			}
			if len(object) == 0 || len(function) == 0 {
				continue
			}
			if method == "grant" {
				session_acl_grant(ses, scope, object, function, alloc)
			} else {
				session_acl_revoke(ses, scope, object, function)
			}
		}
	}
	return "", SESSION_STATUS_OK
}

// ---------------------------------------------------------------------------
// login（session.c:819-1214）
//
// 上游流程：读 /etc/config/rpcd 的 `config login` section 找匹配 username 的那条，
// 用 `rpc_login_test_password` 校验 password（`$p$user` = 引用 shadow/passwd 的条目，
// 否则 crypt 比对），失败回 PERMISSION_DENIED。会话建立后 set data.username，
// 并按 login section 的 read/write 组加载 acl.d（**那部分属 P3-6**）。
//
// 本轮实现到「校验 + 建会话 + data.username」；acl.d 加载与权限组留到 P3-6，
// 所以登录成功但 acls 为空——P3-6 之前不要用登录态去跑需要 ACL 的调用。
// ---------------------------------------------------------------------------

@(private)
session_do_login :: proc(params: json.Object, alloc: mem.Allocator) -> (string, int) {
	username, has_user := param_str(params, "username")
	password, has_pass := param_str(params, "password")
	if !has_user || !has_pass {
		return "", SESSION_STATUS_INVALID_ARGUMENT
	}

	if !session_login_check(username, password, alloc) {
		return "", SESSION_STATUS_PERMISSION_DENIED
	}

	timeout := SESSION_DEFAULT_TIMEOUT
	if v, ok := param_int(params, "timeout"); ok {
		timeout = int(v)
	}

	ses := session_new(timeout)
	if ses == nil {
		return "", SESSION_STATUS_UNKNOWN_ERROR
	}
	ses.data["username"] = session_marshal(json.Value(json.String(username)), session_store_allocator())
	return session_dump(ses, true, alloc), SESSION_STATUS_OK
}

// /etc/config/rpcd 的 login section 校验（session.c:855-924）。
// 没有匹配的 login section → 拒绝（这正是「默认配置里 root/$p$root」能用的原因）。
@(private)
session_login_check :: proc(username, password: string, alloc: mem.Allocator) -> bool {
	sections, ok := uci_config_sections("rpcd", alloc)
	if !ok {
		return false
	}
	for s in sections {
		if s.type_name != "login" {
			continue
		}
		name, has_name := section_option_string(s, "username")
		if !has_name || name != username {
			continue
		}
		hash, has_hash := section_option_string(s, "password")
		if !has_hash {
			continue // 没有 password 选项 → 这一条不匹配（session.c:910-915）
		}
		if session_verify_password(hash, password, alloc) {
			return true
		}
	}
	return false
}

// ---------------------------------------------------------------------------
// 会话存储
// ---------------------------------------------------------------------------

@(private)
session_new :: proc(timeout: int) -> ^Session {
	alloc := session_store_allocator()
	id, ok := session_random_sid(alloc)
	if !ok {
		return nil
	}
	ses := new(Session, alloc)
	ses.id = id
	ses.timeout = timeout
	ses.data = make(map[string]string, 0, alloc)
	ses.acls = make(map[string][dynamic]Acl_Entry, 0, alloc)
	session_touch(ses)
	if g_sessions == nil {
		g_sessions = make(map[string]^Session, 0, alloc)
	}
	g_sessions[ses.id] = ses
	return ses
}

// 取会话并续期（session.c:367-378：get 会 touch 计时器）。
@(private)
session_get :: proc(id: string) -> ^Session {
	ses, found := g_sessions[id]
	if !found {
		return nil
	}
	if session_expired(ses) {
		session_destroy(ses)
		return nil
	}
	session_touch(ses)
	return ses
}

@(private)
session_destroy :: proc(ses: ^Session) {
	// uci.c:1739-1746 的 rpc_uci_purge_savedir_cb：会话销毁时清掉它的 delta 目录
	// （/var/run/rpcd/uci-<sid>）。darwin 上那个目录不存在，purge 是空转。
	uci_purge_savedir(ses.id, session_store_allocator())
	delete_key(&g_sessions, ses.id)
}

// 惰性过期：上游用 uloop_timeout 到点销毁（session.c:313-319）。这里在每次查找/枚举时
// 判断，可观测行为一致（过期会话查不到），内存回收推迟到下一次访问。
// ponytail: 不引入 uloop 定时器；如需精确的内存曲线与「到点即销毁」，P3-9 收尾时再评估。
@(private)
session_expired :: proc(ses: ^Session) -> bool {
	if ses.timeout <= 0 {
		return false
	}
	return time.now()._nsec >= ses.expires_at._nsec
}

@(private)
prune_expired :: proc() {
	// 先收集再删：Odin 的 map 不允许在遍历过程中删除
	dead := make([dynamic]string, context.temp_allocator)
	for id, ses in g_sessions {
		if session_expired(ses) {
			append(&dead, id)
		}
	}
	for id in dead {
		// 过期也走同一条清理（上游的 purge 回调挂在会话销毁上，过期销毁同样会触发）
		uci_purge_savedir(id, session_store_allocator())
		delete_key(&g_sessions, id)
	}
}

@(private)
session_touch :: proc(ses: ^Session) {
	if ses.timeout > 0 {
		ses.expires_at = time.time_add(time.now(), time.Duration(ses.timeout) * time.Second)
	}
}

// session.c:150-176 的 rpc_random：从 /dev/urandom 取 RPC_SID_LEN/2 字节，转小写十六进制。
// 两个平台都有 /dev/urandom，所以这段是共享代码，不需要 provider。
@(private)
session_random_sid :: proc(alloc: mem.Allocator) -> (string, bool) {
	raw := make([]byte, SESSION_SID_LEN / 2, alloc)
	defer delete(raw, alloc) // 必须用同一个 allocator：delete 默认用 context.allocator，
	// 测试里那是跟踪分配器 → 报 bad free（真机上掩盖成「看起来正常」）
	if !urandom_read(raw) {
		return "", false
	}

	out := make([]byte, SESSION_SID_LEN, alloc)
	hex := "0123456789abcdef"
	for b, i in raw {
		out[i * 2] = hex[b >> 4]
		out[i * 2 + 1] = hex[b & 0x0f]
	}
	// transmute 不复制：sid 的生命周期跟随 alloc（与 uri.odin 的写法一致）
	return transmute(string)(out), true
}

// ---------------------------------------------------------------------------
// ACL 匹配（session.c:131-147、432-533、598-612）
// ---------------------------------------------------------------------------

// scope 命中 + 前缀剪枝 + fnmatch(object) + fnmatch(function)。
@(private)
session_acl_allowed :: proc(ses: ^Session, scope, object, function: string) -> bool {
	entries, found := ses.acls[scope]
	if !found {
		return false
	}
	for e in entries {
		if !prefix_match(e.object, object, e.sort_len) {
			continue
		}
		if fnmatch(e.object, object) && fnmatch(e.function, function) {
			return true
		}
	}
	return false
}

@(private)
session_acl_grant :: proc(ses: ^Session, scope, object, function: string, alloc: mem.Allocator) {
	// 入参的 string 指向请求 arena，必须克隆进 store，否则请求结束就是悬垂指针
	_ = alloc
	store := session_store_allocator()
	scope_key := scope
	entries, found := ses.acls[scope_key]
	if !found {
		scope_key = strings.clone(scope, store)
		entries = make([dynamic]Acl_Entry, 0, 4, store)
	}
	for e in entries {
		if e.object == object && e.function == function {
			ses.acls[scope_key] = entries // 已存在，不动（session.c:446-450）
			return
		}
	}
	append(&entries, Acl_Entry {
		object   = strings.clone(object, store),
		function = strings.clone(function, store),
		sort_len = acl_id_len(object),
	})
	ses.acls[scope_key] = entries
}

@(private)
session_acl_revoke :: proc(ses: ^Session, scope, object, function: string) {
	entries, found := ses.acls[scope]
	if !found {
		return
	}
	// 原地压缩（不新增分配）：把保留下来的条目往前挪
	w := 0
	for i in 0 ..< len(entries) {
		if entries[i].object == object && entries[i].function == function {
			continue
		}
		entries[w] = entries[i]
		w += 1
	}
	resize(&entries, w)
	if w == 0 {
		delete_key(&ses.acls, scope)
		return
	}
	ses.acls[scope] = entries
}

@(private)
session_acl_clear_scope :: proc(ses: ^Session, scope: string) {
	delete_key(&ses.acls, scope)
}

// session.c:426-429 的 uh_id_len：到第一个通配符为止的前缀长度。
@(private)
acl_id_len :: proc(s: string) -> int {
	for i := 0; i < len(s); i += 1 {
		switch s[i] {
		case '*', '?', '[':
			return i
		}
	}
	return len(s)
}

@(private)
prefix_match :: proc(entry_object, object: string, sort_len: int) -> bool {
	if sort_len > len(object) || sort_len > len(entry_object) {
		return false
	}
	return entry_object[:sort_len] == object[:sort_len]
}

// fnmatch（FNM_NOESCAPE）：`*` 任意串、`?` 单字符、`[...]` 字符集（含 `!`/`^` 取反与 `a-z` 区间）。
// 上游用 libc 的 fnmatch；Odin 没有等价函数，这里手写等价实现（真实样本里 ACL 条目基本是
// 精确名，通配只出现在 login section 的 read/write `*` 里）。
fnmatch :: proc(pattern, name: string) -> bool {
	return fnmatch_at(pattern, name)
}

@(private)
fnmatch_at :: proc(pattern, name: string) -> bool {
	pi, ni := 0, 0
	star_pi, star_ni := -1, -1

	for ni < len(name) {
		if pi < len(pattern) {
			switch pattern[pi] {
			case '*':
				// 记住回退点，先当 `*` 匹配空串
				star_pi = pi
				star_ni = ni
				pi += 1
				continue
			case '?':
				pi += 1
				ni += 1
				continue
			case '[':
				matched, next_pi := fnmatch_class(pattern, pi, name[ni])
				if matched {
					pi = next_pi
					ni += 1
					continue
				}
				// 字符集不匹配 → 走回退
			case:
				if pattern[pi] == name[ni] {
					pi += 1
					ni += 1
					continue
				}
			}
		}

		if star_pi >= 0 {
			star_ni += 1
			ni = star_ni
			pi = star_pi + 1
			continue
		}
		return false
	}

	// 剩下的 pattern 必须全是 `*`
	for pi < len(pattern) && pattern[pi] == '*' {
		pi += 1
	}
	return pi == len(pattern)
}

// `[...]` 的一步：返回是否命中与该类之后的位置。不闭合的 `[` 按字面量处理。
@(private)
fnmatch_class :: proc(pattern: string, start: int, c: u8) -> (matched: bool, next: int) {
	i := start + 1
	if i >= len(pattern) {
		return pattern[start] == c, start + 1
	}

	negate := false
	if pattern[i] == '!' || pattern[i] == '^' {
		negate = true
		i += 1
	}

	hit := false
	first := true
	for i < len(pattern) {
		if pattern[i] == ']' && !first {
			i += 1
			return hit != negate, i
		}
		first = false

		// 区间 a-z
		if i + 2 < len(pattern) && pattern[i + 1] == '-' && pattern[i + 2] != ']' {
			if c >= pattern[i] && c <= pattern[i + 2] {
				hit = true
			}
			i += 3
			continue
		}
		if pattern[i] == c {
			hit = true
		}
		i += 1
	}
	// 没有闭合的 ']' —— 以字面量 '[' 处理
	return pattern[start] == c, start + 1
}

// ---------------------------------------------------------------------------
// JSON 小工具
// ---------------------------------------------------------------------------

@(private)
param_str :: proc(params: json.Object, key: string) -> (string, bool) {
	v, found := params[key]
	if !found {
		return "", false
	}
	s, is_str := v.(json.String)
	if !is_str {
		return "", false
	}
	return string(s), true
}

@(private)
param_int :: proc(params: json.Object, key: string) -> (i64, bool) {
	v, found := params[key]
	if !found {
		return 0, false
	}
	// 不用类型 switch：Odin 要求穷举 union 的全部成员，用断言链更直接
	if n, ok := v.(json.Integer); ok {
		return i64(n), true
	}
	if f, ok := v.(json.Float); ok {
		return i64(f), true
	}
	return 0, false
}

@(private)
param_obj :: proc(params: json.Object, key: string) -> (json.Object, bool) {
	v, found := params[key]
	if !found {
		return {}, false
	}
	obj, is_obj := v.(json.Object)
	return obj, is_obj
}

@(private)
parse_json_value :: proc(text: string, alloc: mem.Allocator) -> json.Value {
	doc: json.Value
	if err := json.unmarshal(transmute([]byte)(text), &doc, .JSON, alloc); err == nil {
		return doc
	}
	return json.Value(json.String(text))
}

@(private)
session_marshal :: proc(v: json.Value, alloc: mem.Allocator) -> string {
	data, err := json.unparse(v, {spec = .JSON}, alloc)
	if err != nil {
		return "null"
	}
	// 不复制：结果的生命周期跟 alloc
	return transmute(string)(data)
}

@(private)
section_option_string :: proc(s: Uci_Section, name: string) -> (string, bool) {
	for o in s.options {
		if o.name != name || o.is_list || len(o.values) == 0 {
			continue
		}
		return o.values[0], true
	}
	return "", false
}

// session dump（session.c:224-244）。acls 为真时带上 ACL 表。
@(private)
session_dump :: proc(ses: ^Session, with_acls: bool, alloc: mem.Allocator) -> string {
	doc := make(json.Object, 0, alloc)
	doc["ubus_rpc_session"] = json.String(ses.id)
	doc["timeout"] = json.Integer(i64(ses.timeout))
	doc["expires"] = json.Integer(session_remaining(ses))

	if with_acls {
		acls_text := session_dump_acls_json(ses, alloc)
		doc["acls"] = parse_json_value(acls_text, alloc)
	}

	values := json.Object{}
	for key, text in ses.data {
		values[key] = parse_json_value(text, alloc)
	}
	doc["data"] = json.Value(values)

	return session_marshal(json.Value(doc), alloc)
}

// 剩余秒数（session.c:233：uloop_timeout_remaining64 / 1000，即截断到秒）。
@(private)
session_remaining :: proc(ses: ^Session) -> i64 {
	if ses.timeout <= 0 {
		return 0
	}
	now := time.now()
	if now._nsec >= ses.expires_at._nsec {
		return 0
	}
	return i64(time.duration_seconds(time.diff(now, ses.expires_at)))
}

// ACL 表：scope → object → [function…]（session.c:188-222）。
@(private)
session_dump_acls_json :: proc(ses: ^Session, alloc: mem.Allocator) -> string {
	scopes := make(json.Object, 0, alloc)
	for scope, entries in ses.acls {
		objects := make(json.Object, 0, alloc)
		functions := make(map[string][dynamic]json.Value, 0, alloc)
		order := make([dynamic]string, 0, 4, alloc)
		for e in entries {
			list, found := functions[e.object]
			if !found {
				append(&order, e.object)
			}
			append(&list, json.Value(json.String(e.function)))
			functions[e.object] = list
		}
		for object in order {
			arr := functions[object]
			objects[object] = json.Value(json.Array(arr))
		}
		scopes[scope] = json.Value(objects)
	}
	return session_marshal(json.Value(scopes), alloc)
}

// ---------------------------------------------------------------------------
// 小工具：/dev/urandom 与 map 删除（core:os / core:mem 的薄封装，便于集中注释）
// ---------------------------------------------------------------------------

// 读满 buf。两个平台都有 /dev/urandom，所以这段不需要 provider。
@(private)
urandom_read :: proc(buf: []byte) -> bool {
	f, err := os.open("/dev/urandom")
	if err != nil {
		return false
	}
	defer os.close(f)

	got := 0
	for got < len(buf) {
		n, rerr := os.read(f, buf[got:])
		if rerr != nil || n <= 0 {
			return false
		}
		got += n
	}
	return true
}

// 惰性建默认会话（session.c:1380-1390：启动时建 000…0 并挂 unauthenticated 组）。
// 默认会话 timeout = 0（永不过期），且不可被 destroy（见 session_do_destroy）。
// P3-6 会在这里补 acl.d 的 unauthenticated 组；本轮 ACL 为空。
@(private)
session_ensure_default :: proc() {
	alloc := session_store_allocator()
	if g_sessions == nil {
		g_sessions = make(map[string]^Session, 0, alloc)
	}
	if SESSION_DEFAULT_ID in g_sessions {
		return
	}
	ses := new(Session, alloc)
	ses.id = SESSION_DEFAULT_ID
	ses.timeout = 0
	ses.data = make(map[string]string, 0, alloc)
	ses.acls = make(map[string][dynamic]Acl_Entry, 0, alloc)
	g_sessions[ses.id] = ses
}
