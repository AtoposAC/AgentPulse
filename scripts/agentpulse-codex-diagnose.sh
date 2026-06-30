#!/bin/zsh
set -euo pipefail
SWIFTPM_HOME="$PWD/.swiftpm-home" \
CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache" \
swift run --disable-sandbox agentpulse-cli diagnose-codex
