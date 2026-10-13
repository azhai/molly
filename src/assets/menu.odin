package assets

// menu —— 简洁版（/lite）的菜单与注入配置（对齐 webassets/simple/simple.go）。
//
// 三个刻意为之的取舍（同 Go）：
//   1. 不读 menu.d：菜单是这份编译进二进制的常量表，站点导航的唯一事实来源，页面不自己硬编码；
//   2. 单文件页：HTML/Mithril 内嵌（见 embedded.odin），零 CDN、零构建、离线可用；
//   3. 不新增业务 API：数据面仍是 /ubus JSON-RPC，服务端只发页面 + 注入 sid/menu/expert。
//
// JSON 字段顺序**逐字对齐 Go 的 encoding/json**（结构体字段序，非字母序）：
//   MenuItem = id,title,ready ；Config = sid,menu,expert 。
// smoke 用 `grep -o '"id":"[a-z]*","title":"[^"]*","ready":true'` 钉死这段邻接，故不能走会按
// key 排序的 map，必须手工按序拼。

import "core:fmt"

MenuItem :: struct {
	id:    string,
	title: string,
	ready: bool, // false = 菜单里可见但页面尚未落地
}

// Menu —— 简洁版菜单。第一项固定 dash（仪表盘=首屏）。顺序即站点顺序。
Menu : []MenuItem = []MenuItem{
	{"dash", "仪表盘", true},
	{"net", "内外网", true},
	{"wifi", "无线", true},
	{"dhcp", "DHCP", true},
	{"svc", "服务", true},
	{"disk", "存储", true},
	{"diag", "诊断", true},
	{"bk", "备份", true},
	{"log", "日志", true},
	{"sys", "系统", true},
}

// Config —— 注入页面 `__CFG__` 的一份配置。字段值全部服务端可控
// （sid 已收窄成 hex、menu 是本包常量、expert 来自 CLI 且经形态校验）。
Config :: struct {
	sid:    string,
	menu:   []MenuItem,
	expert: string, // 专家版 URL 前缀，页面据此出「前往专家版」链接
}

// menu_json —— 菜单的 JSON 数组形态。
menu_json :: proc(menu: []MenuItem) -> string {
	out: [dynamic]u8
	defer delete(out)
	append(&out, "[")
	for i := 0; i < len(menu); i += 1 {
		it := menu[i]
		if i > 0 {
			append(&out, ",")
		}
		append(&out, "{\"id\":")
		append(&out, quote(it.id))
		append(&out, ",\"title\":")
		append(&out, quote(it.title))
		append(&out, ",\"ready\":")
		append(&out, it.ready ? "true" : "false")
		append(&out, "}")
	}
	append(&out, "]")
	return finish(&out)
}

// MenuJSON —— 用默认 Menu 的 JSON（对齐 Go simple.MenuJSON；失败退化空数组）。
MenuJSON :: proc() -> string { return menu_json(Menu) }

// ConfigJSON —— 序列化配置（对齐 Go simple.ConfigJSON）。落 context.allocator。
ConfigJSON :: proc(c: Config) -> string {
	out: [dynamic]u8
	defer delete(out)
	append(&out, "{\"sid\":")
	append(&out, quote(c.sid))
	append(&out, ",\"menu\":")
	append(&out, menu_json(c.menu))
	append(&out, ",\"expert\":")
	append(&out, quote(c.expert))
	append(&out, "}")
	return finish(&out)
}

// quote —— 把文本转成合法 JSON 字符串字面量（含首尾引号）。
// 转义对齐 Go 的 encoding/json：控制字符、" 与 \，并把 < > & 转成 \u003c/\u003e/\u0026
// （HTML 安全默认）。非 ASCII（中文标题）原样输出（Go 亦如此）。
quote :: proc(s: string) -> string {
	out: [dynamic]u8
	defer delete(out)
	append(&out, `"`)
	for i := 0; i < len(s); i += 1 {
		c := s[i]
		switch c {
		case '"': append(&out, "\\\"")
		case '\\': append(&out, "\\\\")
		case '\n': append(&out, "\\n")
		case '\r': append(&out, "\\r")
		case '\t': append(&out, "\\t")
		case '<': append(&out, "\\u003c")
		case '>': append(&out, "\\u003e")
		case '&': append(&out, "\\u0026")
		case:
			if c < 0x20 {
				append(&out, fmt.tprintf("\\u%04x", cast(int)c))
			} else {
				append(&out, c)
			}
		}
	}
	append(&out, `"`)
	return finish(&out)
}

// finish —— 把 [dynamic]u8 拷成定长 string（脱离动态缓冲）。
finish :: proc(buf: ^[dynamic]u8) -> string {
	out := make([]u8, len(buf^))
	copy(out, buf^[:])
	return string(out)
}
