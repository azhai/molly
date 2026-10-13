# molly —— 用 Odin 复刻的 ImmortalWrt LuCI 服务端替换层（uhttpd + rpcd + ucode dispatcher）。
#
# 交叉编译目标是设备那一侧：linux/arm64（v8a）+ musl，**两段式**——Odin 不能交叉链接
# linux/arm64（-linker 不吃 SDK 的 gcc，只产 .o），故由 zig cc 收尾链接 sysroot 里的
# libubus / libuci / libubox / libblobmsg_json。完整构建配方在 build.sh，本文件只负责指路：
# 编译器、sysroot、以及各验收目标的入口。
#
# 常用：
#   make            原生构建（本机自测二进制）+ 交叉产物（设备二进制）
#   make target     交叉编译设备产物 build/molly-arm64
#   make deploy     交叉编译并部署到设备（默认 192.168.1.1:/usr/sbin/molly）
#   make test       odin test 各包单测（host 跑，假数据后端）
#   make smoke      起本机实例跑 tests/smoke.sh（300+ 条 HTTP 层断言）
#   make fmt        odin fmt src
#   make device-simple     真机验收简洁版 /lite（黑盒，需 MOLLY_DEVICE_PASS=xxx）
#   make device-luci       真机验收专家版（对照基准，需 MOLLY_DEVICE_PASS=xxx）
#   make help       列出所有目标
#
# 交叉编译需要 zig 与 ImmortalWrt 的 aarch64 sysroot，两者都能用变量覆盖：
#   make target SYSROOT=/path/to/sysroot-aarch64_cortex-a53 ZIG=/opt/zig/zig

BIN        := build
HOST_BIN   := $(BIN)/molly-host
TARGET_BIN := $(BIN)/molly-arm64

# ---- 交叉编译配置（设备：ImmortalWrt / aarch64_cortex-a53 / musl）----
# 注意目录名是 aarch64（工具链的命名），不是 arm64。真正的指令基线/tune 由 build.sh 里
# zig 的 -target/-mcpu 决定（cortex-a53 无 LSE，用基础 aarch64）。
ZIG     ?= zig
SYSROOT ?= $(HOME)/openwrt-sdks/sysroot-aarch64_cortex-a53

# ---- Odin 单测覆盖的包（含 *_test.odin 的包；src/main.odin 是可执行入口不参与）----
TEST_PKGS := src/http src/backend src/handlers src/luci src/assets

# ---- 设备部署（make deploy 用）----
HOST ?= 192.168.1.1
DEST ?= /usr/sbin/molly
# molly 的 procd 启动脚本（含依赖前置）；make install-init 装到设备 /etc/init.d/molly。
INIT ?= tools/molly.init
# 需要免密或已配好密钥；用 sshpass 时覆盖即可，例如
#   make deploy SSH="sshpass -p '***' ssh -o StrictHostKeyChecking=no root@192.168.1.1"
SSH ?= ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@$(HOST)

.DEFAULT_GOAL := all

.PHONY: all build target test smoke fmt deploy install-init clean help check-toolchain device-luci device-simple

all: clean build target

## 原生构建（当前平台，给本机自测/冒烟用）：build.sh --host → $(HOST_BIN)
build:
	@mkdir -p $(BIN)
	./build.sh --host

## 交叉编译设备产物：linux/arm64(v8a) + musl，两段式（odin .o + zig cc 链 shim/ubus/uci）→ $(TARGET_BIN)
target: check-toolchain
	./build.sh --target

## 交叉编译前置检查：zig（当 C 编译器）与 sysroot 里的头文件/库
check-toolchain:
	@command -v $(ZIG) >/dev/null 2>&1 || { \
	  echo "找不到 $(ZIG)：交叉编译要用它当 C 编译器（覆盖：make target ZIG=/path/to/zig）"; exit 1; }
	@test -d "$(SYSROOT)/usr/include" || { \
	  echo "找不到 sysroot：$(SYSROOT)"; \
	  echo "  要指向 ImmortalWrt 的 aarch64 sysroot（含 libubus/libuci/libubox 的头文件与库）"; \
	  exit 1; }
	@test -f "$(SYSROOT)/usr/lib/libubus.so" || \
	  echo "  注意：$(SYSROOT)/usr/lib 下没有 libubus.so，链接可能过不去"

## 单元测试（Odin，各包在 host 上跑假数据后端）
test:
	@for p in $(TEST_PKGS); do \
	  echo "==> odin test $$p"; \
	  odin test $$p -collection:molly=src -define:ODIN_TEST_THREADS=1 || exit 1; \
	done

## 集成验收：起本机实例跑 HTTP 层断言
smoke:
	./tests/smoke.sh

## 真机验收（黑盒，只走 HTTP）：简洁版 /lite。需活设备与 root 密码；不做破坏性写操作。
device-simple:
	@: "${MOLLY_DEVICE_PASS:?先 export MOLLY_DEVICE_PASS=<root 密码>，例：make device-simple MOLLY_DEVICE_PASS=xxx}"
	MOLLY_DEVICE_PASS='$(MOLLY_DEVICE_PASS)' ./tests/device_simple.sh $(if $(BASE),$(BASE),http://$(HOST):8080)

## 真机验收（对照基准）：专家版前缀交设备 ucode 渲染那一路（T1 桥接形态）。
device-luci:
	@: "${MOLLY_DEVICE_PASS:?先 export MOLLY_DEVICE_PASS=<root 密码>，例：make device-luci MOLLY_DEVICE_PASS=xxx}"
	MOLLY_DEVICE_PASS='$(MOLLY_DEVICE_PASS)' MOLLY_LUCI_PREFIX=$${MOLLY_LUCI_PREFIX:-/admin} MOLLY_LUCI_SUB=$${MOLLY_LUCI_SUB-} \
	  ./tests/device_luci.sh $(if $(BASE),$(BASE),http://$(HOST):8080)

## 格式化（Odin）
fmt:
	odin fmt src

## 部署到设备：先停服务再覆盖（直接覆盖会 Text file busy），最后拉起来并回状态
deploy: target
	@echo "==> 停服务并清掉可能占着端口的残留实例"
	$(SSH) '/etc/init.d/molly stop >/dev/null 2>&1; sleep 2; \
	  for p in /proc/[0-9]*/exe; do pid=$$(echo $$p | cut -d/ -f3); \
	    case "$$(readlink $$p 2>/dev/null)" in *molly*) kill -9 $$pid 2>/dev/null;; esac; \
	  done; sleep 1; netstat -tlnp 2>/dev/null | grep ":8080" || echo "    8080 已释放"'
	@echo "==> 覆盖二进制（$(TARGET_BIN) → $(DEST)）"
	@cat $(TARGET_BIN) | $(SSH) 'cat > $(DEST) && chmod +x $(DEST) && ls -l $(DEST)'
	@echo "==> 启动"
	$(SSH) '/etc/init.d/molly start; sleep 4; /etc/init.d/molly status'

## 安装/更新设备的 molly 启动脚本（tools/molly.init → /etc/init.d/molly，含依赖前置）并 enable
install-init:
	@echo "==> 安装启动脚本 $(INIT) → /etc/init.d/molly"
	@cat $(INIT) | $(SSH) 'cat > /etc/init.d/molly && chmod +x /etc/init.d/molly && /etc/init.d/molly enable && /etc/init.d/molly status'

clean:
	rm -rf $(BIN)

help:
	@grep -E '^## ' $(MAKEFILE_LIST) | sed 's/^## /  /'
	@echo
	@echo "  常用变量：SYSROOT=$(SYSROOT)"
	@echo "            ZIG=$(ZIG)  HOST=$(HOST)  DEST=$(DEST)"
