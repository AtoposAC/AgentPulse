import Foundation

public enum HookManager {
    private static let marker = "AgentPulse Claude Hook"

    public struct ClaudeHookStatus: Sendable {
        public var settingsExists: Bool
        public var settingsReadable: Bool
        public var hookInstalled: Bool
        public var hookScriptExists: Bool
        public var hookScriptExecutable: Bool
        public var logExists: Bool
        public var logWritable: Bool
        public var latestEventLine: String?
        public var latestEventAt: Date?
    }

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
        return text.contains(marker) && FileManager.default.isExecutableFile(atPath: hookScriptURL.path)
    }

    public static func diagnoseClaudeHook() -> ClaudeHookStatus {
        let fileManager = FileManager.default
        let settingsExists = fileManager.fileExists(atPath: claudeSettingsURL.path)
        let settingsReadable = fileManager.isReadableFile(atPath: claudeSettingsURL.path)
        let hookScriptExists = fileManager.fileExists(atPath: hookScriptURL.path)
        let hookScriptExecutable = fileManager.isExecutableFile(atPath: hookScriptURL.path)
        let logExists = fileManager.fileExists(atPath: claudeHookLogURL.path)
        let logWritable = fileManager.isWritableFile(atPath: claudeHookLogURL.path)
            || fileManager.isWritableFile(atPath: claudeHookLogURL.deletingLastPathComponent().path)
        let latestLine = latestNonEmptyLine(in: claudeHookLogURL)
        return ClaudeHookStatus(
            settingsExists: settingsExists,
            settingsReadable: settingsReadable,
            hookInstalled: isClaudeHookInstalled(),
            hookScriptExists: hookScriptExists,
            hookScriptExecutable: hookScriptExecutable,
            logExists: logExists,
            logWritable: logWritable,
            latestEventLine: latestLine,
            latestEventAt: latestLine.flatMap { ClaudeHookEventParser.parse($0)?.date }
        )
    }

    public static func writeTestClaudeHookEvent() throws {
        try FileManager.default.createDirectory(at: claudeHookLogURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let event: [String: Any] = [
            "hook_event_name": "UserPromptSubmit",
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "source": "AgentPulse Test Event"
        ]
        let data = try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])
        guard let line = String(data: data, encoding: .utf8) else { return }
        if !FileManager.default.fileExists(atPath: claudeHookLogURL.path) {
            FileManager.default.createFile(atPath: claudeHookLogURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: claudeHookLogURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line + "\n").utf8))
        try handle.close()
    }

    public static func recentClaudeHookEvents(limit: Int = 5) -> [ClaudeHookEvent] {
        guard limit > 0,
              let text = try? String(contentsOf: claudeHookLogURL, encoding: .utf8) else {
            return []
        }
        return text.split(separator: "\n", omittingEmptySubsequences: true)
            .reversed()
            .lazy
            .compactMap { ClaudeHookEventParser.parse(String($0)) }
            .prefix(limit)
            .map { $0 }
    }

    public static func installClaudeHook() throws {
        try FileManager.default.createDirectory(at: hookScriptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: claudeHookLogURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let script = """
        #!/bin/zsh
        # \(marker)
        mkdir -p "$HOME/Library/Application Support/AgentPulse/logs"
        payload="$(cat)"
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

        let command = shellQuoted(hookScriptURL.path)
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

    private static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func latestNonEmptyLine(in url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return text.split(separator: "\n", omittingEmptySubsequences: true).last.map(String.init)
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
