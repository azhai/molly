package backend

// ---------------------------------------------------------------------------
// uci 对象的 `apply` 系（P3-3 S4）：apply / confirm / rollback / reload_config
//
// 契约：rpcd uci.c:1443-1734。机制一句话：
//   `apply {rollback:true, timeout:N}` 把 /etc/config 与**该会话的 delta** 各备份一份到
//   快照目录，然后提交（= 配置真的生效）；发起者必须在 N 秒内 `confirm`，否则定时器到点
//   **回滚**（用快照覆盖 /etc/config 并重新提交）。等确认期间 `apply_sid` 非空，
//   `commit`/`revert` 一律被挡（uci.c:1330-1331），发起者之外的人 `confirm`/`rollback` → 6。
//
// 目录（uci.h）：
//   RPC_SNAPSHOT_FILES /var/run/rpcd/snapshot-files/   /etc/config 的原样备份
//   RPC_SNAPSHOT_DELTA /var/run/rpcd/snapshot-delta/   delta 文件的备份
//   RPC_UCI_SAVEDIR_PREFIX /var/run/rpcd/uci-<sid>/    每会话的 delta
//
// 平台无关：文件操作、权限判断、状态码全在这里；只有「提交一个 config」（要 libuci）与
// `reload_config`（要 fork/exec）是 provider。darwin 的 provider 一律回 8。
//
// 与上游的差异（见 docs/interfaces.md §8.3）：
//   1) 确认窗口用**自清理线程 + sleep**，不是 uloop_timeout（少一个 C 结构体绑定；
//      同一时刻最多一个 apply 待确认，线程数有界）。
//   2) 上游用 glob(GLOB_PERIOD) 列目录（`.`/`..` 也进结果，所以它有 `gl_pathc < 3` 这个
//      拐弯的判断）；molly 用 os.read_dir 后**显式跳过 dotfile 与空文件**——效果等价：
//      一个可用的 delta 文件都没有 → 5（NO_DATA）。
// ---------------------------------------------------------------------------

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:runtime"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

// 60 秒确认窗口（RPC_APPLY_TIMEOUT）
UCI_APPLY_TIMEOUT :: 60

UCI_SNAPSHOT_FILES :: "/var/run/rpcd/snapshot-files/"
UCI_SNAPSHOT_DELTA :: "/var/run/rpcd/snapshot-delta/"
UCI_CONFIG_DIR :: "/etc/config/"

// 一个 config 都没命中 / 没有任何 delta 文件时的状态码（上游 UBUS_STATUS_NO_DATA = 5）
UCI_STATUS_NO_DATA :: 5

// 定时器代际号：cancel 时 +1，于是「已经取消的那次定时」醒来后会直接退出。
@(private)
g_uci_apply_timer_gen: int

// 上游把客户端给的 timeout 钳在 INT_MAX 毫秒以内，避免溢出成负数后定时器立刻到点
// （uci.c:1637-1645）。这里用同一个上界。
@(private)
UCI_APPLY_MAX_MS :: 2147483647

// ---------------------------------------------------------------------------
// 文件层
// ---------------------------------------------------------------------------

// 目录里「可用的」文件名：跳过 dotfile（含 . 与 ..）与空文件（uci.c:1489-1498、:1620-1628）。
// 目录不存在 → ok = false（上游 glob 失败 → 4）。
uci_snapshot_files :: proc(dir: string, alloc: mem.Allocator) -> (names: []string, ok: bool) {
	handle, err := os.open(dir)
	if err != nil {
		return nil, false
	}
	defer os.close(handle)

	entries, rerr := os.read_dir(handle, -1, alloc)
	if rerr != nil {
		return nil, false
	}

	out := make([dynamic]string, 0, len(entries), alloc)
	for e in entries {
		if len(e.name) == 0 || e.name[0] == '.' {
			continue
		}
		info, serr := os.stat(fmt.aprintf("%s%s", dir, e.name, allocator = alloc), alloc)
		if serr != nil || info.size == 0 {
			continue
		}
		append(&out, strings.clone(e.name, alloc))
	}
	return out[:], true
}

// <from><name> → <to><name>（uci.c:1457-1478；上游忽略失败，这里也返回 bool 由调用方决定）
uci_copy_file :: proc(from_dir, to_dir, name: string, alloc: mem.Allocator) -> bool {
	src := fmt.aprintf("%s%s", from_dir, name, allocator = alloc)
	dst := fmt.aprintf("%s%s", to_dir, name, allocator = alloc)

	data, rerr := os.read_entire_file(src, alloc)
	if rerr != nil {
		return false
	}
	return os.write_entire_file(dst, data) == nil
}

// ---------------------------------------------------------------------------
// 权限与回滚
// ---------------------------------------------------------------------------

// uci.c:1480-1505 rpc_uci_apply_access：
//   没有任何可用文件 → 5（NO_DATA）
//   有一个 config 没写权限 → 6（PERMISSION_DENIED）
//   全都有写权限 → 0
uci_apply_access :: proc(sid: string, names: []string, alloc: mem.Allocator) -> int {
	if len(names) == 0 {
		return UCI_STATUS_NO_DATA
	}

	ses := session_get(sid)
	for name in names {
		if ses == nil || !session_acl_allowed(ses, "uci", name, "write") {
			return UCI_STATUS_PERMISSION_DENIED
		}
	}
	return UCI_STATUS_OK
}

// uci.c:1507-1548 rpc_uci_do_rollback。
// 「发起 apply 的会话还在吗」用 apply_access 判断：还在（0）就连 delta 一起恢复，
// 否则只恢复 /etc/config（uci.c:1513-1522）。
uci_do_rollback :: proc(names: []string, alloc: mem.Allocator) -> int {
	sid := g_uci_apply_sid
	deny := len(sid) > 0 ? uci_apply_access(sid, names, alloc) : UCI_STATUS_NOT_FOUND

	savedir := fmt.aprintf("%s%s/", UCI_SAVEDIR_PREFIX, sid, allocator = alloc)
	if deny == UCI_STATUS_OK {
		_ = os.make_directory(savedir)
	}

	for name in names {
		// 上游先把 delta 副本放回去，再「不合并 delta」地提交主配置（uci.c:1524-1539）：
		// `rpc_uci_replace_savedir("/dev/null")` 让 uci_load 看不见任何 delta，
		// 否则回滚会被当前的未提交改动污染。provider 的 no_delta 参数就是这件事。
		uci_copy_file(UCI_SNAPSHOT_FILES, UCI_CONFIG_DIR, name, alloc)
		if st := uci_apply_config(name, true, alloc); st != 0 {
			return st
		}
		if deny != UCI_STATUS_OK {
			continue
		}
		uci_copy_file(UCI_SNAPSHOT_DELTA, savedir, name, alloc)
	}

	uci_purge_dir(UCI_SNAPSHOT_FILES, alloc)
	uci_purge_dir(UCI_SNAPSHOT_DELTA, alloc)

	uci_apply_timer_cancel()
	g_uci_apply_sid = ""
	return UCI_STATUS_OK
}

// 定时器到点（uci.c:1550-1563 rpc_uci_apply_timeout）。
uci_apply_timeout_fired :: proc(alloc: mem.Allocator) {
	names, ok := uci_snapshot_files(UCI_SNAPSHOT_FILES, alloc)
	if !ok {
		return
	}
	_ = uci_do_rollback(names, alloc)
}

// 单槽：同一时刻最多只有一个 apply 在等确认（g_uci_apply_sid），所以不需要队列。
@(private)
g_uci_apply_timer_ms: int

// 起 60s（或调用方给的 timeout）确认窗口。见文件头「与上游的差异」第 1 条。
// 线程里不捕获外层局部变量（Odin 没有闭包），所以代际号在线程**启动时**读一次。
uci_apply_timer_start :: proc(ms: int) {
	g_uci_apply_timer_ms = ms
	sync.atomic_add(&g_uci_apply_timer_gen, 1)

	thread.create_and_start(
		proc() {
			context = runtime.default_context()

			my_gen := sync.atomic_load(&g_uci_apply_timer_gen)
			time.sleep(time.Duration(g_uci_apply_timer_ms) * time.Millisecond)

			// 代际变了 = 期间被 confirm/rollback（或新的 apply）顶掉 → 什么都不做
			if sync.atomic_load(&g_uci_apply_timer_gen) != my_gen {
				return
			}
			if uci_apply_pending() {
				uci_apply_timeout_fired(context.allocator)
			}
		},
		self_cleanup = true,
	)
}

// 取消（uci.c:1545-1546、:1678）：让在跑的定时器失效；调用方负责清 g_uci_apply_sid。
uci_apply_timer_cancel :: proc() {
	sync.atomic_add(&g_uci_apply_timer_gen, 1)
}

// ---------------------------------------------------------------------------
// 方法层
// ---------------------------------------------------------------------------

@(private)
uci_param_bool :: proc(params: json.Object, key: string) -> bool {
	v, found := params[key]
	if !found {
		return false
	}
	b, is_bool := v.(json.Boolean)
	return is_bool && bool(b)
}

@(private)
uci_param_int :: proc(params: json.Object, key: string) -> (int, bool) {
	v, found := params[key]
	if !found {
		return 0, false
	}
	n, is_int := v.(json.Integer)
	if !is_int {
		return 0, false
	}
	return int(n), true
}

// uci.c:1565-1651 rpc_uci_apply。
@(private)
uci_method_apply :: proc(params: json.Object, alloc: mem.Allocator) -> (string, int) {
	rollback := uci_param_bool(params, "rollback")

	// 已经有一次 apply 在等确认时，不允许再发起一个「要回滚的 apply」（uci.c:1584-1585）
	if uci_apply_pending() && rollback {
		return "", UCI_STATUS_PERMISSION_DENIED
	}

	sid, has_sid := uci_sid_of(params)
	if !has_sid {
		return "", UCI_STATUS_INVALID_ARGUMENT
	}

	timeout := UCI_APPLY_TIMEOUT
	if n, has_timeout := uci_param_int(params, "timeout"); has_timeout {
		timeout = n
	}

	// 每次 apply 都先清掉上次的快照（uci.c:1595-1596）
	uci_purge_dir(UCI_SNAPSHOT_FILES, alloc)
	uci_purge_dir(UCI_SNAPSHOT_DELTA, alloc)

	// 已有 apply 在等确认 → 只做上面的清理就返回（uci.c:1598 的 if (!apply_sid[0])）
	if uci_apply_pending() {
		return "", UCI_STATUS_OK
	}

	savedir := fmt.aprintf("%s%s/", UCI_SAVEDIR_PREFIX, sid, allocator = alloc)
	names, ok := uci_snapshot_files(savedir, alloc)
	if !ok {
		return "", UCI_STATUS_NOT_FOUND
	}

	if st := uci_apply_access(sid, names, alloc); st != 0 {
		return "", st
	}

	_ = os.make_directory(UCI_SNAPSHOT_FILES)
	_ = os.make_directory(UCI_SNAPSHOT_DELTA)

	// 先记 sid：提交过程会调用 ubus（触发事件）并改动包级状态（上游同样先 strncpy，uci.c:1616-1618）
	if rollback {
		g_uci_apply_sid = strings.clone(sid, session_store_allocator())
	}

	for name in names {
		uci_copy_file(UCI_CONFIG_DIR, UCI_SNAPSHOT_FILES, name, alloc)
		uci_copy_file(savedir, UCI_SNAPSHOT_DELTA, name, alloc)
		if st := uci_apply_config(name, false, alloc); st != 0 {
			return "", st
		}
	}

	if rollback {
		// 上游把毫秒钳到 INT_MAX 以内，避免客户端给的超大/负数 timeout 让定时器立刻到点
		// （uci.c:1637-1645）
		ms := timeout > 0 && timeout <= UCI_APPLY_MAX_MS / 1000 ? timeout * 1000 : UCI_APPLY_MAX_MS
		uci_apply_timer_start(ms)
	}

	return "", UCI_STATUS_OK
}

// uci.c:1653-1683 rpc_uci_confirm。
@(private)
uci_method_confirm :: proc(params: json.Object, alloc: mem.Allocator) -> (string, int) {
	sid, has_sid := uci_sid_of(params)
	if !has_sid {
		return "", UCI_STATUS_INVALID_ARGUMENT
	}

	if !uci_apply_pending() {
		return "", UCI_STATUS_NO_DATA
	}
	if g_uci_apply_sid != sid {
		return "", UCI_STATUS_PERMISSION_DENIED
	}

	uci_purge_dir(UCI_SNAPSHOT_FILES, alloc)
	uci_purge_dir(UCI_SNAPSHOT_DELTA, alloc)

	uci_apply_timer_cancel()
	g_uci_apply_sid = ""
	return "", UCI_STATUS_OK
}

// uci.c:1685-1718 rpc_uci_rollback。注意顺序：**先**判有没有待确认的 apply（→ 5），
// 再判 sid 参数（→ 2），与 confirm 正好相反（上游就是如此，见 uci.c:1698-1702）。
@(private)
uci_method_rollback :: proc(params: json.Object, alloc: mem.Allocator) -> (string, int) {
	if !uci_apply_pending() {
		return "", UCI_STATUS_NO_DATA
	}

	sid, has_sid := uci_sid_of(params)
	if !has_sid {
		return "", UCI_STATUS_INVALID_ARGUMENT
	}
	if g_uci_apply_sid != sid {
		return "", UCI_STATUS_PERMISSION_DENIED
	}

	names, ok := uci_snapshot_files(UCI_SNAPSHOT_FILES, alloc)
	if !ok {
		return "", UCI_STATUS_NOT_FOUND
	}

	if st := uci_do_rollback(names, alloc); st != 0 {
		return "", st
	}
	return "", UCI_STATUS_OK
}

// uci.c:1720-1734 rpc_uci_reload：让 /sbin/reload_config 在响应发出后跑（provider）。
@(private)
uci_method_reload_config :: proc(alloc: mem.Allocator) -> (string, int) {
	if st := uci_reload_config(alloc); st != 0 {
		return "", st
	}
	return "", UCI_STATUS_OK
}
