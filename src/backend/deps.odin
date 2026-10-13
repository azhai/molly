package backend

// deps —— molly 依赖服务的启动期就绪管理（ubusd 总线 + 桥接态的 rpcd）。
// 对齐 internal/backend/deps_linux.go 与 darwin.go 的 EnsureDeps。
//
// 设计边界（与运维确认）：
//   - 只「拉起缺失」，绝不 stop/kill 任何服务；
//   - 只在桥接态（sessionOnBus，即 --luci-cgi + 系统总线）生效——此态登录与会话 ACL 交给
//     总线上的 rpcd，rpcd 不在就什么都用不了。内置接管态（sessionOnBus==false）不该抢 rpcd
//     的对象名，直接跳过。
//   - 永不致命：超时只告警并继续服务，避免把设备卡成无法登录。
//
// 宿主（darwin）无总线 → 空操作（与 darwin.go 同名空实现一致）。linux 的探测/拉起需要
// bindings 支撑的 sysConn/LookupID/init.d 调用，随阶段 3h 的 linux 平台文件接入：设
// hook_ensure_deps 即接管；未设（宿主）时 Ensure_Deps 什么都不做。

// session_on_bus —— 是否处于桥接态（main 在接线时设定；仅 hook 内部逻辑读取）。
session_on_bus : bool

hook_ensure_deps: proc()

// Ensure_Deps —— 起 HTTP 服务之前确保 molly 依赖在线。main 于会话上线、StartServer 之后调一次。
Ensure_Deps :: proc() {
	if hook_ensure_deps != nil {
		hook_ensure_deps()
		return
	}
	// 宿主：无 ubusd / rpcd，也没有总线可探，空操作。
}
