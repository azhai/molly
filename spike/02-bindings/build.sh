#!/usr/bin/env bash
# 阶段 1 集成 spike 构建：Odin(bindings) + 复用的 shim.c + sysroot C 库 → arm64 可执行。
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

ARCH="${ARCH:-aarch64_cortex-a53}"
SR="${OPENWRT_SYSROOT:-$HOME/openwrt-sdks/sysroot-$ARCH}"
OUT="$HERE/out"
mkdir -p "$OUT"

echo "== 1. odin 编 main + molly:backend/bindings 为 arm64 .o =="
rm -f "$OUT"/app*.o
odin build main.odin -file \
  -collection:molly="$ROOT/src" \
  -build-mode:obj -target:linux_arm64 -o:size \
  -out:"$OUT/app.o"

shopt -s nullglob; OBJS=("$OUT"/app*.o); shopt -u nullglob
echo "   odin 产出 ${#OBJS[@]} 个 .o"

echo "== 2. zig cc 编复用的 shim.c =="
zig cc -target aarch64-linux-musl --sysroot="$SR" -I"$SR/usr/include" \
  -O2 -ffunction-sections -fdata-sections \
  -c "$ROOT/src/native/shim.c" -o "$OUT/shim.o"

echo "== 3. zig cc 收尾链接（-luci -lubus -lblobmsg_json -lubox -ljson-c）=="
zig cc -target aarch64-linux-musl --sysroot="$SR" \
  "${OBJS[@]}" "$OUT/shim.o" \
  -L/usr/lib \
  -luci -lubus -lblobmsg_json -lubox -ljson-c \
  -Wl,-s \
  -o "$OUT/spike2-arm64"

echo
file "$OUT/spike2-arm64"
echo "体积: $(ls -l "$OUT/spike2-arm64" | awk '{print $5}') bytes"
