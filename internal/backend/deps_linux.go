//go:build linux

package backend

// molly 依赖服务的启动期就绪管理（ubusd 总线 + 桥接态的 rpcd）。
//
// 设计边界（与运维确认）：
//  - 只「拉起缺失」，绝不 stop/kill 任何服务；
//  - 只在桥接态（sessionOnBus，即 --luci-cgi + 系统总线）生效——此态登录与会话 ACL 交给
//    总线上的 rpcd，rpcd 不在就什么都用不了。内置接管态（sessionOnBus==false）不该抢 rpcd
//    的对象名，直接跳过。
//  - ubusd 无 init 脚本（procd 早期自管），运行期几乎不会缺；这里以「总线能否连上 +
//    能否看到 rpcd 的 session 对象」隐式覆盖，探不到只告警。
//
// darwin（本机自测）无总线，由 darwin.go 的同名空实现兜住。

import (
	"fmt"
	"os"
	"os/exec"
	"time"
)

const (
	depWait = 8 * time.Second // 启动期等待依赖就绪的上限；正常秒过，仅兜 rpcd 崩溃后重启窗口
	depPoll = 300 * time.Millisecond
)

// EnsureDeps 在起 HTTP 服务之前确保 molly 依赖在线。main 于 SetSessionOnBus、StartServer
// 之后调用一次。永不致命：超时只告警并继续服务，避免把设备卡成无法登录。
func EnsureDeps() {
	if !sessionOnBus {
		return // 内置接管 / 非桥接态：不介入 rpcd，交接管方管理
	}
	if busReady() {
		fmt.Println("[molly] 依赖就绪：ubusd 总线可连，rpcd 已注册 session 对象")
		return
	}

	// 只 start（幂等：已在跑即 no-op），不 stop。ubusd 无脚本会被 startIfPresent 跳过。
	startIfPresent("ubusd")
	startIfPresent("rpcd")

	deadline := time.Now().Add(depWait)
	for {
		if busReady() {
			fmt.Println("[molly] 依赖就绪：已拉起 rpcd，session 对象在总线上可用")
			return
		}
		if time.Now().After(deadline) {
			fmt.Fprintln(os.Stderr, "[molly] 警告：rpcd 的 session 对象在总线上仍未就绪；"+
				":8080 的登录与会话鉴权可能不可用。请确认 ubusd 与 /etc/init.d/rpcd 在运行。")
			return
		}
		time.Sleep(depPoll)
	}
}

// busReady 探系统总线上是否已有 rpcd 的 session 对象：一次探明「ubusd 可连」与
// 「rpcd 在线并注册了对象」两件事。持 ubusMu——与 HTTP 侧出站调用同一把锁（shim 的
// 全局 blob_buf 非线程安全）。
func busReady() bool {
	ubusMu.Lock()
	defer ubusMu.Unlock()
	ctx := sysConn()
	if ctx == nil {
		return false
	}
	_, e := ctx.LookupID("session")
	return e == 0
}

// startIfPresent 对存在 init 脚本的服务执行一次 start。失败只告警。绝不 stop/kill。
func startIfPresent(name string) {
	script := "/etc/init.d/" + name
	if _, err := os.Stat(script); err != nil {
		return // 如 ubusd：无 init 脚本（procd 早期自管）
	}
	if err := exec.Command(script, "start").Run(); err != nil {
		fmt.Fprintf(os.Stderr, "[molly] 拉起 %s 失败：%v\n", name, err)
	}
}
