#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
SWIFTPM_HOME="$PWD/.swiftpm-home" \
CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache" \
swift build --disable-sandbox >/dev/null
if .build/debug/agentpulse-cli set codex working "正在运行演示任务"; then
  echo "已写入 Codex 演示状态。等待 App 下一次刷新，或在主界面点刷新。"
else
  echo "写入失败：请确认当前终端有权限访问 ~/Library/Application Support/AgentPulse。"
  exit 1
fi
