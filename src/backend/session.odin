package backend

// session —— molly 自持的 ubus 对象（逐段对齐 internal/backend/session.go）。
//
// 平台无关：密码校验 / uci 数据源 / acl.d 目录这三样平台差异经 hook_uci_sections /
// hook_verify_password / hook_acl_dir 给出（默认宿主实现见 platform_hooks.odin，
// 阶段 3h 会按平台拆分并覆盖）。
//
// 覆盖方法：create / list / get / set / unset / destroy / access / login / grant /
// revoke。`update` 在签名表里但无实现，与上游一致回 Method not found。
//
// 生命周期：会话数据（id / data / acls）必须长于请求，故全部落在 store_alloc
// （进程默认分配器）；每请求的临时解析用 context.allocator（HTTP handler 或入站调用的
// 动态 arena），返回即回收。凡是要存进会话的字符串，一律 clone 进 store_alloc。

import "core:fmt"
import "core:mem"
import "core:sync"
import "core:strings"
import "core:slice"
import "core:os"
import "core:time"
import "core:encoding/json"
import "base:runtime"

Sess_Default_ID           :: "00000000000000000000000000000000"
session_sid_len           :: 32
session_default_timeout   :: 300

acl_perms :: [2]string{"read", "write"}

// 平台钩子（默认在 ensure_store 里装宿主实现；阶段 3h 由平台文件覆盖）。
hook_uci_sections:    proc(config: string, alloc: mem.Allocator) -> ([]Uci_Section, bool)
hook_verify_password: proc(hash, password: string) -> bool
hook_acl_dir:         proc() -> string

ACL_Entry :: struct {
	object:   string, // 存进 store_alloc
	function: string, // 存进 store_alloc
	sort_len: int,
}

Session :: struct {
	id:         string,             // store_alloc
	timeout:    int,                // 秒；<=0 不过期
	expires_at: i64,                // unix 秒（timeout>0 时有效）
	data:       map[string]string,  // key → 该值的 JSON 文本（store_alloc）
	acls:       map[string][]ACL_Entry, // scope → entries（store_alloc）
}

sess_lock:   sync.Mutex
sess_store:  map[string]^Session
store_alloc: mem.Allocator
sess_ready:  bool

// json_opt —— 与 Go 的 encoding/json（map 按 key 排序、不转义 HTML）同形。
json_opt := json.Marshal_Options{spec = .JSON, sort_maps_by_key = true}

// ---------------------------------------------------------------------------
// 入口（注册为 "session" 对象）
// ---------------------------------------------------------------------------

session_handler :: proc(method, params_json: string, alloc: mem.Allocator) -> (status: i32, reply: string) {
	_ = alloc
	params := make(json.Object)
	if len(params_json) > 0 {
		if v, err := json.parse_string(params_json, .JSON, true, context.allocator); err == nil {
			if o, ok := v.(json.Object); ok {
				params = o
			}
		}
	}

	sync.mutex_lock(&sess_lock)
	defer sync.mutex_unlock(&sess_lock)

	session_ensure_store()
	session_prune_expired()

	switch method {
	case "create":
		return session_do_create(params)
	case "list":
		return session_do_list(params)
	case "get":
		return session_do_get(params)
	case "set":
		return session_do_set(params)
	case "unset":
		return session_do_unset(params)
	case "destroy":
		return session_do_destroy(params)
	case "access":
		return session_do_access(params)
	case "login":
		return session_do_login(params)
	case "grant", "revoke":
		return session_do_grant_revoke(method, params)
	}
	return Status_Method_Not_Found, ""
}

// ---------------------------------------------------------------------------
// create / list / destroy
// ---------------------------------------------------------------------------

session_do_create :: proc(params: json.Object) -> (i32, string) {
	timeout := session_default_timeout
	if v, ok := param_int(params, "timeout"); ok {
		timeout = v
	}
	ses, ok := session_new(timeout)
	if !ok {
		return Status_Unknown_Error, ""
	}
	return Status_OK, session_dump(ses, true)
}

session_do_list :: proc(params: json.Object) -> (i32, string) {
	if sid, ok := param_str(params, "ubus_rpc_session"); ok {
		ses := session_get(sid)
		if ses == nil {
			return Status_Not_Found, ""
		}
		return Status_OK, session_dump(ses, true)
	}

	ids: [dynamic]string
	defer delete(ids)
	for id in sess_store {
		append(&ids, id)
	}
	slice.sort(ids[:])

	arr: json.Array = make(json.Array)
	for id in ids {
		append(&arr, session_dump_value(sess_store[id], true))
	}
	return Status_OK, json_unparse(json.Value(arr))
}

session_do_destroy :: proc(params: json.Object) -> (i32, string) {
	sid, ok := param_str(params, "ubus_rpc_session")
	if !ok {
		return Status_Invalid_Argument, ""
	}
	if sid == Sess_Default_ID {
		return Status_Permission_Denied, "" // 默认会话不可销毁
	}
	ses := session_get(sid)
	if ses == nil {
		return Status_Not_Found, ""
	}
	session_destroy(ses)
	return Status_OK, ""
}

// ---------------------------------------------------------------------------
// get / set / unset
// ---------------------------------------------------------------------------

session_do_get :: proc(params: json.Object) -> (i32, string) {
	sid, ok := param_str(params, "ubus_rpc_session")
	if !ok {
		return Status_Invalid_Argument, ""
	}
	ses := session_get(sid)
	if ses == nil {
		return Status_Not_Found, ""
	}

	values: json.Object = make(json.Object)
	if kv, has := params["keys"]; has {
		if arr, is_arr := kv.(json.Array); is_arr {
			for e in arr {
				s, is_str := e.(json.String)
				if !is_str {
					continue
				}
				key := string(s)
				if text, found := ses.data[key]; found {
					values[key] = parse_json_text(text)
				}
			}
		}
	} else {
		for key, text in ses.data {
			values[key] = parse_json_text(text)
		}
	}

	doc: json.Object = make(json.Object)
	doc["values"] = values
	return Status_OK, json_unparse(json.Value(doc))
}

session_do_set :: proc(params: json.Object) -> (i32, string) {
	sid, ok := param_str(params, "ubus_rpc_session")
	if !ok {
		return Status_Invalid_Argument, ""
	}
	vraw, has := params["values"]
	vobj, is_obj := vraw.(json.Object)
	if !has || !is_obj {
		return Status_Invalid_Argument, ""
	}
	ses := session_get(sid)
	if ses == nil {
		return Status_Not_Found, ""
	}
	for key, val in vobj {
		if key == "" {
			continue
		}
		set_persistent(&ses.data, key, json_unparse(val))
	}
	return Status_OK, ""
}

session_do_unset :: proc(params: json.Object) -> (i32, string) {
	sid, ok := param_str(params, "ubus_rpc_session")
	if !ok {
		return Status_Invalid_Argument, ""
	}
	ses := session_get(sid)
	if ses == nil {
		return Status_Not_Found, ""
	}
	kv, has := params["keys"]
	if !has {
		session_clear_data(ses)
		return Status_OK, ""
	}
	if arr, is_arr := kv.(json.Array); is_arr {
		for e in arr {
			if s, is_str := e.(json.String); is_str {
				session_delete_data(ses, string(s))
			}
		}
	}
	return Status_OK, ""
}

// ---------------------------------------------------------------------------
// access
// ---------------------------------------------------------------------------

session_do_access :: proc(params: json.Object) -> (i32, string) {
	sid, ok := param_str(params, "ubus_rpc_session")
	if !ok {
		return Status_Invalid_Argument, ""
	}
	ses := session_get(sid)
	if ses == nil {
		return Status_Not_Found, ""
	}
	object, has_obj := param_str(params, "object")
	function, has_fun := param_str(params, "function")
	if has_obj && has_fun {
		scope, has_scope := param_str(params, "scope")
		if !has_scope {
			scope = "ubus"
		}
		allowed := session_acl_allowed(ses, scope, object, function)
		doc: json.Object = make(json.Object)
		doc["access"] = json.Boolean(allowed)
		return Status_OK, json_unparse(json.Value(doc))
	}
	return Status_OK, json_unparse(session_acls_table(ses))
}

// ---------------------------------------------------------------------------
// grant / revoke
// ---------------------------------------------------------------------------

session_do_grant_revoke :: proc(method: string, params: json.Object) -> (i32, string) {
	sid, ok := param_str(params, "ubus_rpc_session")
	if !ok {
		return Status_Invalid_Argument, ""
	}
	ses := session_get(sid)
	if ses == nil {
		return Status_Not_Found, ""
	}
	scope, has_scope := param_str(params, "scope")
	if !has_scope {
		scope = "ubus"
	}

	raw, has_objects := params["objects"]
	if !has_objects {
		if method == "grant" {
			return Status_Invalid_Argument, ""
		}
		session_acl_clear_scope(ses, scope)
		return Status_OK, ""
	}

	if arr, is_arr := raw.(json.Array); is_arr {
		for inner_v in arr {
			inner, is_inner := inner_v.(json.Array)
			if !is_inner {
				continue
			}
			object, function, taken := "", "", 0
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
			if object == "" || function == "" {
				continue
			}
			if method == "grant" {
				session_acl_grant(ses, scope, object, function)
			} else {
				session_acl_revoke(ses, scope, object, function)
			}
		}
	}
	return Status_OK, ""
}

// ---------------------------------------------------------------------------
// login
// ---------------------------------------------------------------------------

session_do_login :: proc(params: json.Object) -> (i32, string) {
	username, has_user := param_str(params, "username")
	password, has_pass := param_str(params, "password")
	if !has_user || !has_pass {
		return Status_Invalid_Argument, ""
	}

	login, ok := session_login_check(username, password)
	if !ok {
		return Status_Permission_Denied, ""
	}

	timeout := session_default_timeout
	if v, ok := param_int(params, "timeout"); ok {
		timeout = v
	}

	ses, ok_new := session_new(timeout)
	if !ok_new {
		return Status_Unknown_Error, ""
	}
	set_persistent(&ses.data, "username", json_unparse(json.Value(json.String(username))))
	// token 是登录可用性的硬要求：dispatcher.uc 判会话有效靠 token 是字符串。
	tok, ok2 := random_hex(store_alloc, session_sid_len)
	if !ok2 {
		session_destroy(ses)
		return Status_Unknown_Error, ""
	}
	set_persistent(&ses.data, "token", json_unparse(json.Value(json.String(tok))))

	// 会话建立后按 login section 的 read/write 组加载 acl.d
	session_load_acls(ses, login)
	return Status_OK, session_dump(ses, true)
}

session_login_check :: proc(username, password: string) -> (^Uci_Section, bool) {
	sections, ok := hook_uci_sections("rpcd", store_alloc)
	if !ok {
		return nil, false
	}
	for i := 0; i < len(sections); i += 1 {
		s := &sections[i]
		if s.type_name != "login" {
			continue
		}
		name, has_name := section_option_string(s, "username")
		if !has_name || name != username {
			continue
		}
		hash, has_hash := section_option_string(s, "password")
		if !has_hash {
			continue
		}
		if hook_verify_password(hash, password) {
			return s, true
		}
	}
	return nil, false
}

// ---------------------------------------------------------------------------
// acl.d 加载
// ---------------------------------------------------------------------------

session_load_acls :: proc(ses: ^Session, login: ^Uci_Section) {
	dir := hook_acl_dir()
	infos, err := os.read_all_directory_by_path(dir, context.allocator)
	if err != nil {
		return
	}
	defer delete(infos, context.allocator)

	names: [dynamic]string
	defer delete(names)
	for info in infos {
		if info.type == .Directory {
			continue
		}
		if !strings.has_suffix(info.name, ".json") {
			continue
		}
		append(&names, info.name)
	}
	slice.sort(names[:])
	for name in names {
		session_load_acl_file(ses, login, path_join(dir, name))
	}
}

session_load_acl_file :: proc(ses: ^Session, login: ^Uci_Section, path: string) {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		return
	}
	defer delete(data, context.allocator)

	gv, perr := json.parse_string(string(data), .JSON, false, context.allocator)
	if perr != nil {
		return
	}
	groups, ok := gv.(json.Object)
	if !ok {
		return
	}

	gnames: [dynamic]string
	defer delete(gnames)
	for gn in groups {
		append(&gnames, gn)
	}
	slice.sort(gnames[:])

	for gn in gnames {
		gval := groups[gn]
		group, is_obj := gval.(json.Object)
		if !is_obj {
			continue
		}
		for perm in acl_perms {
			perm_raw, has := group[perm]
			if !has {
				continue
			}
			perm_obj, is_obj2 := perm_raw.(json.Object)
			if !is_obj2 {
				continue // 上游要求 TABLE
			}
			if !session_login_test_permission(login, perm, gn) {
				continue
			}
			for scope_name, scope_val in perm_obj {
				if tbl, is_tbl := scope_val.(json.Object); is_tbl {
					for obj_name, funcs_val in tbl {
						if funcs, is_arr := funcs_val.(json.Array); is_arr {
							for f in funcs {
								if fs, is_str := f.(json.String); is_str {
									session_acl_grant(ses, scope_name, obj_name, string(fs))
								}
							}
						}
					}
				} else if list, is_arr := scope_val.(json.Array); is_arr {
					for o in list {
						if os_, is_str := o.(json.String); is_str {
							session_acl_grant(ses, scope_name, string(os_), perm)
						}
					}
				}
			}
			session_acl_grant(ses, "access-group", gn, perm)
		}
	}
}

// session_login_test_permission 对齐 session.c:930-990。
session_login_test_permission :: proc(login: ^Uci_Section, perm, group: string) -> bool {
	if login == nil {
		return group == "unauthenticated"
	}
	for o in login.options {
		if !o.is_list || o.name != perm {
			continue
		}
		for v in o.values {
			if len(v) == 0 || v[0] != '!' {
				continue
			}
			p := strings.trim_space(v[1:])
			if len(p) == 0 {
				continue
			}
			if fnmatch(p, group) {
				return false
			}
		}
		for v in o.values {
			if len(v) == 0 || v[0] == '!' {
				continue
			}
			if fnmatch(v, group) {
				return true
			}
		}
	}
	if perm == "read" {
		return session_login_test_permission(login, "write", group)
	}
	return false
}

// ---------------------------------------------------------------------------
// 会话存储
// ---------------------------------------------------------------------------

session_ensure_store :: proc() {
	if sess_ready {
		return
	}
	store_alloc = runtime.default_allocator()
	if hook_uci_sections == nil {
		hook_uci_sections = host_uci_sections
	}
	if hook_verify_password == nil {
		hook_verify_password = host_verify_password
	}
	if hook_acl_dir == nil {
		hook_acl_dir = host_acl_dir
	}
	sess_store = make(map[string]^Session, 0, store_alloc)
	sess_ready = true
	session_ensure_default()
}

session_new :: proc(timeout: int) -> (^Session, bool) {
	id, ok := random_hex(store_alloc, session_sid_len)
	if !ok {
		return nil, false
	}
	ses := new(Session, store_alloc)
	if ses == nil {
		delete(id, store_alloc)
		return nil, false
	}
	ses^ = Session{
		id = id,
		timeout = timeout,
		data = make(map[string]string, 0, store_alloc),
		acls = make(map[string][]ACL_Entry, 0, store_alloc),
	}
	session_touch(ses)
	sess_store[ses.id] = ses
	return ses, true
}

session_get :: proc(id: string) -> ^Session {
	ses, found := sess_store[id]
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

session_destroy :: proc(ses: ^Session) {
	if ses == nil {
		return
	}
	delete_key(&sess_store, ses.id)
	session_free(ses)
}

session_free :: proc(ses: ^Session) {
	for _, text in ses.data {
		delete(text, store_alloc)
	}
	delete(ses.data)
	for _, entries in ses.acls {
		delete(entries, store_alloc)
	}
	delete(ses.acls)
	delete(ses.id, store_alloc)
	free(ses, store_alloc)
}

session_now_sec :: proc() -> i64 {
	return time.to_unix_seconds(time.now())
}

session_expired :: proc(s: ^Session) -> bool {
	if s.timeout <= 0 {
		return false
	}
	return session_now_sec() >= s.expires_at
}

session_touch :: proc(s: ^Session) {
	if s.timeout > 0 {
		s.expires_at = session_now_sec() + i64(s.timeout)
	}
}

session_prune_expired :: proc() {
	dead: [dynamic]string
	defer delete(dead)
	for id, ses in sess_store {
		if session_expired(ses) {
			append(&dead, id)
		}
	}
	for id in dead {
		if ses, found := sess_store[id]; found {
			delete_key(&sess_store, id)
			session_free(ses)
		}
	}
}

session_ensure_default :: proc() {
	if _, found := sess_store[Sess_Default_ID]; found {
		return
	}
	id, _ := strings.clone(Sess_Default_ID, store_alloc)
	ses := new(Session, store_alloc)
	ses^ = Session{
		id = id,
		timeout = 0,
		data = make(map[string]string, 0, store_alloc),
		acls = make(map[string][]ACL_Entry, 0, store_alloc),
	}
	session_load_acls(ses, nil)
	sess_store[ses.id] = ses
}

// ---------------------------------------------------------------------------
// HTTP 侧鉴权入口（对齐 backend.go 的 Backend 接口）
// ---------------------------------------------------------------------------

// Session_Access_Ubus —— HTTP 前置 ACL 校验（uh_ubus_allowed）；取不到会话 → false（fail-closed）。
Session_Access_Ubus :: proc(sid, object, function: string) -> bool {
	sync.mutex_lock(&sess_lock)
	defer sync.mutex_unlock(&sess_lock)
	session_ensure_store()
	ses := session_get(sid)
	if ses == nil {
		return false
	}
	// `:subscribe` 是订阅伪方法：有效登录会话即可订阅，默认会话拒绝。
	if function == ":subscribe" {
		return sid != Sess_Default_ID
	}
	return session_acl_allowed(ses, "ubus", object, function)
}

// Session_Self_Service —— session 的 get/set/unset/destroy 由对象自身按 sid 鉴权。
Session_Self_Service :: proc(sid, method: string) -> bool {
	if method != "get" && method != "set" && method != "unset" && method != "destroy" {
		return false
	}
	if sid == "" || sid == Sess_Default_ID {
		return false
	}
	sync.mutex_lock(&sess_lock)
	defer sync.mutex_unlock(&sess_lock)
	session_ensure_store()
	return session_get(sid) != nil
}

// Session_ACL_Level —— depends.acl 三态判定。
Session_ACL_Level :: proc(sid: string, groups: []string) -> ACL_Level {
	if len(groups) == 0 {
		return .Writable
	}
	sync.mutex_lock(&sess_lock)
	defer sync.mutex_unlock(&sess_lock)
	session_ensure_store()

	ses := session_get(sid)
	if ses == nil {
		return .Missing
	}
	entries, found := ses.acls["access-group"]
	if !found {
		return .Missing
	}
	writable := false
	for g in groups {
		read := acl_group_has(entries, g, "read")
		write := acl_group_has(entries, g, "write")
		if !read && !write {
			return .Missing
		}
		if write {
			writable = true
		}
	}
	if writable {
		return .Writable
	}
	return .Read_Only
}

acl_group_has :: proc(entries: []ACL_Entry, group, perm: string) -> bool {
	for e in entries {
		if e.object == group && e.function == perm {
			return true
		}
	}
	return false
}

// session_access_bridge —— 桥接层（会话交给 rpcd 的形态）注入：进程内自有对象（uci/file/…）
// 内部那道 ACL 也得问 rpcd —— 桥接态下真会话在 rpcd，molly 私有 sessionStore 里查不到该 sid，
// 不转问就会一律误判成 Permission denied。返回 (允许, 已处理)；handled==false 时退回私有存储判定。
// darwin / 非桥接态恒为 nil → 完全走原来的私有存储，行为不变。装配见 Set_Session_On_Bus。
session_access_bridge: proc(sid, scope, object, function: string) -> (bool, bool)

// session_access —— 对象内部那道 ACL 查询入口（scope 由调用方给：file/uci/…）。fail-closed。
session_access :: proc(sid, scope, object, function: string) -> bool {
	// 桥接态：会话在 rpcd，私有存储没有它 → 这道内部 ACL 转问 rpcd（与 :80 同源同判）。
	// 在拿 sess_lock 之前先短路，避免与 rpcd 往返（走 ubus_mu）嵌套。
	if bridge := session_access_bridge; bridge != nil {
		ok, handled := bridge(sid, scope, object, function)
		if handled {
			return ok
		}
	}
	sync.mutex_lock(&sess_lock)
	defer sync.mutex_unlock(&sess_lock)
	session_ensure_store()
	ses := session_get(sid)
	if ses == nil {
		return false
	}
	return session_acl_allowed(ses, scope, object, function)
}

// ---------------------------------------------------------------------------
// ACL 匹配 / 授予
// ---------------------------------------------------------------------------

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

session_acl_grant :: proc(ses: ^Session, scope, object, function: string) {
	entries := ses.acls[scope]
	for e in entries {
		if e.object == object && e.function == function {
			return // 已存在，不动
		}
	}
	obj_c, _ := strings.clone(object, store_alloc)
	fun_c, _ := strings.clone(function, store_alloc)
	n := len(entries)
	grown := make([]ACL_Entry, n + 1, store_alloc)
	copy(grown, entries)
	grown[n] = ACL_Entry{object = obj_c, function = fun_c, sort_len = acl_id_len(object)}
	if n > 0 {
		delete(entries, store_alloc) // 释放旧 backing（元素字符串仍属新切片）
	}
	if _, has := ses.acls[scope]; has {
		ses.acls[scope] = grown // 键已存在：保留原 scope 字符串
	} else {
		sk, _ := strings.clone(scope, store_alloc)
		ses.acls[sk] = grown
	}
}

session_acl_revoke :: proc(ses: ^Session, scope, object, function: string) {
	entries, found := ses.acls[scope]
	if !found {
		return
	}
	kept: [dynamic]ACL_Entry
	defer delete(kept)
	for e in entries {
		if e.object == object && e.function == function {
			continue
		}
		append(&kept, e)
	}
	if len(kept) == 0 {
		if arr, has := ses.acls[scope]; has {
			delete(arr, store_alloc)
		}
		delete_key(&ses.acls, scope)
		return
	}
	delete(entries, store_alloc)
	kept2 := make([]ACL_Entry, len(kept), store_alloc)
	copy(kept2, kept[:])
	ses.acls[scope] = kept2
}

session_acl_clear_scope :: proc(ses: ^Session, scope: string) {
	if arr, has := ses.acls[scope]; has {
		delete(arr, store_alloc)
		delete_key(&ses.acls, scope)
	}
}

// acl_id_len：到第一个通配符为止的前缀长度（uh_id_len）。
acl_id_len :: proc(s: string) -> int {
	for i := 0; i < len(s); i += 1 {
		c := s[i]
		if c == '*' || c == '?' || c == '[' {
			return i
		}
	}
	return len(s)
}

prefix_match :: proc(entry_object, object: string, sort_len: int) -> bool {
	if sort_len > len(object) || sort_len > len(entry_object) {
		return false
	}
	return entry_object[0:sort_len] == object[0:sort_len]
}

// fnmatch（FNM_NOESCAPE）：`*` 任意串、`?` 单字符、`[...]` 字符集。
fnmatch :: proc(pattern, name: string) -> bool {
	pi, ni := 0, 0
	star_pi, star_ni := -1, -1
	for ni < len(name) {
		if pi < len(pattern) {
			c := pattern[pi]
			if c == '*' {
				star_pi, star_ni = pi, ni
				pi += 1
				continue
			} else if c == '?' {
				pi += 1
				ni += 1
				continue
			} else if c == '[' {
				matched, next_pi := fnmatch_class(pattern, pi, name[ni])
				if matched {
					pi = next_pi
					ni += 1
					continue
				}
			} else if c == name[ni] {
				pi += 1
				ni += 1
				continue
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
	for pi < len(pattern) && pattern[pi] == '*' {
		pi += 1
	}
	return pi == len(pattern)
}

// fnmatch_class 处理 `[...]`。不闭合的 `[` 按字面量处理。
fnmatch_class :: proc(pattern: string, start: int, c: u8) -> (bool, int) {
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
			return hit != negate, i + 1
		}
		first = false
		if i+2 < len(pattern) && pattern[i+1] == '-' && pattern[i+2] != ']' {
			if c >= pattern[i] && c <= pattern[i+2] {
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
	return pattern[start] == c, start + 1
}

// ---------------------------------------------------------------------------
// dump
// ---------------------------------------------------------------------------

session_dump :: proc(ses: ^Session, with_acls: bool) -> string {
	return json_unparse(session_dump_value(ses, with_acls))
}

session_dump_value :: proc(ses: ^Session, with_acls: bool) -> json.Value {
	values: json.Object = make(json.Object)
	for key, text in ses.data {
		values[key] = parse_json_text(text)
	}
	doc: json.Object = make(json.Object)
	doc["ubus_rpc_session"] = json.String(ses.id)
	doc["timeout"] = json.Integer(ses.timeout)
	doc["expires"] = json.Integer(session_remaining(ses))
	doc["data"] = values
	if with_acls {
		doc["acls"] = session_acls_table(ses)
	}
	return json.Value(doc)
}

session_remaining :: proc(ses: ^Session) -> i64 {
	if ses.timeout <= 0 {
		return 0
	}
	rem := ses.expires_at - session_now_sec()
	if rem < 0 {
		return 0
	}
	return rem
}

// session_acls_table —— scope → object → [function…]。
session_acls_table :: proc(ses: ^Session) -> json.Value {
	out: json.Object = make(json.Object)
	for scope, entries in ses.acls {
		objs: json.Object = make(json.Object)
		for e in entries {
			prev, has := objs[e.object]
			arr, is_arr := prev.(json.Array)
			if !has || !is_arr {
				arr = make(json.Array)
			}
			append(&arr, json.String(e.function))
			objs[e.object] = arr
		}
		out[scope] = objs
	}
	return json.Value(out)
}

// ---------------------------------------------------------------------------
// 小工具
// ---------------------------------------------------------------------------

param_str :: proc(o: json.Object, key: string) -> (string, bool) {
	v, found := o[key]
	if !found {
		return "", false
	}
	s, ok := v.(json.String)
	return string(s), ok
}

param_int :: proc(o: json.Object, key: string) -> (int, bool) {
	v, found := o[key]
	if !found {
		return 0, false
	}
	if n, ok := v.(json.Integer); ok {
		return int(n), true
	}
	if f, ok := v.(json.Float); ok {
		return int(f), true
	}
	return 0, false
}

section_option_string :: proc(s: ^Uci_Section, name: string) -> (string, bool) {
	for o in s.options {
		if o.name != name || o.is_list || len(o.values) == 0 {
			continue
		}
		return o.values[0], true
	}
	return "", false
}

// parse_json_text —— 把存下来的 JSON 文本重解析成 Value；非法则退化成字符串值。
parse_json_text :: proc(text: string) -> json.Value {
	v, err := json.parse_string(text, .JSON, true, context.allocator)
	if err != nil {
		return json.Value(json.String(text))
	}
	return v
}

json_unparse :: proc(v: json.Value) -> string {
	s, err := json.unparse(v, json_opt, context.allocator)
	if err != nil {
		return "null"
	}
	return s
}

// set_persistent —— 往 map 里放一条 store_alloc 持久的 key/value（覆盖旧值并释放）。
set_persistent :: proc(m: ^map[string]string, key, value: string) {
	vc, _ := strings.clone(value, store_alloc)
	if old, has := m^[key]; has {
		delete(old, store_alloc)
		m^[key] = vc // 键已存在：只换值，保留原 key 字符串
		return
	}
	kc, _ := strings.clone(key, store_alloc)
	m^[kc] = vc
}

session_clear_data :: proc(ses: ^Session) {
	for _, text in ses.data {
		delete(text, store_alloc)
	}
	delete(ses.data)
	ses.data = make(map[string]string, 0, store_alloc)
}

session_delete_data :: proc(ses: ^Session, key: string) {
	if text, has := ses.data[key]; has {
		delete(text, store_alloc)
		delete_key(&ses.data, key)
	}
}

path_join :: proc(dir, name: string) -> string {
	if len(dir) > 0 && dir[len(dir)-1] == '/' {
		return fmt.tprintf("%s%s", dir, name)
	}
	return fmt.tprintf("%s/%s", dir, name)
}

// random_hex —— 取 n 个十六进制字符（读 /dev/urandom，跨 darwin/linux 一致）。
random_hex :: proc(alloc: mem.Allocator, n: int) -> (string, bool) {
	nbytes := (n + 1) / 2
	buf := make([]u8, nbytes, alloc)
	f, err := os.open("/dev/urandom")
	if err != nil {
		delete(buf, alloc)
		return "", false
	}
	defer os.close(f)
	got, rerr := os.read(f, buf)
	if rerr != nil || got < nbytes {
		delete(buf, alloc)
		return "", false
	}
	digits := "0123456789abcdef"
	out := make([]u8, n, alloc)
	for i := 0; i < n; i += 1 {
		b := buf[i/2]
		if i%2 == 0 {
			out[i] = digits[int(b >> 4)]
		} else {
			out[i] = digits[int(b & 0x0f)]
		}
	}
	delete(buf, alloc)
	return string(out), true
}
