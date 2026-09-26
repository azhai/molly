# 开发环境搭建（Homebrew → aarch64 / musl）

本文记录"为什么这样搭"和"踩过哪些坑"。**权威实现是 [`toolchain/setup.sh`](../toolchain/setup.sh)**，本文只解释它的每一处取舍；两者冲突时以脚本为准。

## 0. 适用范围

主机：macOS arm64 + Homebrew。产物：ImmortalWrt 25.12.2 / `aarch64_cortex-a53` / musl 1.2.5 上能跑的动态链接 ELF。

目标是**本地能编、能自测，真机只负责跑**：HTTP、路由、dispatcher 全是平台无关代码，只有 uci/ubus 在 macOS 上换成假数据（`src/backend/darwin.odin`）。所以整套路由在 Mac 上就能用 curl 验证。

## 1. 依赖（全部由 brew 提供）

| 工具 | 实测版本 | 用途 |
|---|---|---|
| `odin` | `dev-2026-09:a2fb372b7` | 编译本体；必须支持 `-target:linux_arm64` 与 `-build-mode:obj` |
| `zig` | `0.16.0` | 交叉编译器 + 最终链接器（`zig cc -target aarch64-linux-musl`） |
| `cmake` | `4.4.3` | 驱动 json-c / libubox / uci / ubus 的构建 |
| `llvm` | — | 只为 `llvm-readelf`（`/opt/homebrew/opt/llvm/bin/llvm-readelf`），核验 ELF 与 SONAME |

```bash
brew install odin zig cmake llvm
```

`setup.sh` 与 `build.sh` 都会做工具自检，缺哪个就报哪个；两个脚本都能用环境变量覆盖路径（见 §7）。

## 2. 为什么不能直接用 25.12 SDK 里的预编译库

三条实测结论，决定了整个方案只能"自己编"：

1. **SDK 的 `staging_dir/target-aarch64_cortex-a53_musl` 是个空壳**（0 个文件）：既没有 libuci/libubus/libubox 的头文件，也没有 `.so`，连 `bin/` 的预编译包仓库都没有。SDK 里唯一齐全的是 `staging_dir/toolchain-*` 下的 `libc.so` / `crt1.o` / `ld-musl-aarch64.so.1`。
2. **25.12 的包格式从 `.ipk` 换成了 `.apk`**，而且是 apk-tools 3.x 的 ADB 二进制格式（文件头 magic 是 `ADBd`），不是 tar.gz。macOS 上没有现成解包工具。
3. 于是取库的唯一干净路径是：**按 SDK 里 `feeds.conf.default` 钉死的 commit 拉源码，用 `zig cc` 交叉编译**。commit 来自包的版本号，与设备上跑的库完全同源。

编出来的 `.so` **只在链接期当符号来源**。运行时用的是设备上的同名库——两边 SONAME 一致才能命中，所以"必须用同一个 commit"是硬约束，不是洁癖。

## 3. `setup.sh` 做了什么

幂等，可反复跑；`./toolchain/setup.sh --clean` 先清掉源码与构建目录再重来。

### 3.1 编译四个库（顺序不能变）

| 库 | 仓库 | 版本（钉死） | SONAME 后缀 |
|---|---|---|---|
| json-c | `github.com/json-c/json-c` | tag `json-c-0.18` | 无 ABIVERSION 机制（产 `libjson-c.so.5`） |
| libubox | `github.com/openwrt/libubox` | `7dd127841e82eb1cfb61185da37dde7b9bd9ba6d` | `20260213` |
| uci | `github.com/openwrt/uci` | `66127cd76c5d0bd46d5a90302cc6110f53a4e2f8` | `20250120` |
| ubus | `github.com/openwrt/ubus` | `24864e7840b3a02a9ef76284a373f6b2f00b8a9b` | `20251202` |

顺序：`json-c → libubox → uci / ubus`（libubox 依赖 json-c，uci/ubus 依赖 libubox）。

**json-c 是 libubox 逼出来的**：libubox 的 `CMakeLists.txt` 第 18 行写死了 `PKG_SEARCH_MODULE(JSONC json-c REQUIRED)`，第 96–100 行的 `ABIVERSION` 块又会无条件给 `json_script` / `blobmsg_json` 两个 target 设属性；找不到 json-c 时这两个 target 不存在，configure 阶段直接报错。`-DJSONC=OFF` 这类开关对它无效，必须真把 json-c 编出来。

**`ABIVERSION` 决定 SONAME 后缀**，取值必须与设备上的库完全一致（取自 `package/*/Makefile` 的 `PKG_ABI_VERSION`，与包名里的数字一致，如 `libuci20250120-*.apk`）。对不上就是运行时"按 `libuci.so.20250120` 找不到"。

### 3.2 交叉编译工具链包装（`$OPENWRT_LIB_BUILD/bin/`）

cmake 只接受**单个可执行文件**作为编译器，而 zig 需要 `zig cc -target aarch64-linux-musl` 两个词，所以包一层：

- `zigcc` / `zigar` / `zigranlib` —— 分别 `exec zig cc|ar|ranlib`
- `aarch64.cmake` —— `CMAKE_SYSTEM_NAME Linux` + 三个包装器；`CMAKE_FIND_ROOT_PATH` 指到自己的 prefix，这样 ubus/uci 找 libubox 时**只在自己 sysroot 里找**，不会误撞 macOS 上的同名库

### 3.3 两个必须的构建开关

- **`-DCMAKE_LINK_DEPENDS_USE_LINKER=OFF`**：cmake 3.27+ 默认给链接命令加 `-Xlinker --dependency-file=...`，zig 0.16 链接较大的共享库时遇到它会**直接段错误**（实测退出码 139，`Error running link command: Segmentation fault`）。关掉后 cmake 改用构建后的独立步骤生成依赖，效果一样但不碰链接器。
- **`-DBUILD_STATIC=OFF`**（连同 `BUILD_LUA/EXAMPLES/TESTS=OFF`）：只要动态库，减少无关产物。

### 3.4 pkg-config 隔离

libubox 通过 pkg-config 找 json-c。不隔离的话，它会在 `/opt/homebrew/lib/pkgconfig` 里找到 **macOS 版**的 `json-c.pc`，然后拿 Mach-O 的头文件和库去链接 aarch64 目标。

```bash
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig"  # 替换默认搜索路径
export PKG_CONFIG_SYSROOT_DIR="$SYSROOT"                                  # 把 .pc 里的绝对路径重定向进 sysroot
export PKG_CONFIG_PATH=""                                                 # 必须清空
```

注意是 `PKG_CONFIG_LIBDIR` 而不是 `PKG_CONFIG_PATH`——后者只是**追加**搜索路径，压不住默认路径。

## 4. sysroot 布局

默认 `$HOME/openwrt-sdks/sysroot-aarch64_cortex-a53`：

```
usr/include/            我们编的库的头：json-c/ libubox/ libubus.h ubus_common.h
                        ubusmsg.h uci.h uci_blob.h uci_config.h ucimap.h
usr/lib/                链接期符号来源（.so + .a）：
                        libblobmsg_json.so.20260213 · libubox.so.20260213
                        libubus.so.20251202       · libuci.so.20250120
lib  → SDK toolchain-*/lib       软链：真 libc.so / crt1.o / ld-musl-aarch64.so.1
include → SDK toolchain-*/include 软链
```

`lib` / `include` / `lib64` 用软链而非复制：真实 `libc.a` 有 11 MB，复制既占磁盘又容易与 SDK 走样；软链让 sysroot 始终等于"SDK 的 libc + 我们自己编的四个库"。`ln -sfn` 里的 `-n` 是必须的——`$SYSROOT/lib` 若已是软链，`-n` 让它替换**软链本身**而不是写进目标目录。

## 5. musl 一致性：ABI 兼容的真正保障

实测（2026-09-26）**两边同为 1.2.5**：

```bash
SDK=$HOME/openwrt-sdks/immortalwrt-sdk-25.12.2-mediatek-filogic_gcc-14.3.0_musl.Linux-x86_64
TC="$(find "$SDK/staging_dir" -maxdepth 1 -type d -name 'toolchain-aarch64_cortex-a53_*' | head -1)"
strings -a "$TC/lib/libc.so" | grep -oE '^1\.[0-9]+\.[0-9]+$' | head -1     # SDK 侧 → 1.2.5
grep -oE '"[0-9]+\.[0-9]+\.[0-9]+"' \
  /opt/homebrew/Cellar/zig/*/lib/zig/libc/musl/src/internal/version.h | tr -d '"' | head -1  # zig 侧 → 1.2.5
```

**别被目录结构骗了**：`zig cc` 编 musl 目标时**不会**用 sysroot 里的 `libc.so`，它固定取自己缓存的那份和 `crt1.o`（`zig cc -###` 可验证）；sysroot 里那份只被 `-L` 找到但不被选中。所以"挂了 libc 软链"的价值在头文件与统一搜索根，真正的 ABI 风险是**版本是否同源**——不一致时链接可能引到设备 libc 里没有的符号，运行时才炸。`setup.sh` 会核对并在不一致时打印警告，构建期就拦住。

设备最终跑的是它自己的 `libc.so`（`NEEDED` 只记 SONAME），因此这条核对是必须的、不是可选的。

## 6. 环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `OPENWRT_SYSROOT` | `$HOME/openwrt-sdks/sysroot-$ARCH` | sysroot 位置，`build.sh --target` 也读它 |
| `OPENWRT_SRC` | `$HOME/openwrt-sdks/src` | 四个库的源码检出目录 |
| `OPENWRT_LIB_BUILD` | `$HOME/openwrt-sdks/build-libs` | 库的构建目录（含包装器与 cmake 工具链文件） |
| `SDK` | 自动探测 `$HOME/openwrt-sdks/immortalwrt-sdk-*` | 用于挂载 libc 软链 |
| `ARCH` | `aarch64_cortex-a53` | 影响 sysroot 路径名与 ABI 值 |
| `ZIG` / `CMAKE` / `READELF` | `/opt/homebrew/bin/{zig,cmake}`、`/opt/homebrew/opt/llvm/bin/llvm-readelf` | 工具路径覆盖 |

## 7. 常见失败与处置

| 现象 | 原因 | 处置 |
|---|---|---|
| `build.sh --target` 报找不到 `libuci.so` | 还没建 sysroot | 先跑 `./toolchain/setup.sh` |
| cmake 构建共享库时段错误（退出码 139） | `CMAKE_LINK_DEPENDS_USE_LINKER` 没关 | 检查 `setup.sh` 的 `build_lib` 是否传了 `=OFF` |
| json-c 头文件来自 Homebrew、链接报 Mach-O/架构错 | pkg-config 没隔离 | 确认 `PKG_CONFIG_LIBDIR` + `PKG_CONFIG_SYSROOT_DIR`，且 `PKG_CONFIG_PATH` 为空 |
| 设备上运行报找不到 `libXXX.so.<数字>` | `ABIVERSION` 与设备上的库不一致 | 按设备 `apk info` 的包版本号核对 `PKG_ABI_VERSION` |
| `setup.sh` 打印 musl 版本不一致警告 | zig 自带 musl ≠ SDK 的 musl | 换与 SDK 同版本的 zig，或改用 SDK 自带 gcc 链接 |
| 改 `setup.sh` 后报 `unbound variable`（`local` 那几行） | macOS 自带 bash 3.2 会把一条 `local` 里所有右值先算完再赋值 | 每个变量单独一条 `local`（脚本里已注明） |

## 8. 下一步

环境就绪后看 [`build-and-run.md`](build-and-run.md)：两段式链接的细节、`build.sh` 用法、产物核验与本地验收清单。