package backend

// ---------------------------------------------------------------------------
// iwinfo（P3-5 的 S2b′/S2c′ 收尾）
//
// 上游 luci.c:961-1096 的 rpc_luci_get_iwinfo：**只在 getWirelessDevices 里用**
// （接口一次 phy_only=false、radio 一次 phy_only=true）——getNetworkDevices 不调它，
// 之前把它挂到 S2b 名下是记错了。
//
// 实现方式与上游一致：运行时 dlopen `/usr/lib/libiwinfo.so*`，dlsym 取
//   iwinfo_backend（返回 `struct iwinfo_ops *`）、iwinfo_close、iwinfo_format_hwmodes，
// 以及六张名字表（80211/htmode/auth/kmgmt/cipher/opmode）。
//
// **布局是版本敏感的**（函数指针顺序 + 名字表长度都随 iwinfo 版本变）：本文件按
// iwinfo master 的 `include/iwinfo.h` 对齐（字段含 center_chan1/2、mbssid_support、
// htmode、phyname、assoclist…）。为了**绝不吐垃圾**，做了两层失效保护：
//   1. `ops.name` 必须是已知后端名（wext/nl80211/madwifi/wl/unknown）；
//   2. 关键取值做范围检查（mode 落在 OPMODE 表内、hwmodes 位不越过 80211 表）。
// 任一不满足 → 当作「没有 iwinfo」，一个字段都不加（上游 dlopen 失败也是这个行为）。
// 真机 golden 对比时要在这条上专门核对（设备 iwinfo 版本以 ImmortalWrt 25.12.2 为准）。
// ---------------------------------------------------------------------------

import "core:c"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sys/posix"

// iwinfo.h 的常量（名字表长度）
IWINFO_BUFSIZE :: 24 * 1024
IWINFO_80211_COUNT :: 8
IWINFO_HTMODE_COUNT :: 19
IWINFO_HTMODE_NOHT :: u32(1) << 7
IWINFO_AUTH_COUNT :: 2
IWINFO_KMGMT_COUNT :: 5
IWINFO_KMGMT_NONE :: u32(1) << 0
IWINFO_CIPHER_COUNT :: 11
IWINFO_CIPHER_NONE :: u32(1) << 0
IWINFO_OPMODE_COUNT :: 10

// struct iwinfo_ops（iwinfo.h）：函数指针一律存 rawptr，调用时按签名转。
Iwinfo_Ops :: struct {
	name:             rawptr,
	probe:            rawptr,
	mode:             rawptr,
	channel:          rawptr,
	center_chan1:     rawptr,
	center_chan2:     rawptr,
	frequency:        rawptr,
	frequency_offset: rawptr,
	txpower:          rawptr,
	txpower_offset:   rawptr,
	bitrate:          rawptr,
	signal:           rawptr,
	noise:            rawptr,
	quality:          rawptr,
	quality_max:      rawptr,
	mbssid_support:   rawptr,
	hwmodelist:       rawptr,
	htmodelist:       rawptr,
	htmode:           rawptr,
	ssid:             rawptr,
	bssid:            rawptr,
	country:          rawptr,
	hardware_id:      rawptr,
	hardware_name:    rawptr,
	encryption:       rawptr,
	phyname:          rawptr,
	assoclist:        rawptr,
	txpwrlist:        rawptr,
	scanlist:         rawptr,
	freqlist:         rawptr,
	countrylist:      rawptr,
	survey:           rawptr,
	lookup_phy:       rawptr,
	phy_path:         rawptr,
	close:            rawptr,
}

// struct iwinfo_crypto_entry（8 字节，无填充）
Iwinfo_Crypto :: struct {
	enabled:       u8,
	wpa_version:   u8,
	group_ciphers: u16,
	pair_ciphers:  u16,
	auth_suites:   u8,
	auth_algs:     u8,
}

// struct iwinfo_hardware_id（136 字节）
Iwinfo_Hardware_Id :: struct {
	vendor_id:            u16,
	device_id:            u16,
	subsystem_vendor_id:  u16,
	subsystem_device_id:  u16,
	compatible:           [128]u8,
}

// --- dlopen 状态（懒加载一次）---------------------------------------------

@(private)
g_iw_loaded: bool
@(private)
g_iw_ok: bool
@(private)
g_iw_handle: posix.Symbol_Table
@(private)
g_iw_backend: rawptr
@(private)
g_iw_format_hwmodes: rawptr
@(private)
g_iw_close: rawptr
@(private)
g_iw_80211_names: [^]cstring
@(private)
g_iw_htmode_names: [^]cstring
@(private)
g_iw_auth_names: [^]cstring
@(private)
g_iw_kmgmt_names: [^]cstring
@(private)
g_iw_cipher_names: [^]cstring
@(private)
g_iw_opmode_names: [^]cstring

@(private)
iwinfo_load :: proc(alloc: mem.Allocator) -> bool {
	if g_iw_loaded {
		return g_iw_ok
	}
	g_iw_loaded = true

	// 上游 glob("/usr/lib/libiwinfo.so*")：按目录项前缀匹配，取第一个能 dlopen 的
	handle: posix.Symbol_Table
	libs := make([dynamic]string, 0, 4, alloc)
	if entries, derr := os.read_directory_by_path("/usr/lib", -1, alloc); derr == nil {
		for e in entries {
			if strings.has_prefix(e.name, "libiwinfo.so") {
				append(&libs, strings.clone(e.name, alloc))
			}
		}
	}
	for lib in libs {
		path := fmt.aprintf("/usr/lib/%s", lib, allocator = alloc)
		if h := posix.dlopen(strings.clone_to_cstring(path), {.LAZY}); h != nil {
			handle = h
			break
		}
	}
	if handle == nil {
		return false // 设备上没装 libiwinfo：与上游 dlopen 失败同路
	}

	g_iw_backend = posix.dlsym(handle, "iwinfo_backend")
	g_iw_format_hwmodes = posix.dlsym(handle, "iwinfo_format_hwmodes")
	// 新版本叫 iwinfo_finish，老版本叫 iwinfo_close——两个都试，都没有也行
	g_iw_close = posix.dlsym(handle, "iwinfo_close")
	if g_iw_close == nil {
		g_iw_close = posix.dlsym(handle, "iwinfo_finish")
	}
	g_iw_80211_names = cast([^]cstring)(posix.dlsym(handle, "IWINFO_80211_NAMES"))
	g_iw_htmode_names = cast([^]cstring)(posix.dlsym(handle, "IWINFO_HTMODE_NAMES"))
	g_iw_auth_names = cast([^]cstring)(posix.dlsym(handle, "IWINFO_AUTH_NAMES"))
	g_iw_kmgmt_names = cast([^]cstring)(posix.dlsym(handle, "IWINFO_KMGMT_NAMES"))
	g_iw_cipher_names = cast([^]cstring)(posix.dlsym(handle, "IWINFO_CIPHER_NAMES"))
	g_iw_opmode_names = cast([^]cstring)(posix.dlsym(handle, "IWINFO_OPMODE_NAMES"))

	if g_iw_backend == nil ||
	   g_iw_format_hwmodes == nil ||
	   g_iw_80211_names == nil ||
	   g_iw_htmode_names == nil ||
	   g_iw_auth_names == nil ||
	   g_iw_kmgmt_names == nil ||
	   g_iw_cipher_names == nil ||
	   g_iw_opmode_names == nil {
		return false
	}

	g_iw_handle = handle
	g_iw_ok = true
	return true
}

// ops.name 必须是已知后端名（防布局错位时把任意指针当字符串读）
@(private)
iwinfo_ops_name_ok :: proc(ops: ^Iwinfo_Ops) -> bool {
	if ops == nil || ops.name == nil {
		return false
	}
	name := string(cast(cstring)(ops.name))
	switch name {
	case "wext", "nl80211", "madwifi", "wl", "unknown":
		return true
	}
	return false
}

// --- 调用助手（返回 0 = 成功，与上游一致）---------------------------------

@(private)
iwinfo_call_num :: proc(fn: rawptr, dev: cstring, out: ^c.int) -> bool {
	if fn == nil {
		return false
	}
	f := cast(proc "c" (dev: cstring, out: ^c.int) -> c.int)(fn)
	return f(dev, out) == 0
}

@(private)
iwinfo_call_str :: proc(fn: rawptr, dev: cstring, buf: [^]u8) -> bool {
	if fn == nil {
		return false
	}
	f := cast(proc "c" (dev: cstring, buf: [^]u8) -> c.int)(fn)
	return f(dev, buf) == 0
}

// iw_add_bit_array（luci.c:930-959）：bits==0 时用 zero 兜底，逐位查名字表
@(private)
iwinfo_add_bit_array :: proc(
	obj: ^json.Object,
	key: string,
	bits: u32,
	names: [^]cstring,
	count: int,
	lower: bool,
	zero: u32,
	alloc: mem.Allocator,
) {
	b := bits
	if b == 0 {
		b = zero
	}
	arr := make([dynamic]json.Value, 0, count, alloc)
	for i := 0; i < count; i += 1 {
		if (b & (u32(1) << uint(i))) == 0 {
			continue
		}
		v := string(names[i])
		if lower {
			v = strings.to_lower(v, alloc)
		}
		append(&arr, json.Value(json.String(v)))
	}
	obj[key] = json.Value(json.Array(arr))
}

// --- 主体（luci.c:961-1096）----------------------------------------------

// 生成 iwinfo 表；失败返回 (…, false)，调用方不加任何键。
// devname 为接口名；phy_only=true 时只出 radio（phy）级字段。
luci_iwinfo_json :: proc(devname: string, phy_only: bool, alloc: mem.Allocator) -> (json.Object, bool) {
	obj := make(json.Object, 16, alloc)
	if !iwinfo_load(alloc) {
		return obj, false
	}

	backend := cast(proc "c" (dev: cstring) -> ^Iwinfo_Ops)(g_iw_backend)
	dev := strings.clone_to_cstring(devname, alloc)
	ops := backend(dev)
	if !iwinfo_ops_name_ok(ops) {
		return obj, false // 布局可能不匹配：宁可不给字段
	}
	defer if g_iw_close != nil {
		close_fn := cast(proc "c" () -> c.int)(g_iw_close)
		_ = close_fn()
	}

	buf := make([]u8, IWINFO_BUFSIZE, alloc)
	defer delete(buf, alloc)
	num: c.int

	// 数值/字符串字段（luci.c:1008-1016）
	if iwinfo_call_num(ops.signal, dev, &num) {
		obj["signal"] = json.Value(json.Integer(i64(num)))
	}
	if iwinfo_call_num(ops.noise, dev, &num) {
		obj["noise"] = json.Value(json.Integer(i64(num)))
	}
	if iwinfo_call_num(ops.channel, dev, &num) {
		obj["channel"] = json.Value(json.Integer(i64(num)))
	}
	if iwinfo_call_str(ops.country, dev, &buf[0]) {
		obj["country"] = json.Value(json.String(strings.clone(string(cstring(&buf[0])), alloc)))
	}
	if iwinfo_call_str(ops.phyname, dev, &buf[0]) {
		obj["phy"] = json.Value(json.String(strings.clone(string(cstring(&buf[0])), alloc)))
	}
	if iwinfo_call_num(ops.txpower, dev, &num) {
		obj["txpower"] = json.Value(json.Integer(i64(num)))
	}
	if iwinfo_call_num(ops.txpower_offset, dev, &num) {
		obj["txpower_offset"] = json.Value(json.Integer(i64(num)))
	}
	if iwinfo_call_num(ops.frequency, dev, &num) {
		obj["frequency"] = json.Value(json.Integer(i64(num)))
	}
	if iwinfo_call_num(ops.frequency_offset, dev, &num) {
		obj["frequency_offset"] = json.Value(json.Integer(i64(num)))
	}

	// hwmodes（位图 + 文本）+ htmodes（luci.c:1018-1028）
	if iwinfo_call_num(ops.hwmodelist, dev, &num) {
		bits := u32(num)
		// 范围守卫：位越过 80211 名字表说明布局/版本不符
		if bits & ~u32((u32(1) << uint(IWINFO_80211_COUNT)) - 1) != 0 {
			return obj, false
		}
		iwinfo_add_bit_array(&obj, "hwmodes", bits, g_iw_80211_names, IWINFO_80211_COUNT, true, 0, alloc)
		if g_iw_format_hwmodes != nil {
			text: [32]u8
			f := cast(proc "c" (mode: c.int, buf: [^]u8, len: c.int) -> c.int)(g_iw_format_hwmodes)
			if f(num, &text[0], c.int(len(text))) > 0 {
				obj["hwmodes_text"] = json.Value(json.String(strings.clone(string(cstring(&text[0])), alloc)))
			}
		}
	}
	if iwinfo_call_num(ops.htmodelist, dev, &num) {
		bits := u32(num)
		if bits & ~u32((u32(1) << uint(IWINFO_HTMODE_COUNT)) - 1) != 0 {
			return obj, false
		}
		iwinfo_add_bit_array(&obj, "htmodes", bits & ~IWINFO_HTMODE_NOHT, g_iw_htmode_names, IWINFO_HTMODE_COUNT, false, 0, alloc)
	}

	// hardware（luci.c:1030-1043）
	if iwinfo_call_str(ops.hardware_id, dev, &buf[0]) {
		ids := cast(^Iwinfo_Hardware_Id)(&buf[0])
		hw := make(json.Object, 1, alloc)
		arr := make([dynamic]json.Value, 0, 4, alloc)
		append(&arr, json.Value(json.Integer(i64(ids.vendor_id))))
		append(&arr, json.Value(json.Integer(i64(ids.device_id))))
		append(&arr, json.Value(json.Integer(i64(ids.subsystem_vendor_id))))
		append(&arr, json.Value(json.Integer(i64(ids.subsystem_device_id))))
		hw["id"] = json.Value(json.Array(arr))
		if iwinfo_call_str(ops.hardware_name, dev, &buf[0]) {
			hw["name"] = json.Value(json.String(strings.clone(string(cstring(&buf[0])), alloc)))
		}
		obj["hardware"] = json.Value(hw)
	}

	if !phy_only {
		// station 级字段（luci.c:1045-1089）
		if iwinfo_call_num(ops.quality, dev, &num) {
			obj["quality"] = json.Value(json.Integer(i64(num)))
		}
		if iwinfo_call_num(ops.quality_max, dev, &num) {
			obj["quality_max"] = json.Value(json.Integer(i64(num)))
		}
		if iwinfo_call_num(ops.bitrate, dev, &num) {
			obj["bitrate"] = json.Value(json.Integer(i64(num)))
		}
		if iwinfo_call_num(ops.mode, dev, &num) {
			// 范围守卫（同 hwmodes 的理由）
			if num < 0 || int(num) >= IWINFO_OPMODE_COUNT {
				return obj, false
			}
			obj["mode"] = json.Value(json.String(string(g_iw_opmode_names[num])))
		}
		if iwinfo_call_str(ops.ssid, dev, &buf[0]) {
			obj["ssid"] = json.Value(json.String(strings.clone(string(cstring(&buf[0])), alloc)))
		}
		if iwinfo_call_str(ops.bssid, dev, &buf[0]) {
			obj["bssid"] = json.Value(json.String(strings.clone(string(cstring(&buf[0])), alloc)))
		}

		if iwinfo_call_str(ops.encryption, dev, &buf[0]) {
			crypto := cast(^Iwinfo_Crypto)(&buf[0])
			enc := make(json.Object, 4, alloc)
			enc["enabled"] = json.Value(json.Integer(crypto.enabled != 0 ? 1 : 0))
			if crypto.enabled != 0 {
				if crypto.wpa_version == 0 {
					iwinfo_add_bit_array(&enc, "wep", u32(crypto.auth_algs), g_iw_auth_names, IWINFO_AUTH_COUNT, true, 0, alloc)
				} else {
					wpa := make([dynamic]json.Value, 0, 3, alloc)
					for v in 1 ..= 3 {
						if (u32(crypto.wpa_version) & (u32(1) << uint(v - 1))) != 0 {
							append(&wpa, json.Value(json.Integer(v)))
						}
					}
					enc["wpa"] = json.Value(json.Array(wpa))
					iwinfo_add_bit_array(
						&enc,
						"authentication",
						u32(crypto.auth_suites),
						g_iw_kmgmt_names,
						IWINFO_KMGMT_COUNT,
						true,
						IWINFO_KMGMT_NONE,
						alloc,
					)
				}
				iwinfo_add_bit_array(
					&enc,
					"ciphers",
					u32(crypto.pair_ciphers) | u32(crypto.group_ciphers),
					g_iw_cipher_names,
					IWINFO_CIPHER_COUNT,
					true,
					IWINFO_CIPHER_NONE,
					alloc,
				)
			}
			obj["encryption"] = json.Value(enc)
		}
	}

	return obj, true
}
