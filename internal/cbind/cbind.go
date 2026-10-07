//go:build linux && cgo

// Package cbind —— libubus / libubox(blobmsg) / libuci / libc 的 cgo 封装。
//
// 与 Odin 版 src/backend/bindings/*.odin + linux.odin 的 C 侧一一对应，但边界收得更紧：
// **所有 blob_attr / blob_buf 操作、C 回调、malloc/free 都留在 shim.c 里**，Go 侧只看
// JSON 文本与整数状态码。这样 Go 代码不必手抄 C 结构体布局（Odin 手抄是因为它绑 C 不便）。
//
// 交叉编译（环境变量给 sysroot，不进 #cgo —— cgo 会报 invalid flag）：
//
//	CC="zig cc -target aarch64-linux-musl"
//	CGO_CFLAGS="--sysroot=$SYSROOT -I$SYSROOT/usr/include"
//	CGO_LDFLAGS="--sysroot=$SYSROOT"
//
// 本包只在 linux&&cgo 下编译；linux&&!cgo 由 fallback.go 给同签名空实现，
// 保证 `CGO_ENABLED=0 GOOS=linux go build ./...` 的类型检查也能过。

package cbind

/*
#cgo CFLAGS: -I${SRCDIR}
#cgo linux LDFLAGS: -L/usr/lib -luci -lubus -lblobmsg_json -lubox
#include <stdlib.h>
#include "shim.h"
*/
import "C"

import (
	"encoding/json"
	"sync"
	"unsafe"
)

// ubus 调用超时（毫秒），与 Odin 的 UBUS_TIMEOUT_MS 一致（linux.odin:45）。
const timeoutMS = 30000

// ---------------------------------------------------------------------------
// 客户端
// ---------------------------------------------------------------------------

// Ctx 是一条 ubus 连接。零值为未连接；**非线程安全**，调用方自己加锁
// （C 侧复用了全局 blob_buf，且 libubus 的同步 invoke 会 poll ctx->sock）。
type Ctx struct {
	p *C.struct_ubus_context
}

// Connect 连 ubusd。socketPath 为空表示用库内默认 socket。
func Connect(socketPath string) *Ctx {
	var cpath *C.char
	if socketPath != "" {
		cpath = C.CString(socketPath)
		defer C.molly_free(unsafe.Pointer(cpath))
	}
	p := C.molly_ubus_connect(cpath)
	if p == nil {
		return nil
	}
	return &Ctx{p: p}
}

// Free 关闭连接。
func (c *Ctx) Free() {
	if c == nil || c.p == nil {
		return
	}
	C.molly_ubus_free(c.p)
	c.p = nil
}

// Lookup 复刻 GET /ubus/list[/<path>]：path 为空列全部对象（带外层对象名），
// 否则只列该对象（不带外层名）。返回 (JSON 正文, ubus 状态码)。
func (c *Ctx) Lookup(path string) (string, int) {
	if c == nil || c.p == nil {
		return "", 10 // StatusConnectionFailed
	}
	var cpath *C.char
	if path != "" {
		cpath = C.CString(path)
		defer C.molly_free(unsafe.Pointer(cpath))
	}
	var out *C.char
	ret := int(C.molly_ubus_lookup(c.p, cpath, &out))
	if ret != 0 {
		return "", ret
	}
	if out == nil {
		return "", 0
	}
	s := C.GoString(out)
	C.molly_free(unsafe.Pointer(out))
	return s, 0
}

// LookupID 找对象 id。返回 (id, ubus 状态码)。
func (c *Ctx) LookupID(path string) (uint32, int) {
	if c == nil || c.p == nil {
		return 0, 10
	}
	cpath := C.CString(path)
	defer C.molly_free(unsafe.Pointer(cpath))
	var id C.uint
	ret := int(C.molly_ubus_lookup_id(c.p, cpath, &id))
	return uint32(id), ret
}

// Invoke 同步调用。返回 (回复 JSON, ubus 状态码)；回复为空表示「无数据」。
// 参数解析失败与远端 INVALID_ARGUMENT 都返回 2，由调用方翻成 Internal（与 Odin 一致）。
func (c *Ctx) Invoke(id uint32, method, paramsJSON, sid string) (string, int) {
	if c == nil || c.p == nil {
		return "", 10
	}
	cmethod := C.CString(method)
	defer C.molly_free(unsafe.Pointer(cmethod))

	var cparams *C.char
	if paramsJSON != "" {
		cparams = C.CString(paramsJSON)
		defer C.molly_free(unsafe.Pointer(cparams))
	}
	var csid *C.char
	if sid != "" {
		csid = C.CString(sid)
		defer C.molly_free(unsafe.Pointer(csid))
	}

	var out *C.char
	ret := int(C.molly_ubus_invoke(c.p, C.uint(id), cmethod, cparams, csid, C.int(timeoutMS), &out))
	if ret != 0 {
		return "", ret
	}
	if out == nil {
		return "", 0
	}
	s := C.GoString(out)
	C.molly_free(unsafe.Pointer(out))
	return s, 0
}

// ---------------------------------------------------------------------------
// 服务端
// ---------------------------------------------------------------------------

// Handler 是入站 ubus 调用的 Go 侧实现：返回 (ubus 状态码, 回复 JSON)。
// status != 0 时不回数据，状态码由 libubus 交给调用方。
type Handler func(obj, method, paramsJSON string) (int, string)

var (
	handlerMu sync.RWMutex
	handler   Handler
	// serverSocket 长期持有 C 串（服务线程读它，不能随函数返回释放）。
	serverSocket *C.char
)

// SetHandler 注册入站调用的 Go 实现（StartServer 之前调用）。
func SetHandler(h Handler) {
	handlerMu.Lock()
	handler = h
	handlerMu.Unlock()
}

func currentHandler() Handler {
	handlerMu.RLock()
	defer handlerMu.RUnlock()
	return handler
}

// StartServer 起 ubus 服务线程并注册 molly 自有对象。socketPath 为空用默认 socket。
// 返回 0 成功。
func StartServer(socketPath string) int {
	if serverSocket == nil && socketPath != "" {
		serverSocket = C.CString(socketPath)
	}
	return int(C.molly_ubus_start_server(serverSocket))
}

// StopServer 停止服务线程（进程退出用）。
func StopServer() { C.molly_ubus_stop_server() }

// ---------------------------------------------------------------------------
// uci（读）
// ---------------------------------------------------------------------------

// UCISections 返回一个 config 的全部 section（JSON 数组文本）。savedir 为空用默认。
func UCISections(config, savedir string) (string, int) {
	cconfig := C.CString(config)
	defer C.molly_free(unsafe.Pointer(cconfig))
	var csavedir *C.char
	if savedir != "" {
		csavedir = C.CString(savedir)
		defer C.molly_free(unsafe.Pointer(csavedir))
	}
	var out *C.char
	ret := int(C.molly_uci_sections(cconfig, csavedir, &out))
	if ret != 0 {
		return "", ret
	}
	if out == nil {
		return "", 0
	}
	s := C.GoString(out)
	C.molly_free(unsafe.Pointer(out))
	return s, 0
}

// UCIListConfigs 返回 /etc/config/* 的 JSON 字符串数组。
func UCIListConfigs() (string, int) {
	var out *C.char
	ret := int(C.molly_uci_list_configs(&out))
	if ret != 0 {
		return "", ret
	}
	if out == nil {
		return "", 0
	}
	s := C.GoString(out)
	C.molly_free(unsafe.Pointer(out))
	return s, 0
}

// UCIDelta 返回一个 config 的 delta（该会话 savedir 下的未提交改动）的 JSON 数组文本。
func UCIDelta(sid, config string) (string, int) {
	var csid *C.char
	if sid != "" {
		csid = C.CString(sid)
		defer C.molly_free(unsafe.Pointer(csid))
	}
	cconfig := C.CString(config)
	defer C.molly_free(unsafe.Pointer(cconfig))

	var out *C.char
	ret := int(C.molly_uci_delta(csid, cconfig, &out))
	if ret != 0 {
		return "", ret
	}
	if out == nil {
		return "", 0
	}
	s := C.GoString(out)
	C.molly_free(unsafe.Pointer(out))
	return s, 0
}

// ---------------------------------------------------------------------------
// uci 写事务
// ---------------------------------------------------------------------------

// Txn 是一次写事务（uci_load 一次 → 改 → save 一次）的句柄。
//
// 事务期间 libuci 的 ctx/pkg 被独占；调用方（backend）用一把 uci 锁保证同时只有一件事务。
type Txn struct {
	p *C.struct_molly_uci_txn
}

// TxnBegin 开事务。失败返回 nil 与 ubus 状态码（4 载入失败 / 9 其它）。
func TxnBegin(config, savedir string) (*Txn, int) {
	cconfig := C.CString(config)
	defer C.molly_free(unsafe.Pointer(cconfig))
	var csavedir *C.char
	if savedir != "" {
		csavedir = C.CString(savedir)
		defer C.molly_free(unsafe.Pointer(csavedir))
	}

	var status C.int
	p := C.molly_uci_txn_begin(cconfig, csavedir, &status)
	if p == nil {
		return nil, int(status)
	}
	return &Txn{p: p}, int(status)
}

// End 释放事务（unload + free ctx）。
func (t *Txn) End() {
	if t == nil || t.p == nil {
		return
	}
	C.molly_uci_txn_end(t.p)
	t.p = nil
}

// Sections 返回当前包的 section（JSON 数组文本）。
func (t *Txn) Sections() string {
	if t == nil || t.p == nil {
		return ""
	}
	out := C.molly_uci_txn_sections(t.p)
	if out == nil {
		return ""
	}
	s := C.GoString(out)
	C.molly_free(unsafe.Pointer(out))
	return s
}

// SectionExists 报告 section 是否存在。
func (t *Txn) SectionExists(section string) bool {
	if t == nil || t.p == nil {
		return false
	}
	csection := C.CString(section)
	defer C.molly_free(unsafe.Pointer(csection))
	return C.molly_uci_txn_section_exists(t.p, csection) != 0
}

// AddSection 建 section：name 非空用具名（uci_set），为空用匿名（uci_add_section）。
// 返回 (section 名, ubus 状态码)。
func (t *Txn) AddSection(typeName, name string) (string, int) {
	if t == nil || t.p == nil {
		return "", 8
	}
	ctype := C.CString(typeName)
	defer C.molly_free(unsafe.Pointer(ctype))
	var cname *C.char
	if name != "" {
		cname = C.CString(name)
		defer C.molly_free(unsafe.Pointer(cname))
	}

	var out *C.char
	ret := int(C.molly_uci_txn_add_section(t.p, ctype, cname, &out))
	if ret != 0 {
		return "", ret
	}
	if out == nil {
		return "", 0
	}
	s := C.GoString(out)
	C.molly_free(unsafe.Pointer(out))
	return s, 0
}

// OptionState 返回现有 option 的状态：存在与否、是否 list、标量型的值。
func (t *Txn) OptionState(section, option string) (exists, isList bool, value string) {
	if t == nil || t.p == nil {
		return false, false, ""
	}
	csection := C.CString(section)
	defer C.molly_free(unsafe.Pointer(csection))
	coption := C.CString(option)
	defer C.molly_free(unsafe.Pointer(coption))

	var cExists, cIsList C.int
	var cValue *C.char
	C.molly_uci_txn_option_state(t.p, csection, coption, &cExists, &cIsList, &cValue)
	if cValue != nil {
		value = C.GoString(cValue)
		C.molly_free(unsafe.Pointer(cValue))
	}
	return cExists != 0, cIsList != 0, value
}

// Delete 删 option（option 为空删整个 section）。返回 ubus 状态码。
func (t *Txn) Delete(section, option string) int {
	if t == nil || t.p == nil {
		return 8
	}
	csection := C.CString(section)
	defer C.molly_free(unsafe.Pointer(csection))
	var coption *C.char
	if option != "" {
		coption = C.CString(option)
		defer C.molly_free(unsafe.Pointer(coption))
	}
	return int(C.molly_uci_txn_delete(t.p, csection, coption))
}

// Set / AddList 写一个标量 / 往 list 追加一个值。
func (t *Txn) Set(section, option, value string) int {
	return t.write(section, option, value, false)
}

func (t *Txn) AddList(section, option, value string) int {
	return t.write(section, option, value, true)
}

func (t *Txn) write(section, option, value string, list bool) int {
	if t == nil || t.p == nil {
		return 8
	}
	csection := C.CString(section)
	defer C.molly_free(unsafe.Pointer(csection))
	coption := C.CString(option)
	defer C.molly_free(unsafe.Pointer(coption))
	cvalue := C.CString(value)
	defer C.molly_free(unsafe.Pointer(cvalue))
	if list {
		return int(C.molly_uci_txn_add_list(t.p, csection, coption, cvalue))
	}
	return int(C.molly_uci_txn_set(t.p, csection, coption, cvalue))
}

// Rename 重命名 section（option 为空）或 option。
func (t *Txn) Rename(section, option, newName string) int {
	if t == nil || t.p == nil {
		return 8
	}
	csection := C.CString(section)
	defer C.molly_free(unsafe.Pointer(csection))
	var coption *C.char
	if option != "" {
		coption = C.CString(option)
		defer C.molly_free(unsafe.Pointer(coption))
	}
	cnew := C.CString(newName)
	defer C.molly_free(unsafe.Pointer(cnew))
	return int(C.molly_uci_txn_rename(t.p, csection, coption, cnew))
}

// Reorder 把 section 挪到 pos。返回「找到了吗」。
func (t *Txn) Reorder(section string, pos int) bool {
	if t == nil || t.p == nil {
		return false
	}
	csection := C.CString(section)
	defer C.molly_free(unsafe.Pointer(csection))
	return C.molly_uci_txn_reorder(t.p, csection, C.int(pos)) != 0
}

// Save 把改动写进 savedir 的 delta 文件（不碰 /etc/config）。
func (t *Txn) Save() int {
	if t == nil || t.p == nil {
		return 8
	}
	return int(C.molly_uci_txn_save(t.p))
}

// ---------------------------------------------------------------------------
// uci commit / revert / apply
// ---------------------------------------------------------------------------

// UCICommit 提交一个 config（写完清 delta），best-effort 触发 config.change 事件。
func UCICommit(sid, config string) int {
	var csid *C.char
	if sid != "" {
		csid = C.CString(sid)
		defer C.molly_free(unsafe.Pointer(csid))
	}
	cconfig := C.CString(config)
	defer C.molly_free(unsafe.Pointer(cconfig))
	return int(C.molly_uci_commit(csid, cconfig))
}

// UCIRevert 丢弃一个 config 的未提交 delta。
func UCIRevert(sid, config string) int {
	var csid *C.char
	if sid != "" {
		csid = C.CString(sid)
		defer C.molly_free(unsafe.Pointer(csid))
	}
	cconfig := C.CString(config)
	defer C.molly_free(unsafe.Pointer(cconfig))
	return int(C.molly_uci_revert(csid, cconfig))
}

// UCIApplyConfig 提交一个 config；noDelta 时提交看不见任何未提交改动（回滚路径）。
func UCIApplyConfig(config string, noDelta bool) int {
	cconfig := C.CString(config)
	defer C.molly_free(unsafe.Pointer(cconfig))
	nd := C.int(0)
	if noDelta {
		nd = 1
	}
	return int(C.molly_uci_apply_config(cconfig, nd))
}

// ReloadConfig fork/exec /sbin/reload_config（父进程立刻返回）。
func ReloadConfig() int { return int(C.molly_reload_config()) }

// ---------------------------------------------------------------------------
// libc
// ---------------------------------------------------------------------------

// VerifyPassword 复刻 session.c:819-853 的密码校验（crypt + /etc/shadow）。
func VerifyPassword(hash, password string) bool {
	chash := C.CString(hash)
	defer C.molly_free(unsafe.Pointer(chash))
	cpass := C.CString(password)
	defer C.molly_free(unsafe.Pointer(cpass))
	return C.molly_verify_password(chash, cpass) != 0
}

// ---------------------------------------------------------------------------
// luci-rpc 设备绑定（linux only）
//
// 与上面一样：结构体布局与协议字节解析留在 shim.c，Go 侧只看 JSON 文本。
// 这三者都不碰 ubus，只读 sysfs / netlink / dlopen libiwinfo。
// ---------------------------------------------------------------------------

// IfAddr 是 getifaddrs(3) 的一条记录。
// Family: 2=AF_INET，10=AF_INET6，17=AF_PACKET（链路层，Addr/MAC 为 MAC 文本）。
type IfAddr struct {
	Name    string `json:"name"`
	Family  int    `json:"family"`
	Addr    string `json:"addr"`
	Netmask string `json:"netmask"`
	DstAddr string `json:"dstaddr"`
	Flags   uint32 `json:"flags"`
	IfIndex int    `json:"ifindex"`
	HAType  int    `json:"hatype"`
	HALen   int    `json:"halen"`
	MAC     string `json:"mac"`
}

// GetIfaddrs 返回全部接口地址记录（顺序与 getifaddrs 链表一致）。失败返回 nil。
func GetIfaddrs() []IfAddr {
	var out *C.char
	if int(C.molly_getifaddrs_json(&out)) != 0 || out == nil {
		return nil
	}
	s := C.GoString(out)
	C.molly_free(unsafe.Pointer(out))

	var addrs []IfAddr
	if err := json.Unmarshal([]byte(s), &addrs); err != nil {
		return nil
	}
	return addrs
}

// Neighbor 是 netlink 邻居表的一条（MAC 已解析成文本）。
type Neighbor struct {
	IP  string `json:"ip"`
	MAC string `json:"mac"`
}

// GetNeighbors 返回 netlink RTM_GETNEIGH dump 的邻居（已过滤 family 2/10 且 state 非 NOARP）。
// 失败返回 nil（调用方当「没有邻居信息」继续）。
func GetNeighbors() []Neighbor {
	var out *C.char
	if int(C.molly_get_neighbors_json(&out)) != 0 || out == nil {
		return nil
	}
	s := C.GoString(out)
	C.molly_free(unsafe.Pointer(out))

	var ns []Neighbor
	if err := json.Unmarshal([]byte(s), &ns); err != nil {
		return nil
	}
	return ns
}

// IwinfoJSON 返回设备（接口或 phy）的 iwinfo 表（JSON 对象文本）。
// 没装 libiwinfo / 布局不符 / 设备不支持 / 取值越界 → 返回空串与 false，调用方一个键都不加。
// phyOnly 为真时只出 radio（phy）级字段。
func IwinfoJSON(dev string, phyOnly bool) (string, bool) {
	cdev := C.CString(dev)
	defer C.molly_free(unsafe.Pointer(cdev))
	po := C.int(0)
	if phyOnly {
		po = 1
	}
	var out *C.char
	if int(C.molly_iwinfo_json(cdev, po, &out)) != 0 || out == nil {
		return "", false
	}
	s := C.GoString(out)
	C.molly_free(unsafe.Pointer(out))
	return s, true
}
