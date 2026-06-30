import Foundation

public enum HookManager {
    private static let marker = "AgentPulse Claude Hook"

    public static var claudeSettingsURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/settings.json")
    }

    public static var hookScriptURL: URL {
        AppStoragePaths().root.appendingPathComponent("agentpulse-claude-hook.sh")
    }

    public static var claudeHookLogURL: URL {
        AppStoragePaths().logs.appendingPathComponent("claude-hook.jsonl")
    }

    public static func isClaudeHookInstalled() -> Bool {
        guard let text = try? String(contentsOf: claudeSettingsURL, encoding: .utf8) else { return false }
        return text.contains(marker)
    }

    public static func installClaudeHook() throws {
        try FileManager.default.createDirectory(at: hookScriptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let script = """
        #!/bin/zsh
        # \(marker)
        mkdir -p "$HOME/Library/Application Support/AgentPulse/logs"
        payload="$(cat)"
        timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
        bytes="$(printf "%s" "$payload" | wc -c | tr -d ' ')"
        {
          printf "===== HOOK TRIGGERED =====\\n"
          printf "%s\\n" "$timestamp"
          printf "bytes: %s\\n\\n" "$bytes"
          printf "payload:\\n"
          printf "%s\\n\\n" "$payload"
        } >> "$HOME/Library/Application Support/AgentPulse/logs/claude-hook-debug.log"
        printf "%s\\n" "$payload" >> "$HOME/Library/Application Support/AgentPulse/logs/claude-hook.jsonl"
        exit 0
        """
        try script.write(to: hookScriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookScriptURL.path)

        let settingsURL = claudeSettingsURL
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: settingsURL.path) {
            let backup = settingsURL.deletingLastPathComponent()
                .appendingPathComponent("settings.json.bak-\(Int(Date().timeIntervalSince1970))")
            try FileManager.default.copyItem(at: settingsURL, to: backup)
        }

        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = existing
        }

        let command = "\(hookScriptURL.path)"
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        let events: [(name: String, matcher: String?)] = [
            ("UserPromptSubmit", nil),
            ("PreToolUse", "*"),
            ("PostToolUse", "*"),
            ("Notification", "*"),
            ("Stop", nil)
        ]
        for event in events {
            var entries = hooks[event.name] as? [[String: Any]] ?? []
            entries = entries.removingAgentPulseHook(marker: marker)
            entries.append(Self.hookGroup(command: command, matcher: event.matcher))
            hooks[event.name] = entries
        }
        root["hooks"] = hooks
        root["_agentpulse"] = marker

        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: settingsURL, options: [.atomic])
        if let snippet = Self.settingsSnippet(events: events.map(\.name), hooks: hooks) {
            print(snippet)
        }
    }

    private static func hookGroup(command: String, matcher: String?) -> [String: Any] {
        var group: [String: Any] = [
            "hooks": [
                [
                    "type": "command",
                    "command": command
                ]
            ]
        ]
        if let matcher {
            group["matcher"] = matcher
        }
        return group
    }

    private static func settingsSnippet(events: [String], hooks: [String: Any]) -> String? {
        var snippet: [String: Any] = ["_agentpulse": marker]
        var hookSnippet: [String: Any] = [:]
        for event in events {
            if let entries = hooks[event] {
                hookSnippet[event] = entries
            }
        }
        snippet["hooks"] = hookSnippet
        guard let data = try? JSONSerialization.data(withJSONObject: snippet, options: [.prettyPrinted, .sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    public static func uninstallClaudeHook() throws {
        let settingsURL = claudeSettingsURL
        guard let data = try? Data(contentsOf: settingsURL),
              var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var hooks = root["hooks"] as? [String: Any] else { return }

        for key in Array(hooks.keys) {
            guard var entries = hooks[key] as? [[String: Any]] else { continue }
            entries = entries.removingAgentPulseHook(marker: marker)
            hooks[key] = entries
        }
        root["hooks"] = hooks
        root.removeValue(forKey: "_agentpulse")
        let output = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try output.write(to: settingsURL, options: [.atomic])
    }
}

private extension Array where Element == [String: Any] {
    func removingAgentPulseHook(marker: String) -> [[String: Any]] {
        compactMap { entry in
            let command = entry["command"] as? String ?? ""
            let description = entry["description"] as? String ?? ""
            if command.contains("agentpulse-claude-hook.sh") || description.contains(marker) {
                return nil
            }

            guard var nested = entry["hooks"] as? [[String: Any]] else {
                return entry
            }
            nested.removeAll { hook in
                let command = hook["command"] as? String ?? ""
                let description = hook["description"] as? String ?? ""
                return command.contains("agentpulse-claude-hook.sh") || description.contains(marker)
            }
            if nested.isEmpty {
                return nil
            }
            var copy = entry
            copy["hooks"] = nested
            return copy
        }
    }
}
