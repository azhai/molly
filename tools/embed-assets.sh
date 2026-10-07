#!/usr/bin/env bash
# 把设备上的 /www/luci-static 抄进 molly/internal/webassets/，供
# `go build -tags embed_assets` 把前端资源编进二进制。
#
#   ./tools/embed-assets.sh root@192.168.1.1
#   ./tools/embed-assets.sh root@192.168.1.1 /www-molly/luci-static    # 指定源目录
#
# 抄出来的目录**已 gitignore**（体积 + 版本漂移都不该进仓库）。资源是「编译时快照」：
# 设备升级 LuCI 后它会漂移，所以运行时只作**兜底**（docroot 里有的优先）。
set -euo pipefail

HOST="${1:?用法：./tools/embed-assets.sh root@<host> [远端目录，默认 /www/luci-static]}"
SRC="${2:-/www/luci-static}"
DEST="$(cd "$(dirname "$0")/.." && pwd)/webassets/luci-static"

echo "从 $HOST:$SRC 抄到 $DEST"
rm -rf "$DEST"
mkdir -p "$DEST"
# 走 ssh + tar 管道：OpenWrt 的 dropbear scp 不支持 `scp -r <host>:<dir>/.` 这种形式
# （实测报 `unexpected filename: .`），而 busybox tar 两种方向都稳。
#
# **-h 必加**：设备上 /www/luci-static/{bootstrap-light,bootstrap-dark} 是指向主题目录的
# **符号链接**，而 `go:embed` **不跟随符号链接**（只当普通文件处理，内容不进二进制）——
# 不加 -h 就会出现「resources/luci.js 能取到、主题的 cascade.css 404」这种半残状态。
ssh "$HOST" "tar -C '$SRC' -chf - ." | tar -C "$DEST" -xf -

n="$(find "$DEST" -type f | wc -l | tr -d ' ')"
sz="$(du -sh "$DEST" | cut -f1)"
links="$(find "$DEST" -type l | wc -l | tr -d ' ')"
echo "已抄入 $n 个文件，$sz"
if [ "$links" != "0" ]; then
  echo "**警告：抄进来的资源里还有 $links 个符号链接——go:embed 会跳过它们，主题/资源会缺**" >&2
  find "$DEST" -type l >&2
  exit 1
fi
echo
echo "编译（把 <SYSROOT> 换成你的 sysroot）："
echo "  cd molly && CGO_ENABLED=1 GOOS=linux GOARCH=arm64 CC=\"zig cc -target aarch64-linux-musl\" \\"
echo "    CGO_CFLAGS=\"--sysroot=<SYSROOT> -I<SYSROOT>/usr/include\" CGO_LDFLAGS=\"--sysroot=<SYSROOT>\" \\"
echo "    go build -tags embed_assets -o build/molly-arm64-embed ./cmd/molly"
