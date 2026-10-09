// Package simple —— 简洁版（`/lite`）的前端资源与导航菜单。
//
// 三个刻意为之的取舍：
//
//  1. **不读 menu.d**。菜单是下面这份 Go 侧数据（Menu），编译进二进制。代价是设备升级
//     带来的新页面不会自动出现（要我们自己加），换来的是彻底不依赖 LuCI 的目录结构。
//  2. **不调 ucode / 不用 LuCI 主题**。页面是单文件（内联 CSS/JS、零 CDN、零构建），
//     编译期 embed，离线与弱网可用。
//  3. **服务端不新增业务 API**。数据面就是既有的 `/ubus` JSON-RPC，服务端只负责把页面
//     发出去、把会话 id、菜单与专家版前缀注入进去。
//
// 简洁版只有**一个前缀**（/lite）与**一份页面**：仪表盘是它的第一屏（`dash`），其余页面走
// `#/片段`。菜单是 Menu ——站点导航的唯一事实来源，页面不自己硬编码。
package simple

import _ "embed"

import "encoding/json"

//go:embed index.html
var HTML string

// MenuItem 是菜单里的一项。
//
// id 用路由片段（"dash" / "net" …），不是 URL 路径：页面按「<前缀>/#/片段」的约定生成链接，
// 所以前缀一改，所有链接自动跟着变。
type MenuItem struct {
	ID    string `json:"id"`
	Title string `json:"title"`
	Ready bool   `json:"ready"` // false = 菜单里可见但页面尚未落地
}

// Menu 是简洁版的菜单。**这是站点导航的唯一事实来源**，页面不自己硬编码。
//
// 第一项固定是 `dash`（仪表盘），也就是简洁版的首屏。
var Menu = []MenuItem{
	{ID: "dash", Title: "仪表盘", Ready: true},
	{ID: "net", Title: "内外网", Ready: true},
	{ID: "wifi", Title: "无线", Ready: true},
	{ID: "dhcp", Title: "DHCP", Ready: true},
	{ID: "sys", Title: "系统", Ready: true},
	{ID: "log", Title: "日志", Ready: true},
	{ID: "svc", Title: "服务", Ready: true},
	{ID: "disk", Title: "存储", Ready: true},
	{ID: "diag", Title: "诊断", Ready: true},
	{ID: "bk", Title: "备份", Ready: true},
}

// MenuJSON 是菜单的 JSON 形态，供页面注入。
//
// 单独包一层而不是让调用方 import encoding/json：页面只需要一个字符串，序列化细节
// （以及失败时退化成空数组而不是 panic）留在包内。
func MenuJSON() string {
	b, err := json.Marshal(Menu)
	if err != nil {
		return "[]"
	}
	return string(b)
}

// Config 是注入页面的一份配置（占位符 `__CFG__`）。
//
// 为什么合成一个 JSON 而不是散着好几个占位符：页面要同时拿到会话、菜单与专家版前缀。散着加
// 占位符只会越加越散、也多一处漏替换的面。
//
// 字段值全部是服务端可控的（会话 id 已被收窄成 hex、菜单是本包常量、前缀来自 CLI 且经过
// 形态校验），拼进 `<script>` 里的 JSON 不会出现 `</script>` 之类的破环序列。
type Config struct {
	SID    string     `json:"sid"`
	Menu   []MenuItem `json:"menu"`
	Expert string     `json:"expert"` // 专家版（Go 复刻的 LuCI）的 URL 前缀，页面据此出「前往专家版」链接
}

// ConfigJSON 序列化配置。失败时退化成一份「未登录、空菜单」的配置而不是 panic——
// 页面会显示登录卡，行为可预期。
func ConfigJSON(c Config) string {
	b, err := json.Marshal(c)
	if err != nil {
		return `{"sid":"","menu":[],"expert":""}`
	}
	return string(b)
}
