#!/usr/bin/env bash
# spike 01：Odin -> aarch64 OpenWrt（cortex-a53，musl，动态链接 libuci/libubus）
#
# 已实测的三条硬约束（决定了本脚本的形态）：
#   1) Odin 不支持交叉链接到 linux_arm64 / linux_amd64：
#      "Linking for cross compilation for this platform is not yet supported"
#   2) -linker: 只接受 default|lld|radlink|mold，无法指定 OpenWrt SDK 的 gcc
#   3) -build-mode:obj 的产物数量随优化等级变化：
#        debug（不带 -o:）  -> 按模块拆成多个 .o（本 spike 为 37 个）
#        -o:size / -o:speed -> 合并成单个 .o
#      两种情况都要正确收集，所以 glob 用 spike01*.o
#   => 唯一可行路径：Odin 只编 obj，链接完全交给 SDK 的 gcc
#
# 实测体积（aarch64 静态，含 uci/ubus 绑定）：
#   debug 未 strip 4.8 MB · -o:size + strip 587 KB · -o:speed + strip 602 KB
#
# 用法：
#   ./build.sh --sdk        # macOS 首选：本地 sysroot（SDK 同源 libc + 自编 uci/ubus/ubox）+ zig cc
#   ./build.sh              # 真机/CI：用 SDK 自带的 gcc 链接（需 Linux x86_64 环境）
#   ./build.sh --local      # 无 SDK 时的链路自检：zig cc + local/stubs.c
#   OPT=speed ./build.sh --sdk   # 换优化等级；GOSYMS=1 保留符号便于崩溃时定位
#
# 三条已实测的链接细节（踩过的坑，别改回去）：
#   a) 不能传 -Wl,-dynamic-linker：zig 构建 musl 的共享 libc 时会报
#      LldCannotSpecifyDynamicLinkerForSharedLibraries。而 zig 的默认解释器
#      就是 /lib/ld-musl-aarch64.so.1，正好和 OpenWrt 一致，不需要手动指定。
#   b) zig 的 lld 忽略 -Wl,-rpath-link（warning: rpath-link option is unimplemented），
#      所以只能靠 -L 指向 SDK staging，并且依赖 SDK 里的无版本号符号链接 libuci.so。
#   c) 链 OpenWrt 的 .so 时绝不能让 libc 走静态，否则进程里会出现两份 libc
#      （malloc/errno 状态分裂）。只要链了 .so，zig 就会输出 dynamically linked。

set -euo pipefail
cd "$(dirname "$0")"

ARCH="${ARCH:-aarch64_cortex-a53}"
TARGET_TRIPLE="aarch64-openwrt-linux-musl"
OPT="${OPT:-size}"
OUT="build"

# 保留符号（真机第一次跑想抓崩溃栈时用 GOSYMS=1）
if [[ "${GOSYMS:-0}" == "1" ]]; then
  STRIP_FLAG=""
else
  STRIP_FLAG="-Wl,-s"
fi

# ---------------------------------------------------------------------------
# 1. Odin 只编目标文件（不做链接）
# ---------------------------------------------------------------------------
rm -rf "$OUT"
mkdir -p "$OUT"

odin build src \
  -build-mode:obj \
  -target:linux_arm64 \
  -o:"$OPT" \
  -out:"$OUT/spike01.o"

# -o:size / -o:speed 只产出一个合并的 .o；debug 会按模块拆成多个。
# 用 spike01*.o 两种都能覆盖。
shopt -s nullglob
OBJS=("$OUT"/spike01*.o)
shopt -u nullglob

if [[ ${#OBJS[@]} -eq 0 ]]; then
  echo "没有产出目标文件，检查上一步的 Odin 报错" >&2
  exit 1
fi
echo "== Odin 产出 ${#OBJS[@]} 个 aarch64 目标文件（-o:${OPT}）=="

# ---------------------------------------------------------------------------
# 2a. 本地模式：zig cc 自带 musl sysroot，stubs.c 顶替 libuci/libubus
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "--local" ]]; then
  echo "== 本地模式：zig cc 当链接器 =="
  # shellcheck disable=SC2086
  zig cc -target aarch64-linux-musl \
    -o "$OUT/spike01-aarch64" \
    "${OBJS[@]}" local/stubs.c -lm $STRIP_FLAG
  file "$OUT/spike01-aarch64"
  echo "体积: $(ls -l "$OUT/spike01-aarch64" | awk '{print $5}') bytes"
  echo
  echo "注意：本地模式只能证明「obj -> 外部链接器 -> aarch64 ELF」成立，"
  echo "      uci/ubus 走的是桩函数，必须到真机或 qemu 上跑才算验收通过。"
  exit 0
fi

# ---------------------------------------------------------------------------
# 2b. SDK 模式（macOS 首选）
#     不执行 SDK 里的任何 Linux x86_64 二进制，只把它当文件仓库：
#       - libc 头文件 / crt / 解释器：由 setup.sh 软链进本地 sysroot（保证与设备同源可查）
#       - libuci / libubus / libubox：toolchain/setup.sh 按设备包版本交叉编译进本地 sysroot
#     合起来就是一个完整交叉 sysroot，链接由 zig cc 完成（见文件头 a/b/c 三条）。
#     注意 zig 的 libc 永远取自带那份（实测），好在两版 musl 版本一致，见下方注释。
#
#     注意：ImmortalWrt 25.12.2 的 SDK 里，staging_dir/target-aarch64_cortex-a53_musl
#     是空壳（0 个文件），既没有 uci/ubus 的头文件也没有 .so，连 bin/ 预编译包
#     仓库都没有，25.12 的 .apk 还是 apk-tools 3.x 的 ADB 格式解不开。
#     所以这几个库必须自己编，见 repo 根的 toolchain/setup.sh。
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "--sdk" ]]; then
  # SDK 在这里已经不再是链接期的必需品：它能提供的 libc / crt1.o /
  # ld-musl-aarch64.so.1，已被 toolchain/setup.sh 软链进本地 sysroot。
  # 所以没设 SDK 也能构建，只是提示一句。
  SDK="${SDK:-}"
  if [[ -z "$SDK" ]]; then
    echo "（未设 SDK：本次只用本地 sysroot；SDK 只在 toolchain/setup.sh 里需要用）" >&2
  fi

  # 本地 sysroot：libuci / libubus / libubox + （setup.sh 挂进来的）SDK libc
  OPENWRT_SYSROOT="${OPENWRT_SYSROOT:-$HOME/openwrt-sdks/sysroot-$ARCH}"
  LIBS_DIR="$OPENWRT_SYSROOT/usr/lib"
  if [[ ! -f "$LIBS_DIR/libuci.so" ]]; then
    cat >&2 <<EOF
找不到 $LIBS_DIR/libuci.so

先跑一次环境搭建脚本（按 ImmortalWrt 25.12.2 的精确版本交叉编译这几个库）：
  ../../toolchain/setup.sh
EOF
    exit 1
  fi

  # zig 的 --sysroot 会把 -L 的路径也拼在 sysroot 之后：实测绝对路径会被拼成
  #   $sysroot/Users/ryan/openwrt-sdks/sysroot-.../usr/lib   （找不到）
  # 相对路径 usr/lib 又不被解析。唯一可行的是 -L/usr/lib —— 以 sysroot 为根。
  #
  # 一个实测得到的结论，免得后来者误判：zig cc 对 musl 目标永远用自己那份 libc
  # （`zig cc -###` 可见走 ~/.cache/zig/o/*/libc.so 与 crt1.o），--sysroot 里的
  # libc.so 不会参与链接。所以「加了 sysroot = 用了 SDK 的 libc」是错的。
  # 之所以仍然安全：SDK 的 libc 是 musl 1.2.5，zig 0.16 自带的也是 1.2.5，
  # 且运行时由设备上的 /lib/libc.so 接管（NEEDED 只记 SONAME=libc.so）。
  # sysroot 的作用是统一头文件与库的搜索根，脚本末段的版本一致性核对负责兜底。
  if [[ "${NOSYSROOT:-0}" != "1" ]] &&
     { [[ -f "$OPENWRT_SYSROOT/lib/libc.so" ]] || [[ -f "$OPENWRT_SYSROOT/usr/lib/libc.so" ]]; }; then
    SYSROOT_ARGS=(--sysroot="$OPENWRT_SYSROOT")
    LIB_ARGS=(-L/usr/lib)
    LIBC_DESC="zig 自带 musl（版本一致性由 toolchain/setup.sh 核对；运行时装设备上的 libc.so）"
  else
    SYSROOT_ARGS=()
    LIB_ARGS=(-L"$LIBS_DIR")
    LIBC_DESC="zig 自带 musl（sysroot 未启用）"
  fi

  echo "== SDK 模式 =="
  echo "   sysroot   : $OPENWRT_SYSROOT ${SYSROOT_ARGS[@]+[${SYSROOT_ARGS[*]}]}"
  echo "   libc 来源 : $LIBC_DESC"
  echo "   库搜索路径: ${LIB_ARGS[*]}"

  # shellcheck disable=SC2086
  # SYSROOT_ARGS / LIB_ARGS 可能为空数组，macOS 自带 bash 3.2 在 set -u 下不能
  # 直接展开空数组，必须用 ${ARR[@]+"${ARR[@]}"} 这个可移植写法。
  zig cc -target aarch64-linux-musl \
    ${SYSROOT_ARGS[@]+"${SYSROOT_ARGS[@]}"} \
    -o "$OUT/spike01" "${OBJS[@]}" \
    ${LIB_ARGS[@]+"${LIB_ARGS[@]}"} \
    -luci -lubus -lubox \
    $STRIP_FLAG

  echo
  file "$OUT/spike01"
  echo "体积: $(ls -l "$OUT/spike01" | awk '{print $5}') bytes"
  echo
  echo "下一步：scp $OUT/spike01 到设备，然后 ./run.sh build/spike01"
  exit 0
fi

# ---------------------------------------------------------------------------
# 2c. 真机/CI 模式：OpenWrt SDK 自带工具链 + 真实 libuci/libubus
#     需要 Linux x86_64 环境（SDK 里的 gcc 是 Linux 二进制）
# ---------------------------------------------------------------------------
SDK="${SDK:-}"
if [[ -z "$SDK" ]]; then
  echo "请先下载 OpenWrt SDK 并 export SDK=/path/to/openwrt-sdk-...-Linux-x86_64" >&2
  echo "（SDK 是 Linux x86_64 的，macOS 上要么用容器跑，要么在 Linux 机器/CI 上跑）" >&2
  exit 1
fi

TOOLCHAIN_DIR="$(find "$SDK/staging_dir" -maxdepth 1 -type d -name "toolchain-${ARCH}_*" | head -1)"
STAGING="$SDK/staging_dir/target-${ARCH}_musl"
CC="$TOOLCHAIN_DIR/bin/${TARGET_TRIPLE}-gcc"

if [[ ! -x "$CC" ]]; then
  echo "找不到交叉编译器：$CC" >&2
  echo "可用工具链目录：" >&2
  ls "$SDK/staging_dir" >&2
  exit 1
fi

echo "== 用 $CC 链接 =="
# shellcheck disable=SC2086
"$CC" -o "$OUT/spike01" "${OBJS[@]}" \
  -L"$STAGING/usr/lib" \
  -Wl,-rpath-link,"$STAGING/usr/lib" \
  -luci -lubus -lubox \
  -lm -lpthread $STRIP_FLAG

echo
file "$OUT/spike01"
echo "体积: $(ls -l "$OUT/spike01" | awk '{print $5}') bytes"
echo
echo "下一步：./run.sh build/spike01"
