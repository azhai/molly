package handlers

import "core:mem"
import "core:strings"

import "molly:http"

// 新手版（novice）—— 一页只放最常见的几件事：系统状态、实时负载、重启、内外网设置、
// 无线中继、DHCP 分配与 MAC 绑定。
//
// 与专家版（LuCI，前缀由 --luci-prefix 给）的分工：
//   - 专家版吃 `LUCI_PREFIX`（本站部署是 `/pro`），内容交给设备上的 ucode dispatcher；
//   - 新手版吃 `/` 与 `/index.html`，页面是**编译进二进制的单文件**，不碰 ucode、也不
//     依赖 docroot 上的任何文件。
//
// 两者**共用同一份会话**（同一个 cookie）与**同一个数据面**（`/ubus` 的 JSON-RPC，
// 前端直接发 `params: [sid, obj, meth, args]`）——所以服务端不为新手版新增任何 API，
// 也没有第二套鉴权。这样「登录一次、两套界面都能用」是自然结果，不是额外协调出来的。

// 页面在编译期读进来（Odin 的 #load 相当于 Go 的 go:embed）。
// 路径相对本文件：src/handlers/novice.odin → src/novice/assets/index.html
NOVICE_HTML :: #load("../novice/assets/index.html", string)

// 新手版吃哪些路径。页面是单文件（CSS/JS 内联），所以只有入口这两个。
is_novice_path :: proc(path: string) -> bool {
	return path == "/" || path == "/index.html"
}

serve_novice :: proc(
	s: ^http.Server,
	conn: ^http.Connection,
	req: ^http.Request,
	path: string,
) -> bool {
	if !is_novice_path(path) {
		return false
	}
	// 与专家版一致：上游 CGI 形态只接 GET（HEAD 由 HTTP 层处理成「有头无体」）。
	if req.method != .Get && req.method != .Head {
		return http.respond(conn, .Method_Not_Allowed, "method not allowed\n", {
			keep_alive = req.keep_alive,
		})
	}

	alloc := mem.dynamic_arena_allocator(&conn.arena)
	page := build_novice_page(luci_sid_from_cookie(req), alloc)
	return http.respond(conn, .OK, page, {
		content_type = "text/html; charset=utf-8",
		keep_alive   = req.keep_alive,
		head_only    = req.method == .Head,
	})
}

// 把页面里的两个占位符换掉：`__SID__`（会话 id）与 `__EXPERT_PREFIX__`（专家版前缀）。
//
// 用 replace_all 而不是 fmt：HTML 里有大量 `%`（CSS 的百分比、JS 的取模），走格式化
// 很容易踩。
@(private)
build_novice_page :: proc(sid: string, alloc: mem.Allocator) -> string {
	page, _ := strings.replace_all(NOVICE_HTML, "__SID__", sanitize_sid(sid, alloc), alloc)
	page, _ = strings.replace_all(page, "__EXPERT_PREFIX__", LUCI_PREFIX, alloc)
	return page
}

// 只保留十六进制字符（会话 id 就是 32 位 hex）。
//
// 为什么不是「转义」而是「白名单过滤」：这个值来自客户端的 Cookie，而它要被拼进
// **HTML 里的 JavaScript 字符串**。任何引号/尖括号/反斜杠都可能变成脚本注入——
// 与其在两种上下文（HTML 与 JS）里各转义一遍，不如按已知形态收窄到「只可能是它」。
// 非法输入退化成空串，页面就显示登录卡，行为可预期。
@(private)
sanitize_sid :: proc(sid: string, alloc: mem.Allocator) -> string {
	if len(sid) == 0 {
		return ""
	}
	buf := make([dynamic]u8, 0, 32, alloc)
	for c in sid {
		is_hex := (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
		if !is_hex {
			return "" // 出现非 hex 字符：整个丢弃，别做「截断到第一个非法字符」这种猜测
		}
		append(&buf, u8(c)) // 上面已确认是 ASCII hex，收窄到 u8 安全
		if len(buf) >= 32 {
			break
		}
	}
	return string(buf[:])
}
