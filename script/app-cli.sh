#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")/.."

CLI="$PWD/dist/AgentPulse.app/Contents/Resources/agentpulse-cli"

if [[ ! -x "$CLI" ]]; then
  echo "AgentPulse app CLI not found. Run ./script/package-app.sh first." >&2
  exit 1
fi

exec "$CLI" "$@"
