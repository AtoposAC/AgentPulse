# AgentPulse

A native macOS menu bar app for monitoring Codex usage, quota and agent activity.

## Features

- Codex local session monitoring from `~/.codex/sessions`
- Codex token, cost, quota, model and tool usage views
- Agent Journal with recent Codex work segments
- Claude Code Hook status monitoring
- Native macOS menu bar and floating capsule
- Light and dark mode

## Install

Download `AgentPulse.dmg` from GitHub Releases.

## Build

```bash
swift build -c release --disable-sandbox
```

## Package

```bash
./script/package-app.sh
```

## Privacy

Codex usage data comes from local Codex session files.
Claude status data comes from an optional Claude Code Hook that writes to AgentPulse's local Application Support directory.
AgentPulse does not upload data to third-party servers.

## Roadmap

### v1.0.2

- Usage Center clarity improvements
- Agent Journal work segments and 7-day history
- GitHub Release update check
- Claude status monitoring via Claude Code Hooks

### v1.0.3

- Claude Hook compatibility hardening
- Diagnostics cleanup
- Journal export
- Sparkle auto update after Developer ID signing
