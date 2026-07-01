#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
SWIFTPM_HOME="$PWD/.swiftpm-home" \
CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache" \
swift build --disable-sandbox >/dev/null
echo "AgentPulse 已移除手动写入演示状态。"
echo
echo "当前本地诊断："
.build/debug/agentpulse-cli status
echo
echo "如需查看 Codex 用量演示，请运行："
echo "  .build/debug/agentpulse-cli scan-usage"
