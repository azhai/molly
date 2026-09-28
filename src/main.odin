package main

// molly —— 用 Odin 复刻 ImmortalWrt LuCI 的服务端替换层。
//
// 替换的是 uhttpd + rpcd + ucode dispatcher 这三层；不动的是 /etc/config（uci）、
// ubusd、/www 静态文件。目标平台 ImmortalWrt 25.12.2 / aarch64_cortex-a53 / musl。
//
// 构建：./build.sh --host（macOS，uci/ubus 走假数据）| ./build.sh --target（aarch64）

import "core:fmt"
import "core:mem"
import "core:net"
import "core:os"
import "core:strings"
import "core:sys/posix"

import "molly:backend"
import "molly:handlers"
import "molly:http"

DEFAULT_LISTEN   :: "0.0.0.0:8080"
DEFAULT_DOCROOT  :: "/www"
DEFAULT_MENU_DIR :: "/usr/share/luci/menu.d"

USAGE :: `molly —— ImmortalWrt LuCI 的服务端替换层（Odin）

用法：
  molly [--listen HOST:PORT] [--docroot PATH] [--menu-dir PATH] [--luci-cgi CMD]

  --listen   监听地址，必须是数字地址，不接受主机名（默认 0.0.0.0:8080）
  --docroot  静态文件根目录（默认 /www）
  --menu-dir LuCI 菜单目录（menu.d）（默认 /usr/share/luci/menu.d）
  --luci-cgi 把 /cgi-bin/luci 交给子进程执行，设备上填 CGI 兜底脚本
             "/www/cgi-bin/luci"（LuCI 装的 '#!/usr/bin/env ucode' 脚本，复刻 uhttpd
             的 CGI 形态，ADR 0003）。留空则用内置的 Odin dispatcher。
             注意**别**填 "/usr/bin/ucode /usr/share/ucode/luci/uhttpd.uc"：那个
             文件是 uhttpd 进程内加载的 ucode 模板（首行 {%），当脚本跑必然
             语法错、每个请求都回 500。
  --ubus-socket PATH
             让 molly 把 ubus 对象注册在**另一条独立的 ubus 总线**上（那条总线上要先
             跑一个 ubusd -s <PATH>）。配了它，系统总线上的 session/uci/file/luci-rpc
             就归 rpcd，原厂 :80 与 molly 的 :8080 各自拥有同名对象、互不影响；
             molly 这边要访问 netifd / network.* 这类系统对象时会自动回退到系统总线。
             不配 = 用系统总线（于是和 rpcd 抢名字：rpcd 在跑时 molly 注册不上）。
  -h, --help 显示这段说明
`

main :: proc() {
	// SIGPIPE：客户端在响应写完前断开会让写操作触发 SIGPIPE，默认动作是杀进程。
	// core:net 的 send 已经传了 MSG_NOSIGNAL，但任何走裸 write / stdio 的路径
	// 仍会触发，全局忽略一次是最省心的兜底（风险 R3）。
	_ = posix.signal(posix.Signal.SIGPIPE, auto_cast posix.SIG_IGN)

	listen := DEFAULT_LISTEN
	docroot := DEFAULT_DOCROOT
	menu_dir := DEFAULT_MENU_DIR
	luci_cgi := ""
	ubus_socket := ""

	args := os.args[1:]
	for i := 0; i < len(args); i += 1 {
		switch args[i] {
		case "--listen":
			i += 1
			if i >= len(args) {
				die("--listen 缺少参数")
			}
			listen = args[i]
		case "--docroot":
			i += 1
			if i >= len(args) {
				die("--docroot 缺少参数")
			}
			docroot = args[i]
		case "--menu-dir":
			i += 1
			if i >= len(args) {
				die("--menu-dir 缺少参数")
			}
			menu_dir = args[i]
		case "--luci-cgi":
			i += 1
			if i >= len(args) {
				die("--luci-cgi 缺少参数")
			}
			luci_cgi = args[i]
		case "--ubus-socket":
			i += 1
			if i >= len(args) {
				die("--ubus-socket 缺少参数")
			}
			ubus_socket = args[i]
		case "-h", "--help":
			fmt.print(USAGE)
			return
		case:
			die(fmt.tprintf("未知参数：%s", args[i]))
		}
	}

	// 去掉尾部 '/'：handler 里是直接 root + path 拼接，多一个斜杠虽然无害，
	// 但会让「docroot 生效了没有」这类排查变麻烦。
	for len(docroot) > 1 && docroot[len(docroot) - 1] == '/' {
		docroot = docroot[:len(docroot) - 1]
	}
	// menu_dir 由 load_tree 直接当目录名用，尾部 '/' 只是冗余写法
	for len(menu_dir) > 1 && menu_dir[len(menu_dir) - 1] == '/' {
		menu_dir = menu_dir[:len(menu_dir) - 1]
	}

	// parse_endpoint 只解析数字地址（0.0.0.0:8080 / [::]:8080），不做 DNS 解析。
	endpoint, ok := net.parse_endpoint(listen)
	if !ok {
		die(fmt.tprintf("无法解析 --listen %q（只接受数字地址，如 0.0.0.0:8080）", listen))
	}

	listener, lerr := net.listen_tcp(endpoint, backlog = 128)
	if lerr != nil {
		die(fmt.tprintf("监听 %s 失败：%v", listen, lerr))
	}

	fmt.println("[molly] 监听", listen)
	fmt.println("[molly] docroot:", docroot)
	fmt.println("[molly] menu.d:", menu_dir)
	if len(luci_cgi) > 0 {
		fmt.println("[molly] /cgi-bin/luci →", luci_cgi)
	} else {
		fmt.println("[molly] /cgi-bin/luci → 内置 dispatcher")
	}
	// P3-9：不再有「transitional mode」这回事——session/uci/file/luci-rpc 都由 molly
	// 自己提供（P3-2…P3-5）。设备上 rpcd 还占着同名对象时，注册会失败，由 ubus 线程
	// 逐个对象打一行诊断（见 linux.odin）——那是事实陈述，不是「过渡模式」声明。

	if len(ubus_socket) > 0 {
		fmt.println("[molly] ubus 私有总线:", ubus_socket)
	} else {
		fmt.println("[molly] ubus 总线: 系统总线（与 rpcd 争 session/uci/file）")
	}
	// 必须在起 ubus 线程**之前**设好：那条线程一启动就要按它去 connect。
	backend.set_ubus_socket(ubus_socket)

	// P3-1（ADR 0001）：ubus 对象由 molly 自己在专用线程里提供。darwin 上没有 ubusd，
	// 返回 false——只影响「molly 是否提供 ubus 对象」，HTTP 服务不受影响。
	if !backend.start_ubus_server() {
		fmt.println("[molly] ubus 服务端对象未启动（本平台无 ubus 或线程创建失败）")
	}

	server := http.Server {
		listener = listener,
		handler  = handle,
		docroot  = docroot,
		menu_dir = menu_dir,
		luci_cgi = luci_cgi,
	}
	http.serve(&server)
}

// 路由入口。路由顺序（见计划「关键设计决策 5」）：路径规范化 → 前缀 /ubus →
// 前缀 /cgi-bin/luci → 其余按 docroot 静态文件。/cgi-bin/luci 在第 6 步插到
// /ubus 之后。
handle :: proc(s: ^http.Server, conn: ^http.Connection, req: ^http.Request) -> bool {
	alloc := mem.dynamic_arena_allocator(&conn.arena)

	// 规范化是安全边界：编码非法回 400，解码后含 .. 回 403。过了这一关，
	// handler 里才可以放心地把 path 拼到 docroot 后面。
	path, state := http.normalize_path(req.target, alloc)
	switch state {
	case .Ok:
	case .Bad:
		return http.respond(conn, .Bad_Request, "bad request\n", {
			keep_alive = req.keep_alive,
		})
	case .Escaping:
		return http.respond(conn, .Forbidden, "forbidden\n", {
			keep_alive = req.keep_alive,
		})
	}

	if matches_prefix(path, "/ubus") {
		return handlers.serve_ubus(s, conn, req, path)
	}

	// /ubus 之后、静态文件之前（计划决策 5）。同样必须带边界，
	// 否则 /cgi-bin/luci-static 这类真实文件会被 dispatcher 抢走。
	if matches_prefix(path, handlers.LUCI_PREFIX) {
		return handlers.serve_luci(s, conn, req, path)
	}

	// 返回值是「这条连接还能继续用吗」，与 req.keep_alive 的相与在
	// serve_connection 里做，这里不用重复。
	return handlers.serve_static(s, conn, req, path)
}

// 前缀匹配必须带边界：/ubus 本身或 /ubus/ 开头。裸 has_prefix 会把
// /ubus.html 这类真实文件也判给 ubus 路由，静态文件就再也送不出去了。
@(private)
matches_prefix :: proc(path, prefix: string) -> bool {
	if !strings.has_prefix(path, prefix) {
		return false
	}
	return len(path) == len(prefix) || path[len(prefix)] == '/'
}

@(private)
die :: proc(msg: string) {
	fmt.eprintln("[molly] 错误：", msg)
	fmt.eprint(USAGE)
	os.exit(2)
}