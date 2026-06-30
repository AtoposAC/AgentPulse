#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
SWIFTPM_HOME="$PWD/.swiftpm-home" \
CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache" \
swift build --disable-sandbox -c release
