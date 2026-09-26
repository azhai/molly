#!/usr/bin/env bash
# molly —— 用 Odin 复刻 ImmortalWrt LuCI 的服务端替换层
#
# 为什么必须是两个构建模式：
#   --host    macOS 原生可执行文件，用于开发与自测。HTTP / 路由 / dispatcher 全是
#             真代码，只有 uci/ubus 走 src/backend/darwin.odin 的假数据（#+build darwin）。
#             于是无需设备就能用 curl 跑通整套路由。
#   --target  aarch64 / ImmortalWrt 25.12.2（aarch64_cortex-a53，musl，动态链接）：
#             Odin 只编目标文件，链接交给 zig cc。
#
# 为什么目标平台必须两段式（实测硬约束，别改成一步）：
#   1) Odin 不支持交叉链接到 linux_arm64：
#      "Linking for cross compilation for this platform is not yet supported"
#   2) -linker: 只接受 default|lld|radlink|mold，无法指定 SDK 的 gcc
#
# 链接细节（踩过的坑，别改回去）：
#   a) 不能传 -Wl,-dynamic-linker：zig 构建 musl 共享 libc 时报
#      LldCannotSpecifyDynamicLinkerForSharedLibraries。zig 默认解释器就是
#      /lib/ld-musl-aarch64.so.1，与设备一致，无需手动指定。
#   b) zig 的 lld 忽略 -Wl,-rpath-link，只能靠 -L 指向 sysroot。
#   c) 绝不能让 libc 走静态，否则进程里会出现两份 libc。
#   d) -lblobmsg_json 必须显式加：ubus 的 JSON 互转用
#      blobmsg_add_json_from_string / blobmsg_format_json_with_cb，它们不在
#      libubox.so 里，而在独立的 libblobmsg_json.so（SONAME .20260213）。
#   e) 库顺序按依赖排：uci/ubus 依赖 ubox，blobmsg_json 依赖 ubox 与 json-c。
#
# 用法：
#   ./build.sh --host              # macOS 本地开发与自测
#   ./build.sh --target            # aarch64 产物 build/molly
#   OPT=speed ./build.sh --target  # 换优化等级（默认 size）
#   GOSYMS=1 ./build.sh --target   # 保留符号，便于真机抓崩溃栈
#
# 环境：
#   OPENWRT_SYSROOT  默认 $HOME/openwrt-sdks/sysroot-aarch64_cortex-a53
#                    （由 toolchain/setup.sh 生成）

set -euo pipefail
cd "$(dirname "$0")"

ARCH="${ARCH:-aarch64_cortex-a53}"
OPT="${OPT:-size}"
OUT="build"
MODE="${1:-}"

# 保留符号（真机第一次跑想抓崩溃栈时用 GOSYMS=1）
if [[ "${GOSYMS:-0}" == "1" ]]; then
  STRIP_FLAG=""
else
  STRIP_FLAG="-Wl,-s"
fi

if [[ "$MODE" != "--host" && "$MODE" != "--target" ]]; then
  cat >&2 <<'EOF'
用法：./build.sh --host     # macOS 原生（uci/ubus 走假数据）
      ./build.sh --target   # aarch64 / ImmortalWrt 目标
EOF
  exit 1
fi

mkdir -p "$OUT"

# ---------------------------------------------------------------------------
# 1. Odin 编译
#    -collection:molly=src  让子包写成 import "molly:http"，避免相对路径
# ---------------------------------------------------------------------------
if [[ "$MODE" == "--host" ]]; then
  echo "== host 模式（macOS 原生，uci/ubus 使用假数据）=="
  odin build src \
    -collection:molly=src \
    -debug \
    -out:"$OUT/molly-host"

  echo
  file "$OUT/molly-host"
  echo "体积: $(ls -l "$OUT/molly-host" | awk '{print $5}') bytes"
  echo
  echo "下一步：./$OUT/molly-host --listen 127.0.0.1:8080 --docroot tests/fixtures/www"
  exit 0
fi

# ---------------------------------------------------------------------------
# 2. target 模式：Odin 只编目标文件
# ---------------------------------------------------------------------------
echo "== Odin 编译 aarch64 目标文件（-o:${OPT}）=="
# 注意 $VAR 后面紧跟全角标点必须写成 ${VAR}：bash 会把全角字符的字节当成
# 变量名的一部分，报 "OPT?: unbound variable"。
rm -f "$OUT"/molly*.o
odin build src \
  -collection:molly=src \
  -build-mode:obj \
  -target:linux_arm64 \
  -o:"$OPT" \
  -out:"$OUT/molly.o"

# -o:size / -o:speed 一般只产出一个合并的 .o，debug 会按 package 拆成多个，
# 每新增一个 package 就多一个 .o。glob 覆盖两种情况。
shopt -s nullglob
OBJS=("$OUT"/molly*.o)
shopt -u nullglob

if [[ ${#OBJS[@]} -eq 0 ]]; then
  echo "没有产出目标文件，检查上一步的 Odin 报错" >&2
  exit 1
fi
echo "   产出 ${#OBJS[@]} 个目标文件"

# ---------------------------------------------------------------------------
# 3. target 模式：zig cc 收尾链接
#    sysroot 由 toolchain/setup.sh 生成：libuci/libubus/libubox/libblobmsg_json
#    + SDK 的 libc 头与 crt。
#
#    注意：zig 的 --sysroot 会把 -L 的路径也拼在 sysroot 之后（实测绝对路径会被
#    拼成 $sysroot/Users/ryan/...），所以只能用 -L/usr/lib 这种以 sysroot 为根
#    的写法。另外 zig cc 对 musl 目标永远用自己缓存的 libc.so 与 crt1.o
#    （`zig cc -###` 可验证），sysroot 里的 libc.so 不参与链接；两边 musl 版本
#    一致（1.2.5）由 toolchain/setup.sh 核对，运行时由设备的 libc.so 接管。
# ---------------------------------------------------------------------------
OPENWRT_SYSROOT="${OPENWRT_SYSROOT:-$HOME/openwrt-sdks/sysroot-$ARCH}"
if [[ ! -f "$OPENWRT_SYSROOT/usr/lib/libuci.so" ]]; then
  cat >&2 <<EOF
找不到 $OPENWRT_SYSROOT/usr/lib/libuci.so

先跑一次环境搭建脚本（按 ImmortalWrt 25.12.2 的精确版本交叉编译这几个库）：
  ./toolchain/setup.sh
EOF
  exit 1
fi

echo "== zig cc 链接 =="
echo "   sysroot : $OPENWRT_SYSROOT"

# 库顺序按依赖排：uci/ubus 依赖 ubox，blobmsg_json 依赖 ubox 与 json-c
zig cc -target aarch64-linux-musl \
  --sysroot="$OPENWRT_SYSROOT" \
  -o "$OUT/molly" "${OBJS[@]}" \
  -L/usr/lib \
  -luci -lubus -lblobmsg_json -lubox \
  $STRIP_FLAG

echo
file "$OUT/molly"
echo "体积: $(ls -l "$OUT/molly" | awk '{print $5}') bytes"
echo
echo "核验 ELF："
READELF="${READELF:-/opt/homebrew/opt/llvm/bin/llvm-readelf}"
if [[ -x "$READELF" ]]; then
  "$READELF" -h "$OUT/molly" | grep -E 'Class|Machine|Type' | sed 's/^/  /'
  "$READELF" -l "$OUT/molly" | grep -i interpreter | sed 's/^/  /'
  "$READELF" -d "$OUT/molly" | grep NEEDED | sed 's/^/  /'
else
  echo "  （未找到 llvm-readelf，跳过；brew install llvm 可启用）"
fi
echo
echo "下一步：scp $OUT/molly 到设备（建议先用 --listen 0.0.0.0:8081 与原厂 uhttpd 并行观察）"