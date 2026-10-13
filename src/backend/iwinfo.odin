package backend

// iwinfo / 设备信息 —— luci-rpc 设备绑定方法（getNetworkDevices / getWirelessDevices /
// getHostHints）用到的三类宿主无关入口（对齐 internal/cbind：有 cgo 时 shim.c 干字节解析，
// 无 cgo 时 fallback.go fail-closed）。
//
// 边界：真正的字节解析（getifaddrs / netlink / dlopen libiwinfo）留在 src/native/shim.c，
// 经 src/backend/bindings 的 foreign 声明进来。但 bindings 的 `foreign import shim "system:shim"`
// 会把 -lshim 拉进链接图，darwin 测试二进制链不上——所以这里只放**钩子**：钩子为 nil 时按
// fallback.go 的语义 fail-closed（与本机无总线的宿主一致）。阶段 3h 的 linux 平台文件把钩子
// 指向 bindings 支撑的真实现（molly_iwinfo_json / molly_getifaddrs_json / molly_get_neighbors_json）。
//
// 设备绑定方法本身在宿主上直接回 Status_Not_Supported（见 luci_object.odin 的 hook_luci_*），
// 根本不会走到这三个钩子，故宿主保持 nil 即可。

import "core:mem"

// If_Addr —— getifaddrs(3) 的一条记录（Family: 2=AF_INET，10=AF_INET6，17=AF_PACKET）。
If_Addr :: struct {
	name:    string,
	family:  int,
	addr:    string,
	netmask: string,
	dstaddr: string,
	flags:   u32,
	ifindex: int,
	hatype:  int,
	halen:   int,
	mac:     string,
}

// Neighbor —— netlink 邻居表的一条（MAC 已解析成文本）。
Neighbor :: struct {
	ip:  string,
	mac: string,
}

// 设备信息钩子（nil = 宿主 fail-closed；阶段 3h 由 linux 平台文件接真实现）。
hook_iwinfo_json:  proc(dev: string, phy_only: bool, alloc: mem.Allocator) -> (string, bool)
hook_get_ifaddrs:  proc(alloc: mem.Allocator) -> []If_Addr
hook_get_neighbors: proc(alloc: mem.Allocator) -> []Neighbor

// Iwinfo_JSON —— 返回设备（接口或 phy）的 iwinfo 表（JSON 对象文本）。
// 没装 libiwinfo / 布局不符 / 设备不支持 / 取值越界 → 空串与 false，调用方一个键都不加。
// phy_only 为真时只出 radio（phy）级字段。
Iwinfo_JSON :: proc(dev: string, phy_only: bool, alloc: mem.Allocator) -> (string, bool) {
	if hook_iwinfo_json != nil {
		return hook_iwinfo_json(dev, phy_only, alloc)
	}
	return "", false
}

// Get_Ifaddrs —— 全部接口地址记录（顺序与 getifaddrs 链表一致）。失败/宿主 → nil。
Get_Ifaddrs :: proc(alloc: mem.Allocator) -> []If_Addr {
	if hook_get_ifaddrs != nil {
		return hook_get_ifaddrs(alloc)
	}
	return nil
}

// Get_Neighbors —— netlink RTM_GETNEIGH dump 的邻居（已过滤 family 2/10 且 state 非 NOARP）。
// 失败/宿主 → nil（调用方当「没有邻居信息」继续）。
Get_Neighbors :: proc(alloc: mem.Allocator) -> []Neighbor {
	if hook_get_neighbors != nil {
		return hook_get_neighbors(alloc)
	}
	return nil
}
