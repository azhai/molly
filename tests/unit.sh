#!/usr/bin/env bash
# 单元测试（测试金字塔的底层）：odin test 跑纯函数包。
#   集成 / 接口层见 tests/http_smoke.sh（真起 server、真 curl）。
# 用法：./tests/unit.sh
#
# 为什么按包跑：molly 的分层是「handlers → luci/http → backend」，每层的纯函数
# 都在自己的包里，按包跑能直接看出哪一层坏了。
set -uo pipefail
cd "$(dirname "$0")/.."

PKGS=(
  src/http     # normalize_path / content_type_for
  src/luci     # apply_spec / check_depends / resolve / first_child / effective_action
  src/backend  # ubus_error_message + uci 契约（darwin 假配置）
  src/handlers # CGI 桥接的环境构造与响应解析
)

PASS=0
FAIL=0

for pkg in "${PKGS[@]}"; do
  out=$(odin test "$pkg" -collection:molly=src 2>&1)
  code=$?
  summary=$(printf '%s\n' "$out" | grep -o 'Finished [0-9]* tests.*' | tail -1)
  if [[ $code -eq 0 ]]; then
    PASS=$((PASS + 1))
    printf '  ok   %-12s %s\n' "$pkg" "${summary:-通过}"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL %-12s %s\n' "$pkg" "${summary:-见下方输出}"
    printf '%s\n' "$out" | grep -E 'FAIL|Error:|runtime assertion|Signal|leak' | head -10 | sed 's/^/       /'
  fi
done

echo
echo "通过 ${PASS}，失败 ${FAIL}（包数）"
[[ "$FAIL" -eq 0 ]]
