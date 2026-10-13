package backend

// platform_hooks.odin —— 阶段 3c 的临时宿主（darwin 语义）平台钩子。
//
// session 对象是平台无关的，但它依赖三样平台差异（对齐 Go 的 darwin.go/linux.go）：
//   1. uci 数据源（菜单 depends.uci + /etc/config/rpcd 的 login section）；
//   2. 密码校验（linux 用 /etc/shadow + crypt；darwin 假凭据）；
//   3. acl.d 目录（linux 是 /usr/share/rpcd/acl.d；darwin 用仓库 fixture，可用 MOLLY_ACL_DIR 覆盖）。
//
// 这里先给一份「假数据」默认实现，让 session 在 macOS 上端到端可跑、可单测。
// 阶段 3h 会把它们拆成 `#+build darwin` / `#+build linux` 两份，linux 版接真 libuci/libc。

import "core:mem"
import "core:os"

// 假数据以包级变量存放（global 数据段，非栈），可直接返回切片视图（只读不改）。
_ucis_network := []Uci_Section{
	{
		name = "lan", type_name = "interface",
		options = []Uci_Option{
			{name = "proto", values = []string{"static"}},
			{name = "ifname", values = []string{"br-lan"}},
			{name = "ipaddr", values = []string{"192.168.1.1"}},
		},
	},
	{name = "wan", type_name = "interface", options = []Uci_Option{{name = "proto", values = []string{"dhcp"}}}},
	{name = "wg0", type_name = "interface", options = []Uci_Option{{name = "proto", values = []string{"wireguard"}}}},
	{
		name = "", type_name = "switch", anonymous = true,
		options = []Uci_Option{{name = "name", values = []string{"switch0"}}},
	},
}

_ucis_system := []Uci_Section{
	{
		name = "ntp", type_name = "timeserver",
		options = []Uci_Option{
			{name = "enabled", values = []string{"1"}},
			{name = "server", is_list = true, values = []string{"0.openwrt.pool.ntp.org", "1.openwrt.pool.ntp.org"}},
		},
	},
}

_ucis_rpcd := []Uci_Section{
	{
		name = "login", type_name = "login",
		options = []Uci_Option{
			{name = "username", values = []string{"root"}},
			{name = "password", values = []string{"$p$root"}},
			{name = "read", is_list = true, values = []string{"*"}},
			{name = "write", is_list = true, values = []string{"*"}},
		},
	},
}

_ucis_dhcp := []Uci_Section{
	{name = "dnsmasq", type_name = "dnsmasq", options = []Uci_Option{{name = "leasefile", values = []string{"/tmp/molly-dhcp.leases"}}}},
	{name = "odhcpd", type_name = "odhcpd", options = []Uci_Option{{name = "leasefile", values = []string{"/tmp/molly-odhcpd.leases"}}}},
}

// host_uci_sections —— UCI 段数据的宿主默认值（真机以 /etc/config 为准）。
host_uci_sections :: proc(config: string, alloc: mem.Allocator) -> (sections: []Uci_Section, ok: bool) {
	_ = alloc
	switch config {
	case "network":
		return _ucis_network, true
	case "system":
		return _ucis_system, true
	case "empty-config":
		return nil, true // 存在但没有 section
	case "rpcd":
		return _ucis_rpcd, true
	case "dhcp":
		return _ucis_dhcp, true
	}
	return nil, false
}

// 假凭据约定（与 Go darwin.go 一致，session 断言据此）：
//
//	"$p$root"（真机默认配置写法） → 密码必须是 "test1234"
//	空 hash                        → 任何密码都通过
//	其它                           → 明文相等才算通过
host_verify_password :: proc(hash, password: string) -> bool {
	if len(hash) == 0 {
		return true
	}
	if hash == "$p$root" {
		return password == "test1234"
	}
	return hash == password
}

// host_acl_dir —— acl.d 目录。darwin 用仓库 fixture（MOLLY_ACL_DIR 可覆盖，smoke 会设绝对路径）。
host_acl_dir :: proc() -> string {
	if d := os.get_env("MOLLY_ACL_DIR", context.allocator); d != "" {
		return d
	}
	return "tests/fixtures/acl.d"
}
