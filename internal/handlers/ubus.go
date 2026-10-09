package handlers

import (
	"encoding/json"
	"io"
	"net/http"
	"sort"
	"strings"
	"time"

	"github.com/azhai/molly/internal/backend"
)

// /ubus —— HTTP 侧的 ubus 转发，逐条对齐上游 uhttpd 的 ubus 插件（ubus.c）。
//
// 覆盖的协议面（对齐 Odin 版 src/handlers/ubus_http.odin）：
//
//	GET  /ubus/list、/ubus/list/<path>   列对象/签名
//	GET  /ubus/subscribe/<path>          SSE：ACL ":subscribe" → 订阅 → text/event-stream
//	POST /ubus                           旧式：body 是 JSON-RPC，method 为 "call"/"list"
//	POST /ubus/call/<path>               新式：method 直接是 ubus 方法名
//
// 会话来源：新式是 `Authorization: Bearer <sid>` 头，旧式是 params[0]；
// 两者都没有时回退到 32 个 0 的哨兵 sid。
//
// 错误一律走 HTTP 200 + JSON-RPC 信封（上游在 invoke 之前就把 200 头发出去了）。
// 例外是 GET list 的 500（回 ubus 自己的错误码）与订阅失败（回 posix/ubus 码的表）。
//
// P3-6 起 call 先走 uhttpd 那道前置 ACL 校验（不通过 → -32002），见 invoke。
const (
	ubusListPath   = "/ubus/list"
	ubusListPrefix = "/ubus/list/"

	ubusCallPrefix = "/ubus/call/"

	ubusSubscribePrefix = "/ubus/subscribe/"

	// 上游 ubus.c:38 的 UH_UBUS_DEFAULT_SID：未认证会话的哨兵值。
	ubusDefaultSID = "00000000000000000000000000000000"

	// 上游 ubus.c:382 的伪方法名：订阅的权限点与 call 的方法名不在一个命名空间。
	ubusSubscribeFn = ":subscribe"

	// EACCES（上游订阅被拒时回的是 posix 负码 -EACCES，ubus.c:258/:384）。
	ubusEACCES = 13

	// SSE 心跳间隔。上游没有这个值——它是 molly 为了长连接能穿过代理加的
	// （对应 Odin 版 ubus_sse.odin 的 SSE_HEARTBEAT_MS）。
	sseHeartbeat = 30 * time.Second
)

// JSON-RPC 错误码（上游 ubus.c:80-106 的 json_errors 表）。
type rpcError int

const (
	rpcParse rpcError = iota
	rpcRequest
	rpcMethod
	rpcParams
	rpcInternal
	rpcObject
	rpcAccess
)

// 下标必须与 rpcError 的顺序一一对应。
var rpcErrorDefs = [...]struct {
	code int
	msg  string
}{
	{-32700, "Parse error"},
	{-32600, "Invalid request"},
	{-32601, "Method not found"},
	{-32602, "Invalid parameters"},
	{-32603, "Internal error"},
	{-32000, "Object not found"},
	{-32002, "Access denied"},
}

// ServeUbus 处理 /ubus。
//
// 调用约定：path 是 httpx.NormalizePath 的产物（已剥查询串、无 .. 段、尾部 '/'
// 已被压掉）。所以 "/ubus/" 与 "/ubus" 在这里长得一样，与上游「/foo 和 /foo/
// 都算旧式」的处理等价。
func ServeUbus(w http.ResponseWriter, r *http.Request, path string, be backend.Backend) {
	switch r.Method {
	case http.MethodGet:
		ubusGet(w, r, path, be)
	case http.MethodPost:
		ubusPost(w, r, path, be)
	case http.MethodOptions:
		// 上游对 OPTIONS 回 200 + application/json + Content-Length: 0（CORS 预检）
		Respond(w, r, http.StatusOK, "", "application/json")
	default:
		// 上游的 ubus 插件只认 GET / POST / OPTIONS，其余一律 400
		Respond(w, r, http.StatusBadRequest, "invalid request\n", "text/plain; charset=utf-8")
	}
}

func ubusGet(w http.ResponseWriter, r *http.Request, path string, be backend.Backend) {
	switch {
	case path == ubusListPath:
		// 无 path → 列全部对象
		ubusList(w, r, "", be)
		return
	case strings.HasPrefix(path, ubusListPrefix):
		ubusList(w, r, path[len(ubusListPrefix):], be)
		return
	case strings.HasPrefix(path, ubusSubscribePrefix):
		// P3-7：ACL `:subscribe` → 订阅 → text/event-stream（见 ubusSubscribe）。
		ubusSubscribe(w, r, path[len(ubusSubscribePrefix):], be)
		return
	}
	// 上游对 GET /ubus 与其它 /ubus/<x> 都回 404，且不带 body
	Respond(w, r, http.StatusNotFound, "", "")
}

func ubusList(w http.ResponseWriter, r *http.Request, path string, be backend.Backend) {
	body, errCode, ok := be.ListObjects(path)
	if !ok {
		// 上游 ubus.c:210-213：500 + {"code":<ubus errno>,"message":<ubus_strerror>}
		// ——注意这里不是 JSON-RPC 错误码，而是 ubus 自己的状态码。
		Respond(w, r, http.StatusInternalServerError,
			mustJSON(map[string]any{"code": errCode, "message": backend.UbusErrorMessage(errCode)}),
			"application/json")
		return
	}
	jsonResponse(w, r, body)
}

// ---------------------------------------------------------------------------
// GET /ubus/subscribe/<对象路径> —— SSE（P3-7）
// ---------------------------------------------------------------------------

// ubusSubscribe 对齐上游 ubus.c:373-424 与 Odin 版 ubus_sse.odin：
//
//  1. sid 从 `Authorization: Bearer` 取；
//  2. ACL 点是伪方法 ":subscribe"；不过 → 200 + json +
//     {"code":-13,"message":"Permission denied"}（posix **负码**，不是 JSON-RPC 的 -32002）；
//  3. 对象不存在 → 200 + json + {"code":<ubus 码>,"message":…}；
//  4. 订阅失败（容量满）→ 同样的 200 + json，码取 UNKNOWN_ERROR(9)；
//  5. 成功 → 200 + text/event-stream，帧 `event: <method>\ndata: <json>\n\n`，
//     每 sseHeartbeat 发一条注释帧心跳，客户端断开即收尾。
//
// 差异（对应 Odin 版记录）：上游走 chunked（ops->chunk_printf）；Go 侧不设
// Content-Length，net/http 对 HTTP/1.1 自动分块，语义等价。
func ubusSubscribe(w http.ResponseWriter, r *http.Request, path string, be backend.Backend) {
	sid := authSID(r)
	if !be.SessionAccessUbus(sid, path, ubusSubscribeFn) {
		subscribeError(w, r, -ubusEACCES, "Permission denied")
		return
	}
	// 对象必须存在（上游 ubus_lookup_id，ubus.c:397-399）：ACL 在 lookup 之前。
	if _, errCode, ok := be.ListObjects(path); !ok {
		subscribeError(w, r, errCode, backend.UbusErrorMessage(errCode))
		return
	}
	ch, unsub, ok := backend.Subscribe(path)
	if !ok {
		subscribeError(w, r, backend.StatusUnknownError,
			backend.UbusErrorMessage(backend.StatusUnknownError))
		return
	}
	defer unsub()

	h := w.Header()
	h.Set("Content-Type", "text/event-stream")
	h.Set("Cache-Control", "no-cache")
	// 与 Odin 版一致：不发 Date / Server（置 nil 抑制 net/http 自动补的 Date）。
	h["Date"] = nil
	w.WriteHeader(http.StatusOK)
	flusher, _ := w.(http.Flusher)
	if flusher != nil {
		flusher.Flush()
	}

	ticker := time.NewTicker(sseHeartbeat)
	defer ticker.Stop()
	for {
		select {
		case <-r.Context().Done():
			return
		case ev, open := <-ch:
			if !open {
				return
			}
			if _, err := io.WriteString(w, sseFrame(ev)); err != nil {
				return
			}
			if flusher != nil {
				flusher.Flush()
			}
		case <-ticker.C:
			if _, err := io.WriteString(w, ": heartbeat\n\n"); err != nil {
				return
			}
			if flusher != nil {
				flusher.Flush()
			}
		}
	}
}

// sseFrame 一帧 SSE（上游 ubus.c:345 的 `event: %s\ndata: %s\n\n`）。
func sseFrame(ev backend.Event) string {
	return "event: " + ev.Method + "\ndata: " + ev.Data + "\n\n"
}

// subscribeError 订阅失败的回复：200 + application/json + {"code":<码>,"message":"…"}
// （上游 uh_ubus_error，ubus.c:247-264：posix 错误传负码，ubus 错误传正码）。
func subscribeError(w http.ResponseWriter, r *http.Request, code int, message string) {
	Respond(w, r, http.StatusOK,
		mustJSON(map[string]any{"code": code, "message": message}), "application/json")
}

func ubusPost(w http.ResponseWriter, r *http.Request, path string, be backend.Backend) {
	body, err := io.ReadAll(r.Body)
	if err != nil {
		// 读请求体失败：与解析错误同样处理（Odin 版没有这条路径，Go 侧兜底）。
		jsonResponse(w, r, rpcErrorJSON(rpcParse, "null"))
		return
	}
	if path == UBUSPrefix {
		jsonResponse(w, r, rpcLegacy(body, be))
		return
	}
	if strings.HasPrefix(path, ubusCallPrefix) {
		// 会话来自 Authorization 头，不是 body（ubus.c:920）
		sid := authSID(r)
		jsonResponse(w, r, rpcRest(path[len(ubusCallPrefix):], sid, body, be))
		return
	}
	// 上游：POST /ubus/<非 call> → 404 空正文（ubus.c:928-931）
	Respond(w, r, http.StatusNotFound, "", "")
}

func jsonResponse(w http.ResponseWriter, r *http.Request, body string) {
	Respond(w, r, http.StatusOK, body, "application/json")
}

// authSID 对齐上游 uh_ubus_get_auth（ubus.c:120-137）：只认 authorization 头，
// 且值必须以 "Bearer " 开头（大小写不敏感）；否则回退到哨兵 sid。不做任何 trim。
func authSID(r *http.Request) string {
	v := r.Header.Get("Authorization")
	if len(v) >= 7 && strings.EqualFold(v[:7], "Bearer ") {
		return v[7:]
	}
	return ubusDefaultSID
}

// ---------------------------------------------------------------------------
// 旧式 POST /ubus
// ---------------------------------------------------------------------------

// rpcLegacy 对齐上游 uh_ubus_data_done（ubus.c:844-859）：正文是对象走单请求，
// 是数组走批请求，其它一律 parse error。
func rpcLegacy(body []byte, be backend.Backend) string {
	var root json.RawMessage
	if err := json.Unmarshal(body, &root); err != nil {
		return rpcErrorJSON(rpcParse, "null")
	}

	switch firstByte(root) {
	case '{':
		obj, ok := decodeObject(root)
		if !ok {
			return rpcErrorJSON(rpcParse, "null")
		}
		return legacyOne(obj, be)
	case '[':
		var arr []json.RawMessage
		if err := json.Unmarshal(root, &arr); err != nil {
			return rpcErrorJSON(rpcParse, "null")
		}
		// 上游 uh_ubus_init_batch：元素之间插 ','。
		var b strings.Builder
		b.WriteByte('[')
		for i, el := range arr {
			if i > 0 {
				b.WriteByte(',')
			}
			obj, ok := decodeObject(el)
			if ok {
				b.WriteString(legacyOne(obj, be))
			} else {
				b.WriteString(rpcErrorJSON(rpcParse, "null"))
			}
		}
		b.WriteByte(']')
		return b.String()
	default:
		// 既不是对象也不是数组（字符串/数字/null）→ ERROR_PARSE
		return rpcErrorJSON(rpcParse, "null")
	}
}

// legacyOne 处理旧式正文里的一个 JSON-RPC 请求对象（上游
// uh_ubus_handle_request_object，ubus.c:771-827）。
func legacyOne(obj map[string]json.RawMessage, be backend.Backend) string {
	idJSON := rpcIDJSON(obj)

	method, mOK := rpcStr(obj, "method")
	ver, vOK := rpcStr(obj, "jsonrpc")
	// 上游 parse_json_rpc（ubus.c:696-723）：jsonrpc 必须是 "2.0"，method 必须存在。
	// 不满足时 err 还是初值 ERROR_PARSE，所以这里回 -32700 而不是 -32600。
	if !mOK || !vOK || ver != "2.0" {
		return rpcErrorJSON(rpcParse, idJSON)
	}

	switch method {
	case "call":
		// 上游 parse_call_params（ubus.c:725-754）：params 必须是四元数组
		// [sid, 对象, 方法, 参数表]，四项缺一即 parse error。
		params, has := obj["params"]
		if !has || firstByte(params) != '[' {
			return rpcErrorJSON(rpcParse, idJSON)
		}
		var arr []json.RawMessage
		if err := json.Unmarshal(params, &arr); err != nil || len(arr) < 4 {
			return rpcErrorJSON(rpcParse, idJSON)
		}
		sid, sOK := rawStr(arr[0])
		path, pOK := rawStr(arr[1])
		fn, fOK := rawStr(arr[2])
		if !sOK || !pOK || !fOK || firstByte(arr[3]) != '{' {
			return rpcErrorJSON(rpcParse, idJSON)
		}
		return invoke(path, fn, true, arr[3], sid, idJSON, true, be)

	case "list":
		params, has := obj["params"]
		return legacyList(params, has, idJSON, be)
	}
	// method 既不是 "call" 也不是 "list" → ERROR_METHOD（ubus.c:815-818）
	return rpcErrorJSON(rpcMethod, idJSON)
}

// legacyList 处理旧式 method:"list"（上游 uh_ubus_send_list，ubus.c:658-694）。
//
// params 不是数组（含没有 params、含 null）→ result 是**对象路径数组**；
// params 是数组 → result 是**详细表** {"<路径>":{"<方法>":{…}}}，数组里查不到的
// 路径直接忽略（上游根本没看 ubus_lookup 的返回值）。
func legacyList(params json.RawMessage, has bool, idJSON string, be backend.Backend) string {
	if !has || firstByte(params) != '[' {
		return `{"jsonrpc":"2.0","id":` + idJSON + `,"result":` + listPathsJSON(be) + `}`
	}
	var arr []json.RawMessage
	if err := json.Unmarshal(params, &arr); err != nil {
		return `{"jsonrpc":"2.0","id":` + idJSON + `,"result":` + listPathsJSON(be) + `}`
	}

	merged := make(map[string]json.RawMessage, len(arr))
	for _, el := range arr {
		path, ok := rawStr(el)
		if !ok {
			// 上游直接把数组元素当 C 字符串用，非字符串元素我们跳过
			continue
		}
		sigText, _, ok := be.ListObjects(path)
		if !ok || firstByte([]byte(sigText)) != '{' {
			continue
		}
		merged[path] = json.RawMessage(sigText)
	}
	// json.Marshal 对 map 按键排序，等价于上游的 sort_maps_by_key。
	return `{"jsonrpc":"2.0","id":` + idJSON + `,"result":` + mustJSON(merged) + `}`
}

// listPathsJSON 是全部对象路径，字典序（上游的顺序来自 ubus 的 avl 树，也有序）。
func listPathsJSON(be backend.Backend) string {
	text, _, ok := be.ListObjects("")
	if !ok {
		// 上游不看 ubus_lookup 的返回值，失败就是空数组
		return "[]"
	}
	table, ok := decodeObject(json.RawMessage(text))
	if !ok {
		return "[]"
	}
	paths := make([]string, 0, len(table))
	for p := range table {
		paths = append(paths, p)
	}
	sort.Strings(paths)
	return mustJSON(paths)
}

// ---------------------------------------------------------------------------
// 新式 POST /ubus/call/<path>
// ---------------------------------------------------------------------------

// rpcRest 对齐上游 uh_ubus_call（ubus.c:861-905）：method 直接就是 ubus 方法名，
// 对象路径来自 URL，params 是参数表（可以完全没有）。
func rpcRest(path, sid string, body []byte, be backend.Backend) string {
	var root json.RawMessage
	if err := json.Unmarshal(body, &root); err != nil {
		return rpcErrorJSON(rpcParse, "null")
	}
	obj, ok := decodeObject(root)
	if !ok {
		return rpcErrorJSON(rpcParse, "null")
	}
	idJSON := rpcIDJSON(obj)

	method, mOK := rpcStr(obj, "method")
	ver, vOK := rpcStr(obj, "jsonrpc")
	if !mOK || !vOK || ver != "2.0" {
		return rpcErrorJSON(rpcParse, idJSON)
	}

	params, has := obj["params"]
	return invoke(path, method, has, params, sid, idJSON, false, be)
}

// ---------------------------------------------------------------------------
// 一次 ubus 调用（旧式与新式共用的尾巴）
// ---------------------------------------------------------------------------

// hasParams 要单独传：JSON 的 null 与「没有 params 字段」要分开——前者是 -32602，
// 后者是空参数表。legacy 决定 result 的形状（旧式是 [ret,{…}] 数组）。
func invoke(path, method string, hasParams bool, params json.RawMessage,
	sid, idJSON string, legacy bool, be backend.Backend) string {

	// 上游顺序：1) ubus_lookup_id 找不到对象 → -32000；2) ACL → -32002；
	// 3) 参数表校验 → -32602。
	if _, _, ok := be.ListObjects(path); !ok {
		return rpcErrorJSON(rpcObject, idJSON)
	}
	// 2) 前置 ACL（uhttpd 的 uh_ubus_allowed → session.access）：scope "ubus"、
	// object=对象名、function=方法名；不过 → -32002，fail-closed。
	// 例外：session 对象对自己的会话是自服务的（get/set/unset/destroy 由对象按 sid
	// 鉴权）——不放行的话 acl.d 里没人授予 session.get，登录后读不到会话。
	selfService := path == "session" && be.SessionSelfService(sid, method)
	if !selfService && !be.SessionAccessUbus(sid, path, method) {
		return rpcErrorJSON(rpcAccess, idJSON)
	}

	paramsJSON := ""
	if hasParams {
		table, ok := decodeObject(params)
		if !ok {
			// 上游 uh_ubus_send_request（ubus.c:575-576）：非表一律 -32602。null 也走这条。
			return rpcErrorJSON(rpcParams, idJSON)
		}
		if _, has := table["ubus_rpc_session"]; has {
			// 上游 ubus.c:578-582：客户端自带 ubus_rpc_session 直接拒绝，
			// 免得覆盖 molly 追加的那一个（会话固定）。
			return rpcErrorJSON(rpcParams, idJSON)
		}
		paramsJSON = mustJSON(table)
	}

	res := be.CallObject(path, method, paramsJSON, sid)
	switch res.Outcome {
	case backend.OutcomeObjectNotFound:
		return rpcErrorJSON(rpcObject, idJSON)
	case backend.OutcomeInternal:
		return rpcErrorJSON(rpcInternal, idJSON)
	}

	if res.Ret != 0 {
		// 上游 uh_ubus_request_cb（ubus.c:495-503）：ubus 返回码进 error.code，
		// 文案取 ubus_strerror —— 不是 JSON-RPC 的 -32xxx 表。
		payload := mustJSON(map[string]any{"code": res.Ret, "message": backend.UbusErrorMessage(res.Ret)})
		return `{"jsonrpc":"2.0","id":` + idJSON + `,"error":` + payload + `}`
	}

	if legacy {
		// 旧式 result 恒为数组，空回复也是（ubus.c:474-491）
		if res.Reply != "" {
			return `{"jsonrpc":"2.0","id":` + idJSON + `,"result":[0,` + res.Reply + `]}`
		}
		return `{"jsonrpc":"2.0","id":` + idJSON + `,"result":[0]}`
	}
	if res.Reply != "" {
		return `{"jsonrpc":"2.0","id":` + idJSON + `,"result":` + res.Reply + `}`
	}
	// 无回复数据：上游加一个 UNSPEC 字段，格式化出来是 null（ubus.c:512）
	return `{"jsonrpc":"2.0","id":` + idJSON + `,"result":null}`
}

// ---------------------------------------------------------------------------
// JSON 小工具
// ---------------------------------------------------------------------------

func rpcErrorJSON(k rpcError, idJSON string) string {
	def := rpcErrorDefs[k]
	payload := mustJSON(map[string]any{"code": def.code, "message": def.msg})
	return `{"jsonrpc":"2.0","id":` + idJSON + `,"error":` + payload + `}`
}

// rpcStr 从 JSON 对象里取字符串字段；类型不匹配等于「没有这个字段」。
func rpcStr(obj map[string]json.RawMessage, key string) (string, bool) {
	raw, has := obj[key]
	if !has {
		return "", false
	}
	return rawStr(raw)
}

func rawStr(raw json.RawMessage) (string, bool) {
	if firstByte(raw) != '"' {
		return "", false
	}
	var s string
	if err := json.Unmarshal(raw, &s); err != nil {
		return "", false
	}
	return s, true
}

// rpcIDJSON 对齐上游 uh_ubus_init_json_rpc_response：有 id 就原样回，没有（或 null）
// 就补一个格式化出来是 null 的字段。
func rpcIDJSON(obj map[string]json.RawMessage) string {
	raw, has := obj["id"]
	if !has || bytesEqualFold(raw, "null") {
		return "null"
	}
	return string(raw)
}

func decodeObject(raw json.RawMessage) (map[string]json.RawMessage, bool) {
	if firstByte(raw) != '{' {
		return nil, false
	}
	var obj map[string]json.RawMessage
	if err := json.Unmarshal(raw, &obj); err != nil {
		return nil, false
	}
	return obj, true
}

// firstByte 返回跳过前后空白后的第一个有效字节，用来判断 JSON 值的容器类型。
func firstByte(b []byte) byte {
	for _, c := range b {
		switch c {
		case ' ', '\t', '\r', '\n':
			continue
		}
		return c
	}
	return 0
}

func bytesEqualFold(b []byte, s string) bool {
	return strings.EqualFold(strings.TrimSpace(string(b)), s)
}

// mustJSON 序列化并关闭 HTML 转义（Odin 的 json.unparse 不做转义），失败时回 "null"。
// map 的键会被排序，等价于 Odin 的 sort_maps_by_key。
func mustJSON(v any) string {
	var b strings.Builder
	enc := json.NewEncoder(&b)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil {
		return "null"
	}
	return strings.TrimRight(b.String(), "\n")
}
