#!/usr/bin/env bash
# spike 01：运行验证
#
# 验收标准（全部满足才算 spike 1 通过）：
#   [1] 二进制是 aarch64 ELF
#   [2] 动态依赖指向 OpenWrt 的 musl 加载器 /lib/ld-musl-aarch64.so.1
#   [3] 运行时能找到 libuci / libubus（NEEDED 里有 libuci.so.1 / libubus.so.1）
#   [4] 打印出 network.lan.proto 的真实取值（证明 libuci 可用）
#   [5] 打印出 network.interface 的 id 并 invoke dump 成功（证明 libubus 可用）
#   [6] RSS < 2MB（下一步用 /proc/self/status 或 ps 观察）

set -euo pipefail
cd "$(dirname "$0")"

BIN="${1:-}"
if [[ -z "$BIN" ]]; then
  # 真机模式产物是 build/spike01，本地模式产物是 build/spike01-aarch64
  for cand in build/spike01 build/spike01-aarch64; do
    if [[ -f "$cand" ]]; then BIN="$cand"; break; fi
  done
fi
if [[ -z "$BIN" || ! -f "$BIN" ]]; then
  echo "找不到二进制，先跑 ./build.sh 或 ./build.sh --local" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 1. 静态检查
# ---------------------------------------------------------------------------
echo "== 静态检查 =="
file "$BIN"

if command -v readelf >/dev/null 2>&1; then
  INTERP="$(readelf -l "$BIN" 2>/dev/null | grep -oE '/lib/ld-musl[^]]*' | head -1 || true)"
  echo "解释器: ${INTERP:-（静态链接，无解释器）}"
  echo "NEEDED:"
  readelf -d "$BIN" 2>/dev/null | grep -E 'NEEDED' || echo "  （无，静态链接）"
else
  echo "本机没有 readelf（macOS 常见），跳过动态依赖检查"
fi

# ---------------------------------------------------------------------------
# 2. 运行
# ---------------------------------------------------------------------------
echo
echo "== 运行 =="

if [[ "$(uname -s)" == "Linux" && "$(uname -m)" == "aarch64" ]]; then
  echo "本机就是 aarch64 Linux，直接运行"
  exec "$BIN"
fi

if command -v qemu-aarch64 >/dev/null 2>&1; then
  echo "用 qemu-aarch64 运行"
  if [[ -n "${ROOTFS:-}" ]]; then
    echo "sysroot: $ROOTFS"
    exec qemu-aarch64 -L "$ROOTFS" "$BIN"
  fi
  exec qemu-aarch64 "$BIN"
fi

cat <<'EOF'
本机无法直接运行 aarch64 二进制（没有 qemu-aarch64）。三种可选方式：

  1) 真机——最可信，也是最终验收标准：
       scp <bin> root@<router>:/tmp/
       ssh root@<router> /tmp/spike01

  2) 装 qemu 用户态模拟：
       brew install qemu
       ROOTFS=<OpenWrt arm64 rootfs 或 SDK staging_dir> ./run.sh <bin>
     （注意：qemu 用户态需要一套 arm64 的 libuci/libubus，SDK 的 staging_dir 可以当 sysroot）

  3) OpenWrt arm64 镜像 + qemu-system-aarch64 起完整系统再 scp 进去。
EOF
