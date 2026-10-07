// Command molly —— 用 Go 复刻的 ImmortalWrt LuCI 服务端替换层。
//
// 替换的是 uhttpd + rpcd + ucode dispatcher 这三层；不动的是 /etc/config（uci）、
// ubusd、/www 静态文件。目标平台 ImmortalWrt 25.12.2 / aarch64_cortex-a53 / musl。
//
// M1 范围：CLI + HTTP 服务 + 路由顺序 + 静态文件 + URI 规范化。
// M2 加 /ubus 的 JSON-RPC 信封；M3 加 /cgi-bin/luci 的 dispatcher 与 CGI 子进程桥。
package main

import (
	"flag"
	"fmt"
	"net"
	"net/http"
	"os"
	"strings"

	"github.com/azhai/molly/internal/backend"
	"github.com/azhai/molly/internal/handlers"
	"github.com/azhai/molly/internal/httpx"
)

const (
	defaultListen  = "0.0.0.0:8080"
	defaultDocroot = "/www"
	defaultMenuDir = "/usr/share/luci/menu.d"
)

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintf(os.Stderr, "[molly] 错误：%v\n", err)
		os.Exit(2)
	}
}

func run(args []string) error {
	fs := flag.NewFlagSet("molly", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	listen := fs.String("listen", defaultListen, "监听地址，如 0.0.0.0:8080")
	docroot := fs.String("docroot", defaultDocroot, "静态文件根目录")
	menuDir := fs.String("menu-dir", defaultMenuDir, "LuCI 菜单目录（menu.d）")
	luciCGI := fs.String("luci-cgi", "", "把专家版前缀交给子进程执行；留空用内置 dispatcher")
	luciPrefix := fs.String("luci-prefix", "", "专家版（LuCI）的 URL 前缀，默认 /cgi-bin/luci；本站用 /plus")
	luciStrip := fs.String("luci-strip", "", "从专家版 URL 里省掉的那段菜单路径（本站 /admin）；进树时自动补回")
	luciRender := fs.String("luci-render", "app", "专家版渲染方式：app=我们自带的 Go+HTML 站点（默认，不读 menu.d、不依赖 ucode）；builtin=内置占位 dispatcher；cgi=设备 ucode dispatcher（需 --luci-cgi）")
	ubusSocket := fs.String("ubus-socket", "", "让 ubus 对象注册在另一条独立总线上")
	fs.Usage = func() {
		fmt.Fprint(os.Stderr, `molly —— ImmortalWrt LuCI 的服务端替换层（Go）

用法：
  molly [--listen HOST:PORT] [--docroot PATH] [--menu-dir PATH]
          [--luci-prefix PREFIX] [--luci-strip SEG] [--luci-cgi CMD] [--ubus-socket PATH]

三个界面：
  --luci-prefix 给的路径（默认 /cgi-bin/luci）= 专家版，完整 LuCI；
  /lite                                        = 新手版，一页六件事（内置单文件页），/ 是 302 入口；
  /auth/{login,logout,password}                = 两套界面共用的认证面。
  专家版与新手版共用同一个会话 cookie，登录一次两边都能用。

`)
		fs.PrintDefaults()
	}
	if err := fs.Parse(args); err != nil {
		return err
	}

	// 渲染方式：显式给了就用给的；没给就按「有没有 --luci-cgi」推断——
	// 这样旧部署（带 --luci-cgi 的那些）行为不变，而新部署默认就是自研站点。
	render := *luciRender
	if !flagWasSet(fs, "luci-render") {
		if *luciCGI != "" {
			render = "cgi"
		} else {
			render = "app"
		}
	}
	switch render {
	case "app", "builtin", "cgi":
	default:
		return fmt.Errorf("--luci-render 只能是 app / builtin / cgi，收到 %q", render)
	}

	// 前缀：路由、CGI 的 SCRIPT_NAME、PATH_INFO 切分点三处同源，所以只在这里设一次。
	if *luciPrefix != "" {
		if err := handlers.SetLuciPrefix(*luciPrefix); err != nil {
			return err
		}
	}
	// URL 上省掉的那段（LuCI 顶层的 admin）：URL 侧少它，菜单树里不少它。
	if *luciStrip != "" {
		if err := handlers.SetLuciStripSegment(*luciStrip); err != nil {
			return err
		}
	}

	// 去掉尾部 '/'：handler 里是直接 root + path 拼接。
	docrootTrimmed := trimTrailingSlash(*docroot)
	menuDirTrimmed := trimTrailingSlash(*menuDir)

	ln, err := net.Listen("tcp", *listen)
	if err != nil {
		return fmt.Errorf("监听 %s 失败：%w", *listen, err)
	}

	fmt.Println("[molly] 监听", *listen)
	fmt.Println("[molly] docroot:", docrootTrimmed)
	fmt.Println("[molly] menu.d:", menuDirTrimmed)
	if *luciCGI != "" {
		fmt.Println("[molly] 专家版 LuCI", handlers.LuciPrefix, "→", *luciCGI)
	} else {
		fmt.Println("[molly] 专家版 LuCI", handlers.LuciPrefix, "→ 内置 dispatcher")
	}
	fmt.Println("[molly] 新手版 → /（内置单文件页，与专家版共用会话）")
	if *ubusSocket != "" {
		fmt.Println("[molly] ubus 私有总线:", *ubusSocket)
	} else {
		fmt.Println("[molly] ubus 总线: 系统总线")
	}

	rt := &router{
		docroot:    docrootTrimmed,
		menuDir:    menuDirTrimmed,
		luciCGI:    *luciCGI,
		luciRender: render,
		ubusSocket: *ubusSocket,
		ubus:       backend.New(),
	}

	// linux：起 ubus 服务线程注册 molly 自有对象（--luci-cgi 下 ucode 经 ubus 调它们）；
	// darwin：空操作。必须在起 HTTP 服务之前，且失败的只是 ucode 侧访问，不阻断 :8080。
	if rc := backend.StartServer(*ubusSocket); rc != 0 {
		fmt.Fprintln(os.Stderr, "[molly] ubus 服务启动失败：ucode 侧将无法经 ubus 调用 molly 对象")
	}
	srv := &http.Server{Handler: rt}
	return srv.Serve(ln)
}

type router struct {
	docroot    string
	menuDir    string
	luciCGI    string
	luciRender string
	ubusSocket string
	ubus       backend.Backend
}

// ServeHTTP 的路由顺序与 Odin 版一致（计划「关键设计决策 5」）：
// 路径规范化 → 前缀 /ubus → 专家版前缀 → 新手版 / → 其余按 docroot 静态文件。
func (rt *router) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	// 用 RequestURI（原始 origin-form 目标）而不是 r.URL.Path：后者已被 Go 解码，
	// 会丢掉「%2f 与 / 的区别」，而规范化必须看到原始字节才能正确判 400/403。
	target := r.RequestURI
	if target == "" {
		target = r.URL.EscapedPath()
	}

	path, state := httpx.NormalizePath(target)
	switch state {
	case httpx.URIBad:
		handlers.Respond(w, r, http.StatusBadRequest, "bad request\n", "text/plain; charset=utf-8")
		return
	case httpx.URIEscaping:
		handlers.Respond(w, r, http.StatusForbidden, "forbidden\n", "text/plain; charset=utf-8")
		return
	}

	if matchesPrefix(path, handlers.UBUSPrefix) {
		handlers.ServeUbus(w, r, path, rt.ubus)
		return
	}
	// 认证面：两套界面共用（/auth/login、/auth/logout、/auth/password）。
	if handlers.AuthPaths(path) {
		handlers.ServeAuth(w, r, path, rt.ubus)
		return
	}

	// 专家版（--luci-prefix，默认 /cgi-bin/luci）：**我们自己实现的 Go+HTML 站点**。
	// 菜单内置在二进制里（不读 menu.d），页面是静态文件，具体动作全走 /ubus。
	// 只有显式给了 --luci-cgi 时才退回设备 ucode dispatcher 渲染的完整 LuCI（逃生口）。
	if matchesPrefix(path, handlers.LuciPrefix) {
		// app（默认）：自研站点。cgi：设备 ucode dispatcher（逃生口）。
		// builtin：内置占位 dispatcher——留着是为了能回归那条路径（测试在用），
		// 也是设备上排查「页面不出来」时的一个对照。
		if rt.luciRender == "app" || (rt.luciRender == "cgi" && rt.luciCGI == "") {
			handlers.ServeExpert(w, r)
			return
		}
		handlers.ServeLuci(w, r, path, handlers.LuciConfig{
			MenuDir:    rt.menuDir,
			LuciCGI:    rt.luciCGI,
			Docroot:    rt.docroot,
			UbusSocket: rt.ubusSocket,
			Deps:       rt.ubus,
		})
		return
	}
	// 新手版：`/lite` 出页面、`/` 是跳转入口（都排在静态文件之前，于是 docroot 里的
	// index.html 顶不掉它们）。
	if handlers.IsNovicePath(path) || handlers.IsNoviceEntry(path) {
		handlers.ServeNovice(w, r, path, rt.ubus)
		return
	}
	handlers.ServeStatic(w, r, rt.docroot, path)
}

// matchesPrefix 前缀匹配必须带边界：/ubus 本身或 /ubus/ 开头。
// 裸 strings.HasPrefix 会把 /ubus.html 这类真实文件也判给 ubus 路由。
func matchesPrefix(path, prefix string) bool {
	if !strings.HasPrefix(path, prefix) {
		return false
	}
	return len(path) == len(prefix) || path[len(prefix)] == '/'
}

func trimTrailingSlash(s string) string {
	for len(s) > 1 && s[len(s)-1] == '/' {
		s = s[:len(s)-1]
	}
	return s
}

// flagWasSet 报告某个开关是否被**显式**给过（flag 包不区分「默认值」与「用户给了默认值」，
// 而我们需要这个区别：--luci-render 没给时要按 --luci-cgi 推断）。
func flagWasSet(fs *flag.FlagSet, name string) bool {
	set := false
	fs.Visit(func(f *flag.Flag) {
		if f.Name == name {
			set = true
		}
	})
	return set
}
