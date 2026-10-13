#!/usr/bin/env bash
# molly —— Odin 构建入口（阶段 5 接线）。
#
# 语言无关的黑盒验收（tests/smoke.sh、tests/device_*.sh）都从这里取产物：
#   ./build.sh --host     本机（darwin）自测二进制 → build/molly-host
#   ./build.sh --target   交叉编译设备产物          → build/molly-arm64（linux/arm64 + musl）
#   ./build.sh --all      两个都编
#
# 交叉是**两段式**（Odin 不能交叉链接 linux/arm64：-linker 不吃 SDK 的 gcc，只产 .o）：
#   1) odin build src -build-mode:obj -target:linux_arm64 -o:size  → build/molly_arm64.o
#   2) zig cc -target aarch64-linux-musl 收尾：编 src/native/shim.c 得 shim.o，
#      再把 Odin 目标文件 + shim.o + 总线/uci 库链成可执行。
# 硬约束（历史实测，逐条落地）：
#   - 不传 -Wl,-dynamic-linker（musl 的动态由 zig 的 crt 负责）；
#   - 只给相对 sysroot 的 -L/usr/lib（-Wl,-rpath-link 被 zig 的 lld 忽略）；
#   - libc 绝不静态（不 -static）；
#   - 显式 -lblobmsg_json（ubus 的 JSON 互转在这条独立库里）；
#   - 库序 uci ubus blobmsg_json → ubox json-c（被依赖者在后）。
#
# 可用环境变量覆盖：ODIN / ZIG / OPENWRT_SYSROOT。
set -euo pipefail
cd "$(dirname "$0")"

ODIN=${ODIN:-odin}
ZIG=${ZIG:-zig}
SYSROOT=${OPENWRT_SYSROOT:-$HOME/openwrt-sdks/sysroot-aarch64_cortex-a53}

BIN=build
HOST_BIN=$BIN/molly-host
TARGET_BIN=$BIN/molly-arm64
TARGET_OBJ=$BIN/molly_arm64.o
SHIM_OBJ=$BIN/shim_arm64.o
ARM64_TARGET=aarch64-linux-musl

# 目标 CPU tune（换设备只改这里）：Odin 侧无 Go 的 GOARM64，指令基线由 zig 的
# -target/-mcpu 决定；cortex-a53 无 LSE，用基础 aarch64 即可。
TARGET_CPU=${TARGET_CPU:-cortex_a53}

mkdir -p "$BIN"

build_host() {
	echo "==> Odin host（darwin，假数据后端，自测/冒烟用）"
	"$ODIN" build src \
		-collection:molly=src \
		-out:"$HOST_BIN"
	echo "→ $HOST_BIN"
}

check_toolchain() {
	command -v "$ZIG" >/dev/null 2>&1 || { echo "找不到 $ZIG（交叉编译当 C 编译器用）：覆盖 ZIG=/path/to/zig"; exit 1; }
	[ -d "$SYSROOT/usr/include" ] || { echo "找不到 sysroot：$SYSROOT（要含 libubus/libuci/libubox 的头与库）：覆盖 OPENWRT_SYSROOT=..."; exit 1; }
	[ -f "$SYSROOT/usr/lib/libubus.so" ] || echo "  注意：$SYSROOT/usr/lib 下无 libubus.so，链接可能过不去"
}

build_target() {
	check_toolchain
	echo "==> 段1：Odin → linux/arm64 目标文件（只编不链，-o:size 缩体积）"
	"$ODIN" build src \
		-collection:molly=src \
		-build-mode:obj \
		-target:linux_arm64 \
		-o:size \
		-out:"$TARGET_OBJ"

	echo "==> 段2a：zig cc 编 C shim（src/native/shim.c）"
	"$ZIG" cc -target "$ARM64_TARGET" -mcpu="$TARGET_CPU" \
		--sysroot="$SYSROOT" -I"$SYSROOT/usr/include" -Isrc/native \
		-O2 -ffunction-sections -fdata-sections \
		-c src/native/shim.c -o "$SHIM_OBJ"

	echo "==> 段2b：zig cc 链接（Odin .o + shim.o + 总线/uci 库）"
	"$ZIG" cc -target "$ARM64_TARGET" -mcpu="$TARGET_CPU" \
		--sysroot="$SYSROOT" \
		-L/usr/lib \
		-o "$TARGET_BIN" \
		"$TARGET_OBJ" "$SHIM_OBJ" \
		-Wl,--gc-sections -Wl,-s \
		-luci -lubus -lblobmsg_json -lubox -ljson-c \
		-lm -lpthread
	echo "→ $TARGET_BIN  [linux/arm64 · $ARM64_TARGET · musl · $SYSROOT]"
}

mode="${1:---host}"
case "$mode" in
	--host)   build_host ;;
	--target) build_target ;;
	--all)    build_host; build_target ;;
	-h|--help)
		sed -n '2,25p' "$0" ;;
	*)
		echo "用法：$0 [--host|--target|--all]"; exit 2 ;;
esac
