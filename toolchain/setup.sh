#!/usr/bin/env bash
# 用 brew 建立 Odin -> ImmortalWrt 25.12 / MT7986(aarch64_cortex-a53) 的交叉开发环境
#
# ---------------------------------------------------------------------------
# 为什么需要这个脚本（三条实测结论，决定了它的形态）
#
# 1) ImmortalWrt 25.12.2 的 SDK 解压后，staging_dir/target-aarch64_cortex-a53_musl
#    是个空壳（0 个文件），既没有 libuci/libubus/libubox 的头文件，也没有 .so，
#    连 bin/ 预编译包仓库都没有。SDK 里唯一齐全的是 toolchain-* 目录下的
#    libc.so / crt1.o / ld-musl-aarch64.so.1。
#
# 2) 25.12 的包格式已从 .ipk 换成 .apk，而且是 apk-tools 3.x 的 ADB 二进制格式
#    （文件头 magic = "ADBd"），不是 tar.gz，macOS 上拿不到现成解包工具。
#
# 3) 所以取库的唯一干净路径是：按 SDK 里 feeds.conf.default 钉死的 commit 拉源码，
#    用 zig cc 交叉编译。commit 来自图片包版本号，与设备上跑的库完全同源。
#
# 编译出来的 .so 只在链接期当符号来源用；运行时设备上有真的同名库（SONAME 一致，
# 所以构建时必须用同一个 commit，否则 SONAME 可能对不上）。
#
# ---------------------------------------------------------------------------
# 依赖（都由 brew 提供）
#   brew install zig cmake
#   odin 已由 brew 安装（brew install odin）
#
# 产物（默认 $HOME/openwrt-sdks/sysroot-aarch64_cortex-a53）
#   usr/include/{uci.h,libubus.h,libubox/*.h}
#   usr/lib/lib{ubox,ubus,uci}.so*
#
# 用法
#   ./setup.sh              # 拉源码 + 交叉编译 + 装进 sysroot（幂等，可重复跑）
#   ./setup.sh --clean      # 先清掉源码与构建目录再重来
# ---------------------------------------------------------------------------

set -euo pipefail

ARCH="${ARCH:-aarch64_cortex-a53}"
TARGET="${TARGET:-aarch64-linux-musl}"

ZIG="${ZIG:-/opt/homebrew/bin/zig}"
CMAKE="${CMAKE:-/opt/homebrew/bin/cmake}"
GIT="${GIT:-git}"

SYSROOT="${OPENWRT_SYSROOT:-$HOME/openwrt-sdks/sysroot-$ARCH}"
SRC="${OPENWRT_SRC:-$HOME/openwrt-sdks/src}"
WORK="${OPENWRT_LIB_BUILD:-$HOME/openwrt-sdks/build-libs}"

PREFIX="$SYSROOT/usr"

# 与 ImmortalWrt 25.12.2 aarch64_cortex-a53 包里同源的源码版本
# （从 package/*/Makefile 的 PKG_SOURCE_VERSION / PKG_VERSION 提取）
#
# json-c 不在原始计划里，是 libubox 逼出来的：libubox 的 CMakeLists 第 18 行写死了
#   PKG_SEARCH_MODULE(JSONC json-c REQUIRED)
# 而第 96-100 行的 ABIVERSION 块会无条件给 json_script / blobmsg_json 两个 target
# 设属性，找不到 json-c 时这两个 target 不存在，configure 阶段直接报错。
# 所以 -DJSONC=OFF 之类的开关对它无效，必须真的把 json-c 编出来。
JSONC_REPO="https://github.com/json-c/json-c.git"
JSONC_COMMIT="json-c-0.18"
LIBUBOX_REPO="https://github.com/openwrt/libubox.git"
LIBUBOX_COMMIT="7dd127841e82eb1cfb61185da37dde7b9bd9ba6d"
UCI_REPO="https://github.com/openwrt/uci.git"
UCI_COMMIT="66127cd76c5d0bd46d5a90302cc6110f53a4e2f8"
UBUS_REPO="https://github.com/openwrt/ubus.git"
UBUS_COMMIT="24864e7840b3a02a9ef76284a373f6b2f00b8a9b"

if [[ "${1:-}" == "--clean" ]]; then
  echo "== 清理 $SRC 与 $WORK =="
  rm -rf "$SRC" "$WORK"
fi

# ---------------------------------------------------------------------------
# 0. 依赖自检
# ---------------------------------------------------------------------------
missing=()
for tool in "$ZIG" "$CMAKE"; do
  [[ -x "$tool" ]] || missing+=("$tool")
done
if [[ ${#missing[@]} -gt 0 ]]; then
  cat >&2 <<EOF
缺少工具：${missing[*]}

  brew install zig cmake     # zig 当交叉编译器，cmake 驱动三个库的构建
  brew install odin          # Odin 本体
EOF
  exit 1
fi

echo "== 环境 =="
echo "   zig     : $("$ZIG" version)"
echo "   cmake   : $("$CMAKE" --version | head -1)"
echo "   目标    : $TARGET ($ARCH)"
echo "   sysroot : $SYSROOT"
echo

mkdir -p "$SRC" "$WORK/bin" "$PREFIX"

# ---------------------------------------------------------------------------
# 1. zig 的 cc / ar / ranlib 包装脚本
#    cmake 只能接受单个可执行文件作为编译器，而 zig 需要 "zig cc -target ..."
#    两个词，所以必须包一层。
# ---------------------------------------------------------------------------
cat > "$WORK/bin/zigcc" <<EOF
#!/bin/sh
exec "$ZIG" cc -target $TARGET "\$@"
EOF
cat > "$WORK/bin/zigar" <<EOF
#!/bin/sh
exec "$ZIG" ar "\$@"
EOF
cat > "$WORK/bin/zigranlib" <<EOF
#!/bin/sh
exec "$ZIG" ranlib "\$@"
EOF
chmod +x "$WORK/bin/zigcc" "$WORK/bin/zigar" "$WORK/bin/zigranlib"

# 交叉编译工具链文件。
# FIND_ROOT_PATH 指到自己的 prefix，这样 ubus/uci 找依赖的 libubox 时
# 只会在我们的 sysroot 里找，不会误撞到 macOS 上的同名库。
cat > "$WORK/aarch64.cmake" <<EOF
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)
set(CMAKE_C_COMPILER "$WORK/bin/zigcc")
set(CMAKE_AR "$WORK/bin/zigar")
set(CMAKE_RANLIB "$WORK/bin/zigranlib")
set(CMAKE_FIND_ROOT_PATH "$PREFIX")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
EOF

# ---------------------------------------------------------------------------
# 2. 按 commit 取源码（幂等）
# ---------------------------------------------------------------------------
fetch_src() { # name repo commit
  # 必须拆成多条 local：macOS 自带 bash 3.2 会把一条 local 里所有右值先算完
  # 再赋值，dir="$SRC/$name" 里的 $name 那时还没值，set -u 下会直接报错。
  local name="$1"
  local repo="$2"
  local commit="$3"
  local dir="$SRC/$name"

  if [[ ! -d "$dir/.git" ]]; then
    mkdir -p "$dir"
    "$GIT" -C "$dir" init -q
    "$GIT" -C "$dir" remote add origin "$repo"
  fi

  # commit 既可能是 SHA（libubox/uci/ubus）也可能是 tag（json-c），
  # 统一先解析成 SHA 再 detached checkout。
  # 不能直接 `git checkout --detach <tag>`：本地已有同名 tag 时 git 会做 DWIM
  # 尝试建分支，报 "--detach 不能和 -b/-B/--orphan 同时使用"。
  local sha
  sha=$("$GIT" -C "$dir" rev-parse --verify --quiet "$commit^{commit}" || true)
  if [[ -z "$sha" ]]; then
    echo "   拉取 $name@$commit ..."
    "$GIT" -C "$dir" fetch -q --depth 1 origin "$commit"
    sha=$("$GIT" -C "$dir" rev-parse FETCH_HEAD)
  fi

  "$GIT" -C "$dir" checkout -q --detach "$sha"
  "$GIT" -C "$dir" clean -qfd
}

build_lib() { # name abiversion（abiversion 传 - 表示该库不设 SONAME 后缀）
  local name="$1"
  local abiver="$2"
  local dir="$SRC/$name"
  local bdir="$WORK/build-$name"

  local abi_args=()
  if [[ "$abiver" != "-" ]]; then
    abi_args=(-DABIVERSION="$abiver")
  fi

  echo "== 构建 $name ${abiver:+(ABIVERSION=$abiver)} =="
  rm -rf "$bdir"
  mkdir -p "$bdir"

  # CMAKE_LINK_DEPENDS_USE_LINKER=OFF 是必须的：
  # cmake 3.27+ 默认会给链接命令加 `-Xlinker --dependency-file=...`，
  # 而 zig 0.16 在链接较大的共享库时遇到这个参数会直接段错误（实测退出码 139，
  # 报 "Error running link command: Segmentation fault"）。关掉后 cmake 改用
  # 构建后的独立步骤生成依赖，效果一样但不碰链接器。
  #
  # ABIVERSION 决定 SONAME 后缀，必须与设备上的库完全一致，否则运行时
  # 动态加载器按 libuci.so.20250120 去找、而我们的库没有这个 SONAME 就对不上。
  # 三个值取自 package/*/Makefile 的 PKG_ABI_VERSION，与包名里的数字一致
  # （如 libuci20250120-...apk）。
  #
  # DISABLE_EXTRA_LIBS=TRUE 是 OpenWrt 对 json-c 用的开关（见
  # package/libs/libjson-c/Makefile 的 CMAKE_OPTIONS），其它库不认识这个 -D，
  # cmake 只会忽略，所以可以统一传。
  "$CMAKE" -S "$dir" -B "$bdir" \
    -DCMAKE_TOOLCHAIN_FILE="$WORK/aarch64.cmake" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DCMAKE_LINK_DEPENDS_USE_LINKER=OFF \
    -DDISABLE_EXTRA_LIBS=TRUE \
    ${abi_args[@]+"${abi_args[@]}"} \
    -DLUAPATH=/usr/lib/lua \
    -DBUILD_LUA=OFF \
    -DBUILD_EXAMPLES=OFF \
    -DBUILD_STATIC=OFF \
    -DBUILD_TESTS=OFF \
    > "$bdir/configure.log" 2>&1 || { tail -30 "$bdir/configure.log" >&2; exit 1; }

  "$CMAKE" --build "$bdir" -j "$(sysctl -n hw.ncpu)" > "$bdir/build.log" 2>&1 \
    || { tail -40 "$bdir/build.log" >&2; exit 1; }

  "$CMAKE" --install "$bdir" > "$bdir/install.log" 2>&1 \
    || { tail -30 "$bdir/install.log" >&2; exit 1; }

  echo "   完成"
}

echo "== 拉取源码 =="
fetch_src json-c "$JSONC_REPO" "$JSONC_COMMIT"
fetch_src libubox "$LIBUBOX_REPO" "$LIBUBOX_COMMIT"
fetch_src uci "$UCI_REPO" "$UCI_COMMIT"
fetch_src ubus "$UBUS_REPO" "$UBUS_COMMIT"
echo

# ---------------------------------------------------------------------------
# pkg-config 隔离
# libubox 用 PKG_SEARCH_MODULE(JSONC json-c REQUIRED) 找 json-c，走的是 pkg-config。
# 必须把查询范围钉死在我们自己的 sysroot，否则 pkg-config 会去
# /opt/homebrew/lib/pkgconfig 找到 macOS 版的 json-c.pc，然后拿 Mach-O 的头文件
# 和库去链接 aarch64 目标。
#
# PKG_CONFIG_LIBDIR 会替换默认搜索路径（PKG_CONFIG_PATH 只是追加，所以不能用它），
# PKG_CONFIG_SYSROOT_DIR 则负责把 .pc 里的绝对路径重定向到 sysroot 下。
# ---------------------------------------------------------------------------
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR="$SYSROOT"
export PKG_CONFIG_PATH=""

# 顺序不能变：libubox 依赖 json-c，uci / ubus 依赖 libubox。
# 第二个参数是 PKG_ABI_VERSION，也就是 SONAME 里的版本后缀；
# json-c 在 OpenWrt 里没有走 ABIVERSION 机制，用 - 表示不传。
build_lib json-c -
build_lib libubox 20260213
build_lib uci 20250120
build_lib ubus 20251202

# ---------------------------------------------------------------------------
# 3. 头文件补齐
#    libubox 的 cmake 会把头装到 include/libubox/；uci.h 和 libubus.h 由 OpenWrt
#    的包 Makefile 安装，不一定在 cmake install 规则里，这里显式补一份。
# ---------------------------------------------------------------------------
echo "== 补齐头文件 =="
mkdir -p "$PREFIX/include/libubox"
cp -f "$SRC/uci/uci.h" "$PREFIX/include/" 2>/dev/null || true
cp -f "$SRC/ubus/libubus.h" "$PREFIX/include/" 2>/dev/null || true
cp -f "$SRC/libubox"/*.h "$PREFIX/include/libubox/" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 3.5 把 SDK 的 libc / crt / 解释器挂进本地 sysroot
#     到这一步 $SYSROOT 里只有 libuci/libubus/libubox，libc 相关的东西还缺。
#     挂上之后 $SYSROOT 就是一个自洽的交叉 sysroot：头文件统一在 include/，
#     库统一在 usr/lib 与 lib/，后续给自己写的 C 胶水代码编 obj 时不必再拼路径。
#
#     为什么用软链而不是复制：真实 libc.a 有 11 MB，复制一份既占磁盘又容易与
#     SDK 走样；软链让 sysroot 始终等于「SDK 的 libc + 我们自己编的三个库」。
#
#     注意（实测，别被目录结构骗了）：zig cc 编 musl 目标时并不会用这里的
#     libc.so —— 它固定取自己缓存的那份（`zig cc -###` 可见）。所以挂载的价值
#     在头文件与统一搜索根，而 ABI 兼容性的真正保障是两边 musl 版本一致，
#     该核对就在下面这段里做。
# ---------------------------------------------------------------------------
echo "== 挂载 SDK 的 libc =="
SDK="${SDK:-}"
if [[ -z "$SDK" ]]; then
  # 自动探测：$HOME/openwrt-sdks 下第一个解压好的 immortalwrt-sdk-*
  for d in "$HOME"/openwrt-sdks/immortalwrt-sdk-*; do
    if [[ -d "$d/staging_dir" ]]; then SDK="$d"; break; fi
  done
fi

TOOLCHAIN_DIR=""
if [[ -n "$SDK" && -d "$SDK/staging_dir" ]]; then
  TOOLCHAIN_DIR="$(find "$SDK/staging_dir" -maxdepth 1 -type d -name "toolchain-${ARCH}_*" | head -1)"
fi

if [[ -n "$TOOLCHAIN_DIR" && -f "$TOOLCHAIN_DIR/lib/libc.so" ]]; then
  # ln -sfn：$SYSROOT/lib 若已是软链，-n 让它替换软链本身而不是写进目标目录
  for d in lib include lib64; do
    [[ -e "$TOOLCHAIN_DIR/$d" ]] || continue
    ln -sfn "$TOOLCHAIN_DIR/$d" "$SYSROOT/$d"
  done
  echo "   $TOOLCHAIN_DIR/{lib,include,lib64} -> $SYSROOT/"
  ls -l "$SYSROOT/lib/libc.so" "$SYSROOT/lib/ld-musl-aarch64.so.1" "$SYSROOT/lib/crt1.o" \
    | sed 's/^/   /'

  # 挂上不等于用上：实测 zig cc 编 musl 目标时永远取它自己缓存的 libc.so 和
  # crt1.o（`zig cc -###` 可验证），sysroot 里的 libc.so 只在链接时被 -L 找到
  # 但不会被选中。既然最终跑的是设备上的 libc.so（NEEDED 只记 SONAME），
  # 真正决定 ABI 兼容的是「两边 musl 版本是否一致」。这里就核对这一条：
  # 不一致时链接可能引到设备 libc 里没有的符号，运行时才炸，必须构建期拦住。
  sdk_musl="$(strings -a "$TOOLCHAIN_DIR/lib/libc.so" 2>/dev/null | grep -oE '^1\.[0-9]+\.[0-9]+$' | head -1 || true)"
  # zig 自带的 musl 版本写在它的 musl 源码树里；brew 装的话在 Cellar 下，
  # 不依赖 readlink -f（macOS 上未必支持）。
  zig_musl=""
  for vh in \
    "$(brew --prefix zig 2>/dev/null)/lib/zig/libc/musl/src/internal/version.h" \
    /opt/homebrew/Cellar/zig/*/lib/zig/libc/musl/src/internal/version.h; do
    if [[ -f "$vh" ]]; then
      zig_musl="$(grep -oE '"[0-9]+\.[0-9]+\.[0-9]+"' "$vh" | tr -d '"' | head -1)"
      break
    fi
  done
  echo "   musl 版本：SDK ${sdk_musl:-未知} · zig 自带 ${zig_musl:-未知}"
  if [[ -n "$sdk_musl" && -n "$zig_musl" && "$sdk_musl" != "$zig_musl" ]]; then
    echo "   ⚠ 两边 musl 版本不一致：zig 链接时用的是它自带那份，可能与设备 libc 不同源。"
    echo "     要么换用与 SDK 同版本的 zig，要么只把本 sysroot 当链接期符号来源、"
    echo "     在 CI 里改用 SDK 自带 gcc 链接（build.sh 无参数分支）。"
  fi
else
  echo "   警告：没找到 SDK 的 toolchain-${ARCH}_*（设 SDK=... 或解压到 $HOME/openwrt-sdks/）"
  echo "         未挂 libc 时 build.sh --sdk 会退回不带 --sysroot 的链接（能过，但少了版本一致性核对）"
fi

# ---------------------------------------------------------------------------
# 4. 汇总
# ---------------------------------------------------------------------------
echo
echo "== sysroot 产物 =="
ls -1 "$PREFIX/include" 2>/dev/null | sed 's/^/  include\//'
echo "  ----"
for lib in ubox ubus uci; do
  found=$(ls "$PREFIX/lib/" 2>/dev/null | grep -E "^lib${lib}\.so" || true)
  if [[ -n "$found" ]]; then
    while read -r f; do echo "  lib/$f"; done <<< "$found"
  fi
done

echo
echo "== SONAME 核对（必须与设备上的库一致，运行时才会命中真库）=="
# otool 是 Mach-O 工具，读不了 ELF；用 llvm-readelf（brew install llvm 提供）
READELF="${READELF:-/opt/homebrew/opt/llvm/bin/llvm-readelf}"
if [[ -x "$READELF" ]]; then
  for lib in ubox ubus uci; do
    real=$(ls "$PREFIX/lib/lib${lib}.so."* 2>/dev/null | head -1 || true)
    [[ -z "$real" ]] && continue
    printf "  %-10s %s\n" "lib${lib}" "$("$READELF" -d "$real" | grep -o 'Library soname: \[[^]]*\]' | head -1)"
  done
else
  echo "  （未找到 llvm-readelf，跳过；brew install llvm 可启用）"
fi

echo
echo "完成。构建 spike 时指向这个 sysroot："
echo "  export OPENWRT_SYSROOT=\"$SYSROOT\""
echo "  cd spike/01-toolchain && ./build.sh --sdk"
