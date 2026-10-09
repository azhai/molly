//go:build linux

package backend

import (
	"encoding/json"
	"os"
	"sync"
	"syscall"

	"github.com/azhai/molly/internal/cbind"
)

// linux（目标设备）上的 provider —— 真 libubus / libblobmsg_json / libubox / libuci。
//
// 与 Odin 版 src/backend/linux.odin 一一对应，但有一条刻意的架构偏离（见计划
// 「M5 实现设计」）：**molly 自有的五个对象走进程内调用**（callOwnObject），不做
// ubus 往返。可观测结果与 Odin 的往返一致（跑的是同一份 handler 逻辑），
// 但避免「同 ctx 跨线程 invoke」与 uloop poll 冲突。外部对象（netifd / service /
// network.* …）才真正 ubus_invoke_fd。
//
// 另起一条 ubus 服务线程（shim.c 里的 pthread + uloop_run_timeout）注册五个对象，
// 供 --luci-cgi 下的 ucode 经 ubus 调用（等价 Odin 的 ubus_server_thread）。

// New 返回当前平台的 provider。
func New() Backend { return linuxBackend{} }

type linuxBackend struct{}

// ---------------------------------------------------------------------------
// ubus 连接（惰性 + 复用）
//
// 与 Odin 一致：连不上**不**缓存失败，下次调用再试（代价一次 connect）。
// libubus 的 ctx 非线程安全，且 shim.c 复用了全局 blob_buf，所以 HTTP 侧所有
// 调用共用一把锁串行化（与 Odin 的 g_lock 同义）。
// ---------------------------------------------------------------------------

var (
	ubusMu     sync.Mutex
	ubusSocket string // 私有总线路径；空 = 系统总线
	ownCtx     *cbind.Ctx
	sysCtx     *cbind.Ctx

	// sessionOnBus：桥接态标志——系统总线且设备 rpcd 占住 session 时置真。此时
	// molly 原生界面（/lite、/auth、/ubus）把 session 对象与前置 ACL 交给总线上的
	// rpcd，使 sysauth_molly 里的 sid 全端通用（cookie 不分端口，两套存储会互盖）。
	// 非桥接态（内置接管 / darwin）恒为 false，行为与以前完全一致。见 SetSessionOnBus。
	sessionOnBus bool
)

// SetSessionOnBus 记下是否处于「session 由总线上的 rpcd 权威」的桥接态。
// main 在起任何线程 / HTTP 服务之前调用一次（darwin.go 有同名空实现）。
func SetSessionOnBus(on bool) {
	sessionOnBus = on
	// 桥接态顺带接管「自有对象实现内部那道 ACL」：进程内 uci/file 对象调的 sessionAccess
	// 也转问 rpcd。否则桥接态下真会话在 rpcd、molly 私有存储查不到那条 sid，会被一律
	// 误判成 Permission denied（uci.get / file.exec 等带内部鉴权的方法在 :8080 频繁被拒）。
	if on {
		SetSessionAccessBridge(func(sid, scope, object, function string) (bool, bool) {
			return rpcdSessionAccess(sid, scope, object, function), true
		})
	} else {
		SetSessionAccessBridge(nil)
	}
}

// SetUbusSocket 记下私有总线路径（由 main 在起任何线程之前调用一次）。
func SetUbusSocket(path string) { ubusSocket = path }

// ownConn 是 molly 对象所在总线的连接（没配私有总线就是系统总线）。
func ownConn() *cbind.Ctx {
	if ownCtx == nil {
		ownCtx = cbind.Connect(ubusSocket)
	}
	return ownCtx
}

// sysConn 是系统总线的连接，只用于**访问系统对象**。没配私有总线时返回 ownConn()
// ——表示「主连接就是系统总线，不必多开一条」（与 Odin ubus_sys_ctx 同义）。
func sysConn() *cbind.Ctx {
	if ubusSocket == "" {
		return ownConn()
	}
	if sysCtx == nil {
		sysCtx = cbind.Connect("")
	}
	return sysCtx
}

// ---------------------------------------------------------------------------
// GET /ubus/list 与 /ubus/list/<path>
// ---------------------------------------------------------------------------

func (linuxBackend) ListObjects(path string) (string, int, bool) {
	ubusMu.Lock()
	defer ubusMu.Unlock()

	ctx := ownConn()
	if ctx == nil {
		return "", StatusConnectionFailed, false
	}
	j, e, ok := listOn(ctx, path)
	if !ok {
		// 私有总线模式下系统对象只挂在系统总线上，查不到要换那条再查一次。
		// 这层回退是必需的：ubus_http 在 invoke 之前会先 list 探对象是否存在，
		// 漏掉这里的话，系统对象的调用会在进 CallObject 之前就被判 Object not found。
		if sys := sysConn(); sys != nil && sys != ctx {
			return listOn(sys, path)
		}
	}
	return j, e, ok
}

func listOn(ctx *cbind.Ctx, path string) (string, int, bool) {
	j, e := ctx.Lookup(path)
	if e != 0 {
		return "", e, false
	}
	return j, 0, true
}

// ---------------------------------------------------------------------------
// POST /ubus 与 /ubus/call/<path> 的调用部分
// ---------------------------------------------------------------------------

func (linuxBackend) CallObject(objPath, method, paramsJSON, sid string) CallResult {
	// 自有对象（session/uci/file/luci-rpc/molly.probe）走进程内真实现，与 darwin 完全同构。
	// 例外：桥接态下的 session——让登录与会话读写都落到总线上的 rpcd，molly 不再用自己的
	// 进程内存储 mint sid。其余对象仍由 molly 服务（它们的 ACL 判定已在 SessionAccessUbus 里交给 rpcd）。
	if !(sessionOnBus && objPath == "session") {
		if reply, status, handled := callOwnObject(objPath, method, paramsJSON, sid); handled {
			if status != 0 {
				return CallResult{Outcome: OutcomeOk, Ret: status}
			}
			return CallResult{Outcome: OutcomeOk, Ret: 0, Reply: reply}
		}
	}

	ubusMu.Lock()
	defer ubusMu.Unlock()

	ctx := ownConn()
	if ctx == nil {
		return CallResult{Outcome: OutcomeInternal}
	}

	// 1) 找对象：先自己总线，失败且系统总线不同 → 回退系统总线；都失败 → Object_Not_Found。
	use := ctx
	id, e := ctx.LookupID(objPath)
	if e != 0 {
		sys := sysConn()
		if sys == nil || sys == use {
			return CallResult{Outcome: OutcomeObjectNotFound}
		}
		var e2 int
		id, e2 = sys.LookupID(objPath)
		if e2 != 0 {
			return CallResult{Outcome: OutcomeObjectNotFound}
		}
		use = sys
	}

	// 2) 同步调用（sid 由 shim 追加成 ubus_rpc_session）。
	reply, ret := use.Invoke(id, method, paramsJSON, sid)
	if ret != 0 {
		// ubus_invoke_fd 把「请求根本没发出去」和「远端返回 INVALID_ARGUMENT」合并成同一个
		// 返回值。按上游语义：INVALID_ARGUMENT 当本机故障，其余（NOT_FOUND / TIMEOUT /
		// METHOD_NOT_FOUND …）当远端返回码交给 handler。
		if ret == StatusInvalidArgument {
			return CallResult{Outcome: OutcomeInternal}
		}
		return CallResult{Outcome: OutcomeOk, Ret: ret}
	}
	return CallResult{Outcome: OutcomeOk, Ret: 0, Reply: reply}
}

// ---------------------------------------------------------------------------
// ubus 服务端（--luci-cgi 下 ucode 经 ubus 调用 molly 对象）
// ---------------------------------------------------------------------------

// StartServer 起 ubus 服务线程并注册五个对象。socketPath 为空用系统总线。
// 返回 0 成功。main 在起 HTTP 服务前调用一次（darwin.go 有同名空实现）。
func StartServer(socketPath string) int {
	SetUbusSocket(socketPath)
	cbind.SetHandler(linuxUbusHandler)
	return cbind.StartServer(socketPath)
}

// linuxUbusHandler 是入站 ubus 调用的 Go 侧实现：只处理自有对象（shim 也只注册这五个）。
// 入参 paramsJSON 里通常已带 ubus_rpc_session（ucode 传的），所以 sid 传空。
func linuxUbusHandler(obj, method, paramsJSON string) (int, string) {
	reply, status, handled := callOwnObject(obj, method, paramsJSON, "")
	if !handled {
		return StatusNotSupported, ""
	}
	if status != 0 {
		return status, ""
	}
	return 0, reply
}

// ---------------------------------------------------------------------------
// 平台钩子（session.go 调用；darwin.go 有同名同签名的另一份）
//
//   uciConfigSections     → libuci（见 uci_linux.go）
//   sessionVerifyPassword → /etc/shadow + crypt()（见 session_linux.go）
//   sessionACLDir         → /usr/share/rpcd/acl.d
//   fileStatMeta          → syscall.Stat_t 的 atime/ctime/inode
// ---------------------------------------------------------------------------

func uciConfigSections(config string) ([]UciSection, bool) {
	return uciProviderSections(config)
}

func sessionACLDir() string {
	if d := os.Getenv("GOMOLLY_ACL_DIR"); d != "" {
		return d
	}
	return "/usr/share/rpcd/acl.d"
}

// fileStatMeta 是 file_object.go 的 fileStatJSON 用的平台钩子：stat 的 atime/ctime
// （秒）与 inode（截到 u32），对齐 Odin file_stat_dump_json（file_object.odin:355-358）。
// linux 的 Stat_t 字段名是 Atim/Ctim/Ino。
func fileStatMeta(info os.FileInfo) (atime, ctime, inode int64) {
	st, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		mt := info.ModTime().Unix()
		return mt, mt, 0
	}
	return st.Atim.Sec, st.Ctim.Sec, int64(uint32(st.Ino))
}

func (linuxBackend) UciConfigSections(config string) ([]UciSection, bool) {
	return uciConfigSections(config)
}

// rpcdSessionAccess 把一道 ACL 判断交给总线上的 rpcd：session.access(scope/object/function)。
// 传输失败或 rpcd 报错一律按拒绝（fail-closed）。桥接态下 HTTP 前置 ACL 与自有对象内部
// ACL 都收敛到这里，保证 :8080 与 :80 判定同源一致。复用 CallObject（session 在桥接态已
// 转发到总线），不另立 plumbing。
func rpcdSessionAccess(sid, scope, object, function string) bool {
	params := `{"scope":` + quoteJSON(scope) +
		`,"object":` + quoteJSON(object) +
		`,"function":` + quoteJSON(function) + `}`
	res := linuxBackend{}.CallObject("session", "access", params, sid)
	if res.Outcome != OutcomeOk || res.Ret != 0 {
		return false
	}
	var out struct {
		Access bool `json:"access"`
	}
	if err := json.Unmarshal([]byte(res.Reply), &out); err != nil {
		return false
	}
	return out.Access
}

func (linuxBackend) SessionAccessUbus(sid, object, function string) bool {
	if sessionOnBus {
		return rpcdSessionAccess(sid, "ubus", object, function)
	}
	return SessionAccessUbus(sid, object, function)
}

func (linuxBackend) SessionSelfService(sid, method string) bool {
	if sessionOnBus {
		// 会话归 rpcd：对 get/set/unset/destroy 这几个「读改自己会话」的方法，按 sid
		// 形态放行，真正的有效性交给被转发的 rpcd session 对象兜底（rpcd 不认的 sid 自会报错）。
		switch method {
		case "get", "set", "unset", "destroy":
			return sid != "" && sid != SessionDefaultID
		}
		return false
	}
	return SessionSelfService(sid, method)
}

func (linuxBackend) SessionACLLevel(sid string, groups []string) ACLLevel {
	return SessionACLLevel(sid, groups)
}

// sseWatchStart / sseWatchStop：M5 起由 ubus 线程做 register_subscriber + subscribe
// （见 Odin linux.odin）。当前空实现，事件仍可经 Publish 直达（测试路径）。
func sseWatchStart(string) bool { return true }
func sseWatchStop(string)       {}
