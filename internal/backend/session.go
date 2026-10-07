package backend

// session 对象 —— molly 自持的 ubus 对象之一（对齐 Odin 版 src/backend/session.odin）。
//
// 平台无关：密码校验 / acl.d 目录这两个平台差异由同包的 uciConfigSections、
// sessionVerifyPassword、sessionACLDir 三个钩子给出（darwin.go / linux.go 各一份，
// 与 Odin 的 `#+build` 双实现同义）。
//
// 覆盖的方法（sessionSig）：create / list / get / set / unset / destroy / access /
// login / grant / revoke。`update` 在签名表里但没有实现，与上游一致回 METHOD_NOT_FOUND。
//
// 会话数据（id / data / acls）的生命周期必须长于请求，所以全部放在包级 store 里，
// 只用 Go 的堆（不牵涉调用方的分配）。

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

const (
	// SessionDefaultID：未认证会话的哨兵值（session.c 的默认会话）。
	SessionDefaultID = "00000000000000000000000000000000"
	sessionSIDLen    = 32
	// sessionDefaultTimeout：上游 SESSION_DEFAULT_TIMEOUT（秒）。
	sessionDefaultTimeout = 300

	// session 对象自己的状态码（Odin 版 session.odin:41-46）。
	sessionStatusInvalidArgument  = StatusInvalidArgument
	sessionStatusMethodNotFound   = StatusMethodNotFound
	sessionStatusNotFound         = StatusNotFound
	sessionStatusPermissionDenied = StatusPermissionDenied
	sessionStatusUnknownError     = StatusUnknownError
)

// aclEntry 是 session.c:432-480 的一个 ACL 条目：一个 scope 下一组 (object, function)。
// sortLen = 前缀长度（到第一个通配符为止，uh_id_len），匹配时用于快速剪枝。
type aclEntry struct {
	object   string
	function string
	sortLen  int
}

type session struct {
	id        string
	timeout   int // 秒；<= 0 表示不过期
	expiresAt time.Time
	data      map[string]string     // key → 该值的 JSON 文本（保类型）
	acls      map[string][]aclEntry // scope → entries
}

var (
	sessionMu    sync.Mutex
	sessionStore map[string]*session
)

// ---------------------------------------------------------------------------
// 入口
// ---------------------------------------------------------------------------

// SessionCall 是一次 session 对象的方法调用。
// reply == "" 表示上游「不回数据」（set / unset / destroy 三种）；
// status != 0 时 reply 无效，调用方按 ubus 状态码回错误。
func SessionCall(method, paramsJSON string) (string, int) {
	var params map[string]json.RawMessage
	if len(paramsJSON) > 0 {
		if err := json.Unmarshal([]byte(paramsJSON), &params); err != nil {
			params = nil
		}
	}

	sessionMu.Lock()
	defer sessionMu.Unlock()

	sessionEnsureDefault()
	sessionPruneExpired()

	switch method {
	case "create":
		return sessionDoCreate(params)
	case "list":
		return sessionDoList(params)
	case "get":
		return sessionDoGet(params)
	case "set":
		return sessionDoSet(params)
	case "unset":
		return sessionDoUnset(params)
	case "destroy":
		return sessionDoDestroy(params)
	case "access":
		return sessionDoAccess(params)
	case "login":
		return sessionDoLogin(params)
	case "grant", "revoke":
		return sessionDoGrantRevoke(method, params)
	}
	return "", sessionStatusMethodNotFound
}

// ---------------------------------------------------------------------------
// create / list / destroy
// ---------------------------------------------------------------------------

func sessionDoCreate(params map[string]json.RawMessage) (string, int) {
	timeout := sessionDefaultTimeout
	if v, ok := paramInt(params, "timeout"); ok {
		timeout = v
	}
	ses := sessionNew(timeout)
	if ses == nil {
		return "", sessionStatusUnknownError
	}
	return sessionDump(ses, true), sessionStatusOK()
}

func sessionDoList(params map[string]json.RawMessage) (string, int) {
	if sid, ok := paramStr(params, "ubus_rpc_session"); ok {
		ses := sessionGet(sid)
		if ses == nil {
			return "", sessionStatusNotFound
		}
		return sessionDump(ses, true), sessionStatusOK()
	}

	ids := make([]string, 0, len(sessionStore))
	for id := range sessionStore {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	arr := make([]json.RawMessage, 0, len(ids))
	for _, id := range ids {
		arr = append(arr, json.RawMessage(sessionDump(sessionStore[id], true)))
	}
	return marshalNoEscape(arr), sessionStatusOK()
}

func sessionDoDestroy(params map[string]json.RawMessage) (string, int) {
	sid, ok := paramStr(params, "ubus_rpc_session")
	if !ok {
		return "", sessionStatusInvalidArgument
	}
	if sid == SessionDefaultID {
		// 默认会话不可销毁（session.c:806-807）
		return "", sessionStatusPermissionDenied
	}
	ses := sessionGet(sid)
	if ses == nil {
		return "", sessionStatusNotFound
	}
	sessionDestroy(ses)
	return "", sessionStatusOK()
}

// ---------------------------------------------------------------------------
// get / set / unset
// ---------------------------------------------------------------------------

func sessionDoGet(params map[string]json.RawMessage) (string, int) {
	sid, ok := paramStr(params, "ubus_rpc_session")
	if !ok {
		return "", sessionStatusInvalidArgument
	}
	ses := sessionGet(sid)
	if ses == nil {
		return "", sessionStatusNotFound
	}

	values := map[string]json.RawMessage{}
	if raw, has := params["keys"]; has {
		var keys []json.RawMessage
		if err := json.Unmarshal(raw, &keys); err == nil {
			for _, el := range keys {
				key, isStr := rawStr(el)
				if !isStr {
					continue
				}
				if text, found := ses.data[key]; found {
					values[key] = json.RawMessage(text)
				}
			}
		}
	} else {
		for key, text := range ses.data {
			values[key] = json.RawMessage(text)
		}
	}
	return marshalNoEscape(map[string]any{"values": values}), sessionStatusOK()
}

func sessionDoSet(params map[string]json.RawMessage) (string, int) {
	sid, ok := paramStr(params, "ubus_rpc_session")
	if !ok {
		return "", sessionStatusInvalidArgument
	}
	values, has := paramObject(params, "values")
	if !has {
		return "", sessionStatusInvalidArgument
	}
	ses := sessionGet(sid)
	if ses == nil {
		return "", sessionStatusNotFound
	}
	for key, val := range values {
		if key == "" {
			continue
		}
		ses.data[key] = string(val)
	}
	return "", sessionStatusOK()
}

func sessionDoUnset(params map[string]json.RawMessage) (string, int) {
	sid, ok := paramStr(params, "ubus_rpc_session")
	if !ok {
		return "", sessionStatusInvalidArgument
	}
	ses := sessionGet(sid)
	if ses == nil {
		return "", sessionStatusNotFound
	}
	keys, has := params["keys"]
	if !has {
		ses.data = map[string]string{}
		return "", sessionStatusOK()
	}
	var arr []json.RawMessage
	if err := json.Unmarshal(keys, &arr); err == nil {
		for _, el := range arr {
			if key, isStr := rawStr(el); isStr {
				delete(ses.data, key)
			}
		}
	}
	return "", sessionStatusOK()
}

// ---------------------------------------------------------------------------
// access
// ---------------------------------------------------------------------------

func sessionDoAccess(params map[string]json.RawMessage) (string, int) {
	sid, ok := paramStr(params, "ubus_rpc_session")
	if !ok {
		return "", sessionStatusInvalidArgument
	}
	ses := sessionGet(sid)
	if ses == nil {
		return "", sessionStatusNotFound
	}

	object, hasObj := paramStr(params, "object")
	function, hasFun := paramStr(params, "function")
	if hasObj && hasFun {
		scope := "ubus"
		if s, hasScope := paramStr(params, "scope"); hasScope {
			scope = s
		}
		allowed := sessionACLAllowed(ses, scope, object, function)
		return marshalNoEscape(map[string]any{"access": allowed}), sessionStatusOK()
	}
	return sessionDumpACLsJSON(ses), sessionStatusOK()
}

// ---------------------------------------------------------------------------
// grant / revoke
// ---------------------------------------------------------------------------

func sessionDoGrantRevoke(method string, params map[string]json.RawMessage) (string, int) {
	sid, ok := paramStr(params, "ubus_rpc_session")
	if !ok {
		return "", sessionStatusInvalidArgument
	}
	ses := sessionGet(sid)
	if ses == nil {
		return "", sessionStatusNotFound
	}
	scope := "ubus"
	if s, hasScope := paramStr(params, "scope"); hasScope {
		scope = s
	}

	raw, hasObjects := params["objects"]
	if !hasObjects {
		if method == "grant" {
			return "", sessionStatusInvalidArgument
		}
		delete(ses.acls, scope)
		return "", sessionStatusOK()
	}

	var arr [][]json.RawMessage
	if err := json.Unmarshal(raw, &arr); err == nil {
		for _, inner := range arr {
			object, function := "", ""
			taken := 0
			for _, el := range inner {
				if s, isStr := rawStr(el); isStr {
					if taken == 0 {
						object = s
					} else if taken == 1 {
						function = s
					}
					taken++
				}
			}
			if object == "" || function == "" {
				continue
			}
			if method == "grant" {
				sessionACLGrant(ses, scope, object, function)
			} else {
				sessionACLRevoke(ses, scope, object, function)
			}
		}
	}
	return "", sessionStatusOK()
}

// ---------------------------------------------------------------------------
// login
// ---------------------------------------------------------------------------

func sessionDoLogin(params map[string]json.RawMessage) (string, int) {
	username, hasUser := paramStr(params, "username")
	password, hasPass := paramStr(params, "password")
	if !hasUser || !hasPass {
		return "", sessionStatusInvalidArgument
	}

	login, ok := sessionLoginCheck(username, password)
	if !ok {
		return "", sessionStatusPermissionDenied
	}

	timeout := sessionDefaultTimeout
	if v, ok := paramInt(params, "timeout"); ok {
		timeout = v
	}

	ses := sessionNew(timeout)
	if ses == nil {
		return "", sessionStatusUnknownError
	}
	ses.data["username"] = quoteJSON(username)
	// `token` 是登录可用性的硬要求：LuCI 的 dispatcher.uc 判定会话有效靠
	// `type(sdat.values.token) == 'string'`——没有 token 就判为未认证，整站 403。
	ses.data["token"] = quoteJSON(randomHex(sessionSIDLen))

	// session.c:1204：会话建立后按 login section 的 read/write 组加载 acl.d
	sessionLoadACLs(ses, login)
	return sessionDump(ses, true), sessionStatusOK()
}

func sessionLoginCheck(username, password string) (*UciSection, bool) {
	sections, ok := uciConfigSections("rpcd")
	if !ok {
		return nil, false
	}
	for i := range sections {
		s := &sections[i]
		if s.TypeName != "login" {
			continue
		}
		name, hasName := sectionOptionString(s, "username")
		if !hasName || name != username {
			continue
		}
		hash, hasHash := sectionOptionString(s, "password")
		if !hasHash {
			continue
		}
		if sessionVerifyPassword(hash, password) {
			return s, true
		}
	}
	return nil, false
}

// ---------------------------------------------------------------------------
// acl.d 加载
// ---------------------------------------------------------------------------

func sessionLoadACLs(ses *session, login *UciSection) {
	dir := sessionACLDir()
	entries, err := os.ReadDir(dir)
	if err != nil {
		return // 目录不存在：一个组都不给
	}
	names := make([]string, 0, len(entries))
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".json") {
			continue
		}
		names = append(names, e.Name())
	}
	sort.Strings(names)
	for _, name := range names {
		sessionLoadACLFile(ses, login, filepath.Join(dir, name))
	}
}

func sessionLoadACLFile(ses *session, login *UciSection, path string) {
	data, err := os.ReadFile(path)
	if err != nil {
		return
	}
	var groups map[string]json.RawMessage
	if err := json.Unmarshal(data, &groups); err != nil {
		return
	}
	// 组名必须**按序**遍历：下面的 append 会把同一 object 的函数名累积成数组，
	// 而 Go 的 map 遍历是随机的——不排序的话 login/get 回包里的 acls 数组顺序
	// 每次都不同（实测三次 sha1 全不同），golden 比对无从稳定。（条目本身是集合，
	// 顺序无语义；排序只是让输出可复现。）
	groupNames := make([]string, 0, len(groups))
	for groupName := range groups {
		groupNames = append(groupNames, groupName)
	}
	sort.Strings(groupNames)
	for _, groupName := range groupNames {
		groupRaw := groups[groupName]
		var group map[string]json.RawMessage
		if err := json.Unmarshal(groupRaw, &group); err != nil {
			continue
		}
		for _, perm := range []string{"read", "write"} {
			permRaw, has := group[perm]
			if !has {
				continue
			}
			var permObj map[string]json.RawMessage
			if err := json.Unmarshal(permRaw, &permObj); err != nil {
				continue // 上游要求 TABLE（session.c:1060-1061）
			}
			if !sessionLoginTestPermission(login, perm, groupName) {
				continue
			}
			for scopeName, scopeRaw := range permObj {
				// scope 的值两种形态：表（object → [function…]）或数组（object 列表，
				// 函数名 = 权限名本身）。
				var table map[string][]string
				if err := json.Unmarshal(scopeRaw, &table); err == nil && firstNonSpace(scopeRaw) == '{' {
					for objName, funcs := range table {
						for _, f := range funcs {
							sessionACLGrant(ses, scopeName, objName, f)
						}
					}
					continue
				}
				var list []string
				if err := json.Unmarshal(scopeRaw, &list); err == nil && firstNonSpace(scopeRaw) == '[' {
					for _, o := range list {
						sessionACLGrant(ses, scopeName, o, perm)
					}
				}
			}
			// access-group 元 scope（session.c:1101-1103）
			sessionACLGrant(ses, "access-group", groupName, perm)
		}
	}
}

// sessionLoginTestPermission 对齐 session.c:930-990：
//
//	login == nil（默认会话）→ 只认 "unauthenticated" 组；
//	先看 `!pattern`，命中即拒绝；再看正模式，命中即允许；
//	都没命中且求的是 read → 用 write 再问一遍（write 蕴含 read）。
func sessionLoginTestPermission(login *UciSection, perm, group string) bool {
	if login == nil {
		return group == "unauthenticated"
	}
	for _, o := range login.Options {
		if !o.IsList || o.Name != perm {
			continue
		}
		for _, v := range o.Values {
			if len(v) == 0 || v[0] != '!' {
				continue
			}
			p := strings.TrimSpace(v[1:])
			if len(p) == 0 {
				continue
			}
			if fnmatch(p, group) {
				return false
			}
		}
		for _, v := range o.Values {
			if len(v) == 0 || v[0] == '!' {
				continue
			}
			if fnmatch(v, group) {
				return true
			}
		}
	}
	if perm == "read" {
		return sessionLoginTestPermission(login, "write", group)
	}
	return false
}

// ---------------------------------------------------------------------------
// 会话存储
// ---------------------------------------------------------------------------

func sessionNew(timeout int) *session {
	id, ok := randomHexChecked(sessionSIDLen)
	if !ok {
		return nil
	}
	ses := &session{
		id:      id,
		timeout: timeout,
		data:    map[string]string{},
		acls:    map[string][]aclEntry{},
	}
	ses.touch()
	if sessionStore == nil {
		sessionStore = map[string]*session{}
	}
	sessionStore[ses.id] = ses
	return ses
}

func sessionGet(id string) *session {
	ses, found := sessionStore[id]
	if !found {
		return nil
	}
	if ses.expired() {
		sessionDestroy(ses)
		return nil
	}
	ses.touch()
	return ses
}

func sessionDestroy(ses *session) {
	delete(sessionStore, ses.id)
}

func (s *session) expired() bool {
	if s.timeout <= 0 {
		return false
	}
	return !time.Now().Before(s.expiresAt)
}

func (s *session) touch() {
	if s.timeout > 0 {
		s.expiresAt = time.Now().Add(time.Duration(s.timeout) * time.Second)
	}
}

func sessionPruneExpired() {
	var dead []string
	for id, ses := range sessionStore {
		if ses.expired() {
			dead = append(dead, id)
		}
	}
	for _, id := range dead {
		delete(sessionStore, id)
	}
}

// sessionEnsureDefault 惰性建默认会话（session.c:1380-1390）：只加载 acl.d 里的
// `unauthenticated` 组（rpc_login_test_permission 的 login==NULL 分支）。
func sessionEnsureDefault() {
	if sessionStore == nil {
		sessionStore = map[string]*session{}
	}
	if _, found := sessionStore[SessionDefaultID]; found {
		return
	}
	ses := &session{
		id:      SessionDefaultID,
		timeout: 0,
		data:    map[string]string{},
		acls:    map[string][]aclEntry{},
	}
	sessionLoadACLs(ses, nil)
	sessionStore[ses.id] = ses
}

// ---------------------------------------------------------------------------
// ACL 匹配
// ---------------------------------------------------------------------------

// SessionAccessUbus 是 HTTP 侧前置 ACL 校验（uh_ubus_allowed）用的入口：
// sid 取不到会话 → false（fail-closed）。
func SessionAccessUbus(sid, object, function string) bool {
	sessionMu.Lock()
	defer sessionMu.Unlock()

	sessionEnsureDefault()
	ses := sessionGet(sid)
	if ses == nil {
		return false
	}
	// `:subscribe` 是订阅用的伪方法名：有效登录会话即可订阅，默认会话拒绝。
	if function == ":subscribe" {
		return sid != SessionDefaultID
	}
	return sessionACLAllowed(ses, "ubus", object, function)
}

// sessionAccess 是 ubus 对象内部方法用的 ACL 查询入口（scope 由调用方给：file/uci/…），
// 对应 Odin 版各对象里的 `session_acl_allowed(ses, scope, …)`。fail-closed。
func sessionAccess(sid, scope, object, function string) bool {
	sessionMu.Lock()
	defer sessionMu.Unlock()
	sessionEnsureDefault()
	ses := sessionGet(sid)
	if ses == nil {
		return false
	}
	return sessionACLAllowed(ses, scope, object, function)
}

// SessionSelfService：session 对象的 get/set/unset/destroy 由对象自己按 sid 鉴权，
// 不走 ubus scope 的 ACL（否则 acl.d 里没人授予 session.get，LuCI 读不到自己的会话）。
func SessionSelfService(sid, method string) bool {
	switch method {
	case "get", "set", "unset", "destroy":
	default:
		return false
	}
	if sid == "" || sid == SessionDefaultID {
		return false
	}
	sessionMu.Lock()
	defer sessionMu.Unlock()
	sessionEnsureDefault()
	return sessionGet(sid) != nil
}

// SessionACLLevel 见 Backend 接口 / ACLLevel 的说明。
func SessionACLLevel(sid string, groups []string) ACLLevel {
	if len(groups) == 0 {
		return ACLWritable
	}

	sessionMu.Lock()
	defer sessionMu.Unlock()
	sessionEnsureDefault()

	ses := sessionGet(sid)
	if ses == nil {
		return ACLMissing
	}
	entries, found := ses.acls["access-group"]
	if !found {
		return ACLMissing
	}

	writable := false
	for _, g := range groups {
		read := aclGroupHas(entries, g, "read")
		write := aclGroupHas(entries, g, "write")
		if !read && !write {
			return ACLMissing
		}
		if write {
			writable = true
		}
	}
	if writable {
		return ACLWritable
	}
	return ACLReadOnly
}

func aclGroupHas(entries []aclEntry, group, perm string) bool {
	for _, e := range entries {
		if e.object == group && e.function == perm {
			return true
		}
	}
	return false
}

func sessionACLAllowed(ses *session, scope, object, function string) bool {
	entries, found := ses.acls[scope]
	if !found {
		return false
	}
	for _, e := range entries {
		if !prefixMatch(e.object, object, e.sortLen) {
			continue
		}
		if fnmatch(e.object, object) && fnmatch(e.function, function) {
			return true
		}
	}
	return false
}

func sessionACLGrant(ses *session, scope, object, function string) {
	entries := ses.acls[scope]
	for _, e := range entries {
		if e.object == object && e.function == function {
			ses.acls[scope] = entries
			return // 已存在，不动（session.c:446-450）
		}
	}
	entries = append(entries, aclEntry{object: object, function: function, sortLen: aclIDLen(object)})
	ses.acls[scope] = entries
}

func sessionACLRevoke(ses *session, scope, object, function string) {
	entries, found := ses.acls[scope]
	if !found {
		return
	}
	kept := entries[:0]
	for _, e := range entries {
		if e.object == object && e.function == function {
			continue
		}
		kept = append(kept, e)
	}
	if len(kept) == 0 {
		delete(ses.acls, scope)
		return
	}
	ses.acls[scope] = kept
}

// aclIDLen：到第一个通配符为止的前缀长度（session.c:426-429 的 uh_id_len）。
func aclIDLen(s string) int {
	for i := 0; i < len(s); i++ {
		switch s[i] {
		case '*', '?', '[':
			return i
		}
	}
	return len(s)
}

func prefixMatch(entryObject, object string, sortLen int) bool {
	if sortLen > len(object) || sortLen > len(entryObject) {
		return false
	}
	return entryObject[:sortLen] == object[:sortLen]
}

// fnmatch（FNM_NOESCAPE）：`*` 任意串、`?` 单字符、`[...]` 字符集。
func fnmatch(pattern, name string) bool {
	pi, ni := 0, 0
	starPi, starNi := -1, -1
	for ni < len(name) {
		if pi < len(pattern) {
			switch pattern[pi] {
			case '*':
				starPi, starNi = pi, ni
				pi++
				continue
			case '?':
				pi++
				ni++
				continue
			case '[':
				matched, nextPi := fnmatchClass(pattern, pi, name[ni])
				if matched {
					pi = nextPi
					ni++
					continue
				}
			default:
				if pattern[pi] == name[ni] {
					pi++
					ni++
					continue
				}
			}
		}
		if starPi >= 0 {
			starNi++
			ni = starNi
			pi = starPi + 1
			continue
		}
		return false
	}
	for pi < len(pattern) && pattern[pi] == '*' {
		pi++
	}
	return pi == len(pattern)
}

// fnmatchClass 处理 `[...]` 的一步。不闭合的 `[` 按字面量处理。
func fnmatchClass(pattern string, start int, c byte) (bool, int) {
	i := start + 1
	if i >= len(pattern) {
		return pattern[start] == c, start + 1
	}
	negate := false
	if pattern[i] == '!' || pattern[i] == '^' {
		negate = true
		i++
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
		i++
	}
	return pattern[start] == c, start + 1
}

// ---------------------------------------------------------------------------
// dump
// ---------------------------------------------------------------------------

func sessionDump(ses *session, withACLs bool) string {
	values := map[string]json.RawMessage{}
	for key, text := range ses.data {
		values[key] = json.RawMessage(text)
	}
	doc := map[string]any{
		"ubus_rpc_session": ses.id,
		"timeout":          ses.timeout,
		"expires":          sessionRemaining(ses),
		"data":             values,
	}
	if withACLs {
		doc["acls"] = ses.aclsTable()
	}
	return marshalNoEscape(doc)
}

func sessionRemaining(ses *session) int64 {
	if ses.timeout <= 0 {
		return 0
	}
	now := time.Now()
	if !now.Before(ses.expiresAt) {
		return 0
	}
	return int64(ses.expiresAt.Sub(now).Seconds())
}

// aclsTable 是 scope → object → [function…]（session.c:188-222）。
func (s *session) aclsTable() map[string]map[string][]string {
	out := map[string]map[string][]string{}
	for scope, entries := range s.acls {
		objects := map[string][]string{}
		for _, e := range entries {
			objects[e.object] = append(objects[e.object], e.function)
		}
		out[scope] = objects
	}
	return out
}

func sessionDumpACLsJSON(ses *session) string {
	return marshalNoEscape(ses.aclsTable())
}

// ---------------------------------------------------------------------------
// 小工具
// ---------------------------------------------------------------------------

func sessionStatusOK() int { return StatusOK }

func sectionOptionString(s *UciSection, name string) (string, bool) {
	for _, o := range s.Options {
		if o.Name != name || o.IsList || len(o.Values) == 0 {
			continue
		}
		return o.Values[0], true
	}
	return "", false
}

func paramStr(params map[string]json.RawMessage, key string) (string, bool) {
	raw, has := params[key]
	if !has {
		return "", false
	}
	return rawStr(raw)
}

func paramInt(params map[string]json.RawMessage, key string) (int, bool) {
	raw, has := params[key]
	if !has {
		return 0, false
	}
	var n float64
	if err := json.Unmarshal(raw, &n); err != nil {
		return 0, false
	}
	return int(n), true
}

func paramObject(params map[string]json.RawMessage, key string) (map[string]json.RawMessage, bool) {
	raw, has := params[key]
	if !has || firstNonSpace(raw) != '{' {
		return nil, false
	}
	var obj map[string]json.RawMessage
	if err := json.Unmarshal(raw, &obj); err != nil {
		return nil, false
	}
	return obj, true
}

func rawStr(raw json.RawMessage) (string, bool) {
	if firstNonSpace(raw) != '"' {
		return "", false
	}
	var s string
	if err := json.Unmarshal(raw, &s); err != nil {
		return "", false
	}
	return s, true
}

func firstNonSpace(b []byte) byte {
	for _, c := range b {
		switch c {
		case ' ', '\t', '\r', '\n':
			continue
		}
		return c
	}
	return 0
}

// quoteJSON 把一个字符串编码成 JSON 文本（用于存进 ses.data）。
func quoteJSON(s string) string {
	b, err := json.Marshal(s)
	if err != nil {
		return `""`
	}
	return string(b)
}

// randomHex 取 n 个十六进制字符（n/2 字节的 /dev/urandom 等价物）。
func randomHex(n int) string {
	out, _ := randomHexChecked(n)
	return out
}

func randomHexChecked(n int) (string, bool) {
	buf := make([]byte, (n+1)/2)
	if _, err := rand.Read(buf); err != nil {
		return "", false
	}
	return hex.EncodeToString(buf)[:n], true
}

// marshalNoEscape 序列化并关闭 HTML 转义（与 handlers 的 mustJSON 同义）。
func marshalNoEscape(v any) string {
	var b strings.Builder
	enc := json.NewEncoder(&b)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil {
		return "null"
	}
	return strings.TrimRight(b.String(), "\n")
}
