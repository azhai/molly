package handlers

// dispatch —— 路由**接线**：规范化 + 按 route_of 的决策把请求交给对应 Serve_*。
//
// router.odin 把「判给谁」抽成了纯函数（可脱离套接字第 host 单测）；本文件是那条评论里
// 明确留给阶段5的另一半——「怎么应答」：把 Normalize_Path 的 400/403 终结，再逐簇调用
// Serve_Ubus/Serve_Auth/Serve_Simple/Serve_Luci/Serve_CGI_IO/Serve_Static。等到 simple/luci/
// cgi-io 都落地（s5a~s5c）才一次写全，正是为了避免此前那个「半接线分发器」与契约相悖。
//
// 顺序即优先级（见 route_of）：normalize → /ubus → /auth → 简洁版(/、/lite) → 专家版(luci-prefix)
// → cgi-io → 静态兜底。前缀匹配带边界、专家版排在静态之前（否则 /cgi-bin/luci 被静态 403 抢吃）。

import "molly:http"
import "molly:luci"

// Deploy_Config —— 分发所需的部署参数（全是启动时定好的字符串；无函数指针、无套接字状态）。
//   docroot/menu_dir：静态根目录 / menu.d 目录（均已去尾部 '/'）。
//   luci_prefix：专家版 URL 前缀（main 已解析默认，恒非空）。
//   strip_segment：URL 里省掉的那段菜单路径（main 已归一化为 '' 或 '/xxx'）。
//   luci_cgi：非空 → 专家版整段前缀交设备 ucode 子进程渲染（对照/排查形态，见 Serve_Luci）。
//   ubus_socket：ubus 私有总线路径（空=系统总线）。
Deploy_Config :: struct {
	docroot:       string,
	menu_dir:      string,
	luci_prefix:   string,
	strip_segment: string,
	luci_cgi:      string,
	ubus_socket:   string,
}

// Dispatch —— 一条已就绪请求的分发入口（对齐 main.go 的 router.ServeHTTP）。
// 用 req.target（原始 origin-form 目标）而非解码后的路径规范化：必须先看到原始字节才能正确判
// 400/403（%2f 与 / 的区别在解码后丢失）。d 由 main 在启动时定好、随连接透传（只读）。
Dispatch :: proc(res: ^http.Response, req: ^http.Request, d: ^Deploy_Config) {
	path, state := http.Normalize_Path(req.target)
	switch state {
	case .Ok:
		// 规范化通过：继续往下按 route_of 分发。
	case .Bad:
		http.Respond(res, 400, "bad request\n", "text/plain; charset=utf-8")
		return
	case .Escaping:
		http.Respond(res, 403, "forbidden\n", "text/plain; charset=utf-8")
		return
	}

	// cgi_base 与 SCRIPT_NAME 同源（cgi_base_of 内部即 cgi_script_name 去最后一段）；
	// 路由判定（CGI_IO 端点）与实际 Serve_CGI_IO 必须共用这一个值。
	cgi_base := cgi_base_of(d.luci_prefix, d.strip_segment)
	cfg := Router_Config{luci_prefix = d.luci_prefix, cgi_base = cgi_base}

	switch route_of(path, cfg) {
	case .Ubus:
		Serve_Ubus(res, req, path)
	case .Auth:
		Serve_Auth(res, req, path)
	case .Simple:
		// expert 注入项 = 专家版前缀（页面「前往专家版」链接的 href），与路由/CGI 同源。
		Serve_Simple(res, req, path, d.luci_prefix)
	case .Luci:
		Serve_Luci(res, req, path, Luci_Config{
			menu_dir      = d.menu_dir,
			deps          = luci.Backend_Deps(),
			luci_prefix   = d.luci_prefix,
			strip_segment = d.strip_segment,
			luci_cgi      = d.luci_cgi,
			docroot       = d.docroot,
			ubus_socket   = d.ubus_socket,
		})
	case .CGI_IO:
		Serve_CGI_IO(res, req, path, cgi_base)
	case .Static:
		Serve_Static(res, req, d.docroot, path)
	}
}
