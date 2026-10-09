# molly —— 用 Go 复刻的 ImmortalWrt LuCI 服务端替换层（uhttpd + rpcd + ucode dispatcher）。
#
# 交叉编译目标是设备那一侧：**linux/arm64（v8a）+ musl**，用 zig cc 当 C 编译器。
# 库（libubus / libuci / libubox / libblobmsg_json）的名字写在 internal/cbind 的
# `#cgo linux LDFLAGS` 里，sysroot 只在源码之外给（cgo 会把 #cgo 里的 flag 判成
# invalid flag，见 internal/cbind/cbind.go 的注释），所以这个文件只负责指路：
# 编译器、GOOS/GOARCH/GOARM、sysroot。
#
# 常用：
#   make            原生构建（本机自测/快速迭代）
#   make target     交叉编译设备产物 build/molly-arm64
#   make deploy     交叉编译并部署到设备（默认 192.168.1.1:/usr/sbin/molly）
#   make test       go test ./...
#   make smoke      起本机实例跑 tests/smoke.sh（300+ 条 HTTP 层断言）
#   make lint       gofmt 检查 + go vet（CI 用的那步）
#   make device-simple 真机验收简洁版 /lite（黑盒，需 MOLLY_DEVICE_PASS=xxx）
#   make device-luci    真机验收专家版（对照基准，需 MOLLY_DEVICE_PASS=xxx）
#   make help       列出所有目标
#
# 交叉编译需要 zig 与 ImmortalWrt 的 aarch64 sysroot，两者都能用变量覆盖：
#   make target SYSROOT=/path/to/sysroot-aarch64_cortex-a53 ZIG=/opt/zig/zig

MODULE := github.com/azhai/molly
CMD    := *.go
BIN    := build

HOST_BIN   := $(BIN)/molly-host
TARGET_BIN := $(BIN)/molly-arm64

# ---- 交叉编译配置（设备：ImmortalWrt 25.12.2 / aarch64_cortex-a53 / musl）----
GOOS_TARGET   ?= linux
GOARCH_TARGET ?= arm64
# v8a 就是 ARMv8-A。GOARM=8 只是把目标架构写明在命令行里；真正决定代码生成与 ABI 的
# 是 zig 的 -target aarch64-linux-musl（走 cgo 时 Go 侧的 GOARM 不参与）。
GOARM_TARGET  ?= 8
ZIG           ?= zig
# 注意目录名是 aarch64（工具链的命名），不是 arm64。
SYSROOT       ?= $(HOME)/openwrt-sdks/sysroot-aarch64_cortex-a53

CGO_CFLAGS  ?= --sysroot=$(SYSROOT) -I$(SYSROOT)/usr/include
CGO_LDFLAGS ?= --sysroot=$(SYSROOT)

TARGET_CC := $(ZIG) cc -target aarch64-linux-musl
GO_ENV    := CGO_ENABLED=1 GOOS=$(GOOS_TARGET) GOARCH=$(GOARCH_TARGET) GOARM=$(GOARM_TARGET) \
             CC="$(TARGET_CC)" CGO_CFLAGS="$(CGO_CFLAGS)" CGO_LDFLAGS="$(CGO_LDFLAGS)"

# 额外的链接参数。`make target LDFLAGS='-s -w'` 能把产物缩小四成左右（去掉符号表与调试信息）。
LDFLAGS ?=

# ---- 设备部署（make deploy 用）----
HOST ?= 192.168.1.1
DEST ?= /usr/sbin/molly
# 需要免密或已配好密钥；用 sshpass 时覆盖即可，例如
#   make deploy SSH="sshpass -p '***' ssh -o StrictHostKeyChecking=no root@192.168.1.1"
SSH ?= ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@$(HOST)

.DEFAULT_GOAL := all

.PHONY: all build target target-embed test smoke device-luci device-simple fmt fmt-check vet lint deploy clean help check-toolchain

all: clean build target

## 原生构建（当前平台，给本机自测用）
build:
	@mkdir -p $(BIN)
	go build -ldflags '$(LDFLAGS)' -o $(HOST_BIN) $(CMD)
	@echo "→ $(HOST_BIN)"

## 交叉编译设备产物：linux/arm64(v8a) + musl
target: check-toolchain
	@mkdir -p $(BIN)
	$(GO_ENV) go build -ldflags '$(LDFLAGS)' -o $(TARGET_BIN) $(CMD)
	@echo "→ $(TARGET_BIN)  [$(GOOS_TARGET)/$(GOARCH_TARGET) v$(GOARM_TARGET)a · musl · $(SYSROOT)]"

## 同 target，但把设备的前端资源也编进二进制（「只丢一个二进制上设备」也能跑）
## 前置：./tools/embed-assets.sh <host> 从设备抄一份 webassets/luci-static
target-embed: check-toolchain
	@test -d webassets/luci-static || { \
	  echo "webassets/luci-static 不存在。先跑：./tools/embed-assets.sh <host>"; exit 1; }
	@mkdir -p $(BIN)
	$(GO_ENV) go build -tags embed_assets -ldflags '$(LDFLAGS)' -o $(TARGET_BIN)-embed $(CMD)
	@echo "→ $(TARGET_BIN)-embed"

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

## 单元测试（纯 Go，darwin 上跑假数据）
test:
	go test -count=1 ./...

## 集成验收：起 7 个本机实例跑 HTTP 层断言
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

fmt:
	gofmt -l -w .

## 只检查不改（CI 用）
fmt-check:
	@out=$$(gofmt -l .); if [ -n "$$out" ]; then echo "以下文件未格式化："; echo "$$out"; exit 1; fi

vet:
	go vet ./...

lint: fmt-check vet

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

clean:
	rm -rf $(BIN)

help:
	@grep -E '^## ' $(MAKEFILE_LIST) | sed 's/^## /  /'
	@echo
	@echo "  常用变量：SYSROOT=$(SYSROOT)"
	@echo "            ZIG=$(ZIG)  LDFLAGS='$(LDFLAGS)'  HOST=$(HOST)  DEST=$(DEST)"
