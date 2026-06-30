#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
echo "AgentPulse doctor"
echo "Workspace: $PWD"
echo
echo "Swift:"
swift --version | head -1
echo
echo "Build:"
SWIFTPM_HOME="$PWD/.swiftpm-home" \
CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache" \
swift build --disable-sandbox >/dev/null
echo "OK"
echo
echo "Codex events:"
.build/debug/agentpulse-cli diagnose-codex
echo
echo "State:"
.build/debug/agentpulse-cli status
