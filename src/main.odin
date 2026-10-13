package main

// molly —— ImmortalWrt LuCI 的服务端替换层（Odin 重写）。
//
// 替换 uhttpd + rpcd + ucode dispatcher 三层；不动 /etc/config（uci）、ubusd、/www 静态文件。
// 本文件是入口：解析 CLI、按契约顺序初始化后端、把每个请求交给 handlers.Dispatch 分发。
// 语义逐条对齐 main.go（后者是 Go 权威版）；路由顺序本身落在 molly:handlers（见 dispatch.odin）。
//
// M1 范围：CLI + HTTP 服务 + 路由顺序 + 静态文件 + URI 规范化 + 简洁版 + cgi-io 决策。

import "core:os"
import "core:fmt"
import "core:strings"
import "core:c/libc"

import "molly:http"
import "molly:backend"
import "molly:handlers"

// 启动默认值（对齐 main.go）。
DEFAULT_LISTEN      :: "0.0.0.0:8080"
DEFAULT_DOCROOT     :: "/www"
DEFAULT_MENU_DIR    :: "/usr/share/luci/menu.d"
DEFAULT_LUCI_PREFIX :: "/cgi-bin/luci"

// SIGPIPE —— Darwin 与 Linux 同为 13。写半路客户端断开必须由 send_all 静默收尾（见
// http/server.odin、http/response.odin 的注释「SIGPIPE 已在 main 里忽略」），否则进程会被信号杀死。
SIGPIPE :: 13

main :: proc() {
	args: []string
	if len(os.args) > 1 {
		args = os.args[1:]
	}

	if _has_flag(args, "help") || _has_flag(args, "h") {
		usage()
		return
	}

	listen := _flag_or(args, "listen", DEFAULT_LISTEN)
	docroot := _trim_trailing_slash(_flag_or(args, "docroot", DEFAULT_DOCROOT))
	menu_dir := _trim_trailing_slash(_flag_or(args, "menu-dir", DEFAULT_MENU_DIR))
	luci_cgi := _flag_or(args, "luci-cgi", "")
	ubus_socket := _flag_or(args, "ubus-socket", "")

	// 前缀：路由、CGI 的 SCRIPT_NAME、PATH_INFO 切分点三处同源，所以只在这里定一次。
	// 给了就校验并采用，没给用默认 /cgi-bin/luci（本站部署给 /admin）。
	prefix := DEFAULT_LUCI_PREFIX
	if v, ok := _flag_value(args, "luci-prefix"); ok && v != "" {
		if ! _valid_prefix(v) {
			_fail("--luci-prefix 形态不合法（要 '/' 开头、不以 '/' 结尾，且不含空白 / ? / #）")
		}
		prefix = v
	}

	// URL 上省掉的那段（LuCI 顶层的 admin）：URL 侧少它，菜单树里不少它。
	// `admin` 与 `/admin` 等价（补前导 '/'），归一化后交给 handlers 的树路径/SCRIPT_NAME 逻辑。
	strip := ""
	if v, ok := _flag_value(args, "luci-strip"); ok {
		s := strings.trim_space(v)
		if s != "" {
			if ! strings.has_prefix(s, "/") {
				s = _cat([]string{"/", s})
			}
			if len(s) < 2 || s[len(s)-1] == '/' {
				_fail("--luci-strip 形态不合法（写成 admin 或 /admin，或留空）")
			}
			strip = s
		}
	}

	// 渲染方式：显式给了就用给的；没给按「有没有 --luci-cgi」推断——这样旧部署（带 --luci-cgi
	// 的那些）行为不变，摘掉这个开关就是内置 dispatcher。校验取值，与 main.go 一致。
	render := ""
	if v, ok := _flag_value(args, "luci-render"); ok {
		render = v
	} else if luci_cgi != "" {
		render = "cgi"
	} else {
		render = "builtin"
	}
	if render != "builtin" && render != "cgi" {
		_fail(fmt.tprintf("--luci-render 只能是 builtin / cgi，收到 %q", render))
	}

	// 会话统一（方案 1）：专家版交给设备 ucode 渲染（--luci-cgi）且 molly 走系统总线时，设备
	// rpcd 占住 session——molly 原生界面（/lite、/auth、/ubus）的会话与前置 ACL 交给 rpcd，让
	// sid 全端通用。内置接管形态（无 rpcd）不置位，行为不变。
	backend.Set_Session_On_Bus(luci_cgi != "" && ubus_socket == "")

	deploy := handlers.Deploy_Config{
		docroot       = docroot,
		menu_dir      = menu_dir,
		luci_prefix   = prefix,
		strip_segment = strip,
		luci_cgi      = luci_cgi,
		ubus_socket   = ubus_socket,
	}
	print_banner(listen, render, &deploy)

	// 屏蔽 SIGPIPE：必须在起连接线程之前（写侧静默断连由 send_all 处理）。
	libc.signal(SIGPIPE, cast(proc "c" (i32))libc.SIG_IGN)

	// linux：起 ubus 服务线程注册 molly 自有对象（--luci-cgi 下 ucode 经 ubus 调它们）；
	// darwin：空操作。必须在起 HTTP 服务之前，且失败的只是 ucode 侧访问，不阻断 :8080。
	if rc := backend.Start_Server(ubus_socket); rc != 0 {
		fmt.eprintln("[molly] ubus 服务启动失败：ucode 侧将无法经 ubus 调用 molly 对象")
	}
	// 依赖就绪：桥接态（--luci-cgi + 系统总线）登录与会话 ACL 依赖总线上的 rpcd，ubusd 是所有
	// ubus 调用底座。起 HTTP 前先确保它们在线（只拉起缺失、绝不停服务；探不到只告警）。
	backend.Ensure_Deps()

	// 起 HTTP 服务（阻塞；每连接一条线程 → handle）。绑定失败退出码 2（对齐 main.go）。
	if ! http.Serve(listen, handle, &deploy) {
		_fail(fmt.tprintf("监听 {0} 失败", listen))
	}
}

// handle —— 适配 http.Handler（data 携带只读部署配置）→ handlers.Dispatch。
handle :: proc(data: rawptr, req: ^http.Request, res: ^http.Response) {
	deploy := cast(^handlers.Deploy_Config)data
	handlers.Dispatch(res, req, deploy)
}

// print_banner —— 启动横幅（对齐 main.go 的 [molly] 输出）。
print_banner :: proc(listen, render: string, d: ^handlers.Deploy_Config) {
	fmt.println("[molly] 监听", listen)
	fmt.println("[molly] docroot:", d.docroot)
	fmt.println("[molly] menu.d:", d.menu_dir)
	if render == "cgi" {
		fmt.println("[molly] 专家版（Go 复刻的 LuCI）", d.luci_prefix, "→ 交设备 ucode 渲染（对照）:", d.luci_cgi)
	} else {
		fmt.println("[molly] 专家版（Go 复刻的 LuCI）", d.luci_prefix, "→ 内置 Go dispatcher")
	}
	fmt.println("[molly] 简洁版 →", handlers.Simple_Prefix, "（单页应用：仪表盘 + 其余页面），与专家版共用会话")
	if d.ubus_socket != "" {
		fmt.println("[molly] ubus 私有总线:", d.ubus_socket)
	} else {
		fmt.println("[molly] ubus 总线: 系统总线")
	}
}

usage :: proc() {
	fmt.eprintln(`molly —— ImmortalWrt LuCI 的服务端替换层（Odin）

用法：
  molly [--listen HOST:PORT] [--docroot PATH] [--menu-dir PATH]
        [--luci-prefix PREFIX] [--luci-strip SEG] [--luci-cgi CMD] [--luci-render MODE]
        [--ubus-socket PATH]

两套界面（共用同一个会话 cookie，登录一次两边都能用）：
  简洁版  /lite = 全部页面（内置单文件单页应用）；
  专家版  --luci-prefix 给的路径（本站 /admin）= 用 Odin 重写的 LuCI，内置 dispatcher 渲染；
  认证面  /auth/{login,logout,password} = 两边共用，登录/退出一次生效。

默认：--listen ${DEFAULT_LISTEN}  --docroot ${DEFAULT_DOCROOT}  --menu-dir ${DEFAULT_MENU_DIR}
      --luci-prefix ${DEFAULT_LUCI_PREFIX}（专家版前缀）  --luci-render 按有无 --luci-cgi 推断`)
}

// ---- CLI 解析小工具（对齐 Go flag 的 --name value / --name=value 两形态）----

// _cat —— 拼接若干段为一个 string（main 里等价于 handlers 包私有的 build 助手）。
_cat :: proc(parts: []string) -> string {
	return strings.concatenate(parts)
}

// _flag_value —— 找 --name 的取值：`--name v`（下一 token）或 `--name=v`（等号后子串）。
// 返回 (值, 是否存在)。存在但无后继值时返回 ("", true)（交由上层判空/校验）。
_flag_value :: proc(args: []string, name: string) -> (string, bool) {
	long := _cat([]string{"--", name})
	eq := _cat([]string{long, "="})
	for i := 0; i < len(args); i += 1 {
		a := args[i]
		if a == long {
			if i + 1 < len(args) {
				return args[i+1], true
			}
			return "", true
		} else if strings.has_prefix(a, eq) {
			return a[len(eq):], true
		}
	}
	return "", false
}

// _flag_or —— 取字符串开关，未给或给空则回默认。
_flag_or :: proc(args: []string, name, def: string) -> string {
	if v, ok := _flag_value(args, name); ok && v != "" {
		return v
	}
	return def
}

// _has_flag —— 是否存在某个「无值」开关（--help / -h）。
_has_flag :: proc(args: []string, name: string) -> bool {
	long := _cat([]string{"--", name})
	short := _cat([]string{"-", name})
	for a in args {
		if a == long || a == short {
			return true
		}
	}
	return false
}

// _valid_prefix —— 复现 SetLuciPrefix 的形态校验。
_valid_prefix :: proc(p: string) -> bool {
	if len(p) < 2 || p[0] != '/' || p[len(p)-1] == '/' {
		return false
	}
	for i := 0; i < len(p); i += 1 {
		c := p[i]
		if c == ' ' || c == '\t' || c == '?' || c == '#' {
			return false
		}
	}
	return true
}

// _trim_trailing_slash —— 去掉尾部 '/'（handler 里是直接 root + path 拼接，多斜杠会错位）。
_trim_trailing_slash :: proc(input: string) -> string {
	s := input
	for len(s) > 1 && s[len(s)-1] == '/' {
		s = s[0:len(s)-1]
	}
	return s
}

// _fail —— 打印错误并以退出码 2 结束（对齐 main.go：run 返回 error → os.Exit(2)）。
_fail :: proc(msg: string) -> ! {
	fmt.eprintf("[molly] 错误：%s\n", msg)
	os.exit(2)
}
