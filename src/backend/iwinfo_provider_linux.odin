package backend

// iwinfo_provider_linux —— luci-rpc 设备绑定三钩子的 linux 真实现（对齐
// internal/cbind 的 molly_getifaddrs_json / molly_get_neighbors_json / molly_iwinfo_json）。
//
// 字节解析（getifaddrs 链表、netlink RTM_GETNEIGH dump、dlopen libiwinfo）全留在 src/native/shim.c，
// C 侧把结果打包成 malloc 的 JSON 文本交回；本层解析成 If_Addr / Neighbor，落**调用方传入的 alloc**
// （会话/请求生命周期由调用方管），再把 C 缓冲 molly_free。
//
// 文件名后缀 _linux 让 Odin 只在 linux 目标编本文件：bindings 的 `foreign import shim "system:shim"`
// 会拉进 -lshim，不进 darwin 测试二进制的链接图。宿主（darwin）那份保持 hook_* 为 nil → iwinfo.odin 里
// fail-closed（回 ""/nil）；设备绑定方法本身在宿主直接回 Status_Not_Supported，根本不走到这三个钩子。
//
// 入参 dev 用 strings.clone_to_cstring（context.allocator，随 arena 回收、**不** molly_free）；
// 出参 JSON 文本先 clone 进 alloc 再 molly_free 原缓冲。uci_jstr/uci_jint 复用 uci_provider_linux 的同包定义。

import "core:mem"
import "core:strings"
import "core:encoding/json"

import "bindings"

// linux_iwinfo_json —— 设备 iwinfo 表（JSON 对象文本）。C 失败/空 → ("", false)，调用方一个键都不加。
linux_iwinfo_json :: proc(dev: string, phy_only: bool, alloc: mem.Allocator) -> (string, bool) {
	phy: i32 = 0
	if phy_only {
		phy = 1
	}
	out_c: cstring
	if bindings.molly_iwinfo_json(strings.clone_to_cstring(dev), phy, &out_c) != 0 {
		return "", false
	}
	if out_c == nil {
		return "", false
	}
	s := strings.clone_from_cstring(out_c, alloc)
	bindings.molly_free(transmute(rawptr)(out_c))
	if s == "" {
		return "", false
	}
	return s, true
}

// linux_json_array —— 把 JSON 文本解析进 alloc 并断言是数组；否则回 nil,false。
linux_json_array :: proc(js: string, alloc: mem.Allocator) -> (json.Array, bool) {
	if js == "" {
		return {}, false
	}
	v, err := json.parse_string(js, .JSON, true, alloc)
	if err != nil {
		return {}, false
	}
	arr, is_arr := v.(json.Array)
	if !is_arr {
		return {}, false
	}
	return arr, true
}

// linux_decode_ifaddrs —— shim 的 molly_getifaddrs_json 数组 → []If_Addr。
// family/ifindex/hatype/halen/flags 是 u32；转 int/u32 落结构体。
linux_decode_ifaddrs :: proc(js: string, alloc: mem.Allocator) -> []If_Addr {
	arr, ok := linux_json_array(js, alloc)
	if !ok {
		return nil
	}
	out := make([dynamic]If_Addr, alloc)
	for item in arr {
		o, is_obj := item.(json.Object)
		if !is_obj {
			continue
		}
		append(&out, If_Addr{
			name    = uci_jstr(o, "name"),
			family  = int(uci_jint(o, "family")),
			addr    = uci_jstr(o, "addr"),
			netmask = uci_jstr(o, "netmask"),
			dstaddr = uci_jstr(o, "dstaddr"),
			flags   = u32(uci_jint(o, "flags")),
			ifindex = int(uci_jint(o, "ifindex")),
			hatype  = int(uci_jint(o, "hatype")),
			halen   = int(uci_jint(o, "halen")),
			mac     = uci_jstr(o, "mac"),
		})
	}
	return out[:]
}

// linux_decode_neighbors —— shim 的 molly_get_neighbors_json 数组 → []Neighbor。
linux_decode_neighbors :: proc(js: string, alloc: mem.Allocator) -> []Neighbor {
	arr, ok := linux_json_array(js, alloc)
	if !ok {
		return nil
	}
	out := make([dynamic]Neighbor, alloc)
	for item in arr {
		o, is_obj := item.(json.Object)
		if !is_obj {
			continue
		}
		append(&out, Neighbor{
			ip  = uci_jstr(o, "ip"),
			mac = uci_jstr(o, "mac"),
		})
	}
	return out[:]
}

// linux_get_ifaddrs —— 取全部接口地址；C 失败 → nil（调用方当无接口）。
linux_get_ifaddrs :: proc(alloc: mem.Allocator) -> []If_Addr {
	out_c: cstring
	if bindings.molly_getifaddrs_json(&out_c) != 0 || out_c == nil {
		return nil
	}
	js := strings.clone_from_cstring(out_c, alloc)
	bindings.molly_free(transmute(rawptr)(out_c))
	return linux_decode_ifaddrs(js, alloc)
}

// linux_get_neighbors —— 取 netlink 邻居表；C 失败 → nil（调用方当「没有邻居信息」继续）。
linux_get_neighbors :: proc(alloc: mem.Allocator) -> []Neighbor {
	out_c: cstring
	if bindings.molly_get_neighbors_json(&out_c) != 0 || out_c == nil {
		return nil
	}
	js := strings.clone_from_cstring(out_c, alloc)
	bindings.molly_free(transmute(rawptr)(out_c))
	return linux_decode_neighbors(js, alloc)
}

@(init)
install_linux_device_hooks :: proc "contextless" () {
	hook_iwinfo_json   = linux_iwinfo_json
	hook_get_ifaddrs   = linux_get_ifaddrs
	hook_get_neighbors = linux_get_neighbors
}
