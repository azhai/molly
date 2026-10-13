#!/usr/bin/env bash
# 阶段 0 spike 构建：两阶段交叉编译，验证 Odin + OpenWrt sysroot C 库能链接。
#
# 用法： ./build.sh
# 环境： OPENWRT_SYSROOT  默认 $HOME/openwrt-sdks/sysroot-aarch64_cortex-a53
set -euo pipefail
cd "$(dirname "$0")"

ARCH="${ARCH:-aarch64_cortex-a53}"
SR="${OPENWRT_SYSROOT:-$HOME/openwrt-sdks/sysroot-$ARCH}"
OUT="out"
mkdir -p "$OUT"

if [[ ! -f "$SR/usr/lib/libuci.so" ]]; then
  echo "找不到 sysroot 里的 libuci.so：$SR" >&2
  exit 1
fi

echo "== 1. odin 编 arm64 目标文件（-o:size）=="
rm -f "$OUT"/spike*.o
odin build src \
  -build-mode:obj \
  -target:linux_arm64 \
  -o:size \
  -out:"$OUT/spike.o"

shopt -s nullglob
OBJS=("$OUT"/spike*.o)
shopt -u nullglob
echo "   产出 ${#OBJS[@]} 个 .o"

echo "== 2. zig cc 收尾链接 sysroot（-luci -lubus -lubox）=="
# 历史硬约束：
#   - 不传 -Wl,-dynamic-linker（zig 对 musl 默认解释器即 /lib/ld-musl-aarch64.so.1）
#   - 只用相对 sysroot 的 -L/usr/lib（zig 的 lld 忽略 -Wl,-rpath-link，且 --sysroot 会拼 -L）
#   - libc 绝不静态；-Wl,-s 去符号缩体积
zig cc -target aarch64-linux-musl \
  --sysroot="$SR" \
  "${OBJS[@]}" \
  -L/usr/lib \
  -luci -lubus -lubox \
  -Wl,-s \
  -o "$OUT/spike-arm64"

echo
file "$OUT/spike-arm64"
echo "体积: $(ls -l "$OUT/spike-arm64" | awk '{print $5}') bytes"
echo "→ 产物在真机（aarch64/musl）上执行应打印 uci_alloc_context 的结果。"
