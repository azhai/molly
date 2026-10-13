package handlers

// router —— 路由**决策**：给定规范化后的路径与部署配置，判定该交给哪个 handler。
//
// 这是 docs/interfaces.md §3 / Go 版 main.go 里 router.ServeHTTP 那条顺序的纯函数化身
// （normalize → /ubus → /auth → 简洁版(/、/lite) → 专家版(luci-prefix) → cgi-io → 静态）。
// 把「判给谁」与「怎么应答」拆开，有两个理由：
//   1. 顺序与边界是契约（前缀匹配必须带边界：/ubus 认 /ubus 与 /ubus/… 但不认 /ubus.html），
//      且**专家版前缀必须排在静态之前**——否则默认部署的 /cgi-bin/luci 会被静态层的
//      /cgi-bin/* → 403 抢先吃掉；而换了前缀（本站 /admin）后 /cgi-bin/* 又要落回静态 403。
//      这些是语言无关、能脱离套接字与未就绪 handler 单测的东西。
//   2. 各 handler（simple/luci/cgi-io）尚未落地（s4d/s4e/阶段5），把 I/O 粘合等全部就位后
//      在 main.odin 一次写全，能避免一个「半接线、与契约相悖」的分发器。
//
// 因此本文件只提供决策；真正调用 Serve_* 与终结 400/403（Normalize_Path 的产物）的 handle
// 属阶段5。

import "core:strings"

// Route 是一条路径应当去到的处理簇。
Route :: enum {
	Ubus,
	Auth,
	Simple, // 简洁版：/lite 及其任意子路径，外加入口 /（302 到 /lite/）
	Luci,   // 专家版：--luci-prefix 给的前缀
	CGI_IO, // cgi-io 三件套 + backup（按 cgi_base 精确实配）
	Static, // 兜底：docroot 静态文件（/cgi-bin/* 在这里被 403）
}

// Router_Config 是决策需要的部署参数。
//   luci_prefix：专家版 URL 前缀（默认 /cgi-bin/luci，本站 /admin）。
//   cgi_base：cgi-io 端点的公共前缀（由 SCRIPT_NAME 去掉最后一段推得；本部署 ""，上游 "/cgi-bin"）。
Router_Config :: struct {
	luci_prefix: string,
	cgi_base:    string,
}

// 规范化后各前缀的固定字面量（与 ubus_http / auth / simple 里的同名常量对齐）。
router_ubus_prefix  :: "/ubus"
router_auth_prefix  :: "/auth"
router_simple_prefix :: "/lite"
router_simple_entry  :: "/"

// cgi_io_names —— cgi-io 四端点（fs.exec_direct/read_direct/ui.uploadFile + 专家版 backup）。
// 只在 path **正好等于** cgi_base+名字时命中，不做前缀匹配（避免吃掉 /cgi-exec/anything）。
// 用 := 而非 ::：下面要按下标遍历。
cgi_io_names := []string{"/cgi-exec", "/cgi-download", "/cgi-upload", "/cgi-backup"}

// Matches_Prefix —— 带边界的前缀匹配（对齐 main.go 的 matchesPrefix）：等于前缀本身，或
// 前缀之后紧跟 '/'。裸 has_prefix 会把 /ubus.html 这类真实文件误判给 ubus。
Matches_Prefix :: proc(path, prefix: string) -> bool {
	if ! strings.has_prefix(path, prefix) {
		return false
	}
	return len(path) == len(prefix) || path[len(prefix)] == '/'
}

// is_cgi_io —— path 是否正好命中某个 cgi-io 端点（cgi_base + 名字的全等）。
is_cgi_io :: proc(path, base: string) -> bool {
	for name in cgi_io_names {
		if path == build([]string{base, name}) {
			return true
		}
	}
	return false
}

// route_of —— 按契约顺序判定路径归属。path 必须是 Normalize_Path 的 .Ok 产物（'/' 开头、无 .. 段、
// 已剥查询串）。顺序本身即优先级，不可打乱。
route_of :: proc(path: string, cfg: Router_Config) -> Route {
	if Matches_Prefix(path, router_ubus_prefix) {
		return .Ubus
	}
	if Matches_Prefix(path, router_auth_prefix) {
		return .Auth
	}
	if path == router_simple_entry || Matches_Prefix(path, router_simple_prefix) {
		return .Simple
	}
	if Matches_Prefix(path, cfg.luci_prefix) {
		return .Luci
	}
	if is_cgi_io(path, cfg.cgi_base) {
		return .CGI_IO
	}
	return .Static
}
