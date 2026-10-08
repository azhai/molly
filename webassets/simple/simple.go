package expert

import _ "embed"

import "encoding/json"

// 专家版界面：**我们自己实现的 Go + HTML 站点**，只有动作经 ubus。
//
// 三个刻意为之的取舍：
//
//  1. **不读 menu.d**。菜单是下面这份 Go 侧数据（Menu），编译进二进制。代价是设备升级
//     带来的新页面不会自动出现（要我们自己加），换来的是彻底不依赖 LuCI 的目录结构——
//     这是「只依赖 libubus」最干净的形态。
//  2. **不调 ucode / 不用 LuCI 主题**。页面是单文件（内联 CSS/JS、零 CDN、零构建），
//     编译期 embed，离线与弱网可用。
//  3. **服务端不新增业务 API**。数据面就是既有的 `/ubus` JSON-RPC，服务端只负责把页面
//     发出去、把会话 id 与下面这份菜单注入进去。
//
//go:embed index.html
var HTML string

// 直接用 HTML：调用方只需 strings.ReplaceAll 注入占位符，不必知道来源。

// MenuItem 是菜单里的一项。页面按这个结构渲染左侧导航，点击切 hash（前端路由）。
//
// href 用路由片段（"dash" / "net" …），不是 URL 路径：站点是单页，URL 只带
// `--luci-prefix` + `#/片段`，专家版前缀一改，所有链接自动跟着变。
type MenuItem struct {
	ID    string `json:"id"`
	Title string `json:"title"`
	Ready bool   `json:"ready"` // false = 菜单里可见但页面尚未落地
}

// Menu 是专家版的菜单。**这是站点导航的唯一事实来源**，页面不自己硬编码。
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
