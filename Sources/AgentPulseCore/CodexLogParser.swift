import Foundation

public struct CodexParseResult: Sendable {
    public var signal: AgentSignal
    public var usage: UsageSnapshot
    public var toolStats: ToolStats
    public var eventMessage: String
    public var lastMeaningfulEventAt: Date?

    public init(signal: AgentSignal, usage: UsageSnapshot, toolStats: ToolStats, eventMessage: String, lastMeaningfulEventAt: Date? = nil) {
        self.signal = signal
        self.usage = usage
        self.toolStats = toolStats
        self.eventMessage = eventMessage
        self.lastMeaningfulEventAt = lastMeaningfulEventAt
    }
}

public enum CodexLogParser {
    public static func parseRecentLines(_ lines: [String]) -> CodexParseResult {
        var signal: AgentSignal = .idle
        var tokens = 0
        var cost = Decimal(0)
        var toolStats = ToolStats()
        var message = "Agent 空闲"
        var lastMeaningfulEventAt: Date?

        for line in lines {
            guard
                let data = line.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let payload = object["payload"] as? [String: Any]
            else { continue }

            let payloadType = (payload["type"] as? String ?? "").lowercased()
            let name = toolName(in: payload).lowercased()
            let eventDate = dateValue(object["timestamp"])
            let searchable = searchableText(payload: payload, name: name)

            if isPermissionRequest(payloadType: payloadType, searchable: searchable) {
                signal = .attention
                message = "等待授权"
                lastMeaningfulEventAt = eventDate ?? lastMeaningfulEventAt
            } else if isRateLimited(payloadType: payloadType, searchable: searchable) {
                signal = .attention
                message = "额度受限"
                lastMeaningfulEventAt = eventDate ?? lastMeaningfulEventAt
            } else if isFailureEvent(payloadType: payloadType, searchable: searchable) {
                signal = .attention
                message = "需要处理"
                lastMeaningfulEventAt = eventDate ?? lastMeaningfulEventAt
            } else if payloadType.contains("tool") || payloadType.contains("command") || payloadType.contains("function_call") || payloadType == "custom_tool_call" || payloadType == "patch_apply_end" || payloadType == "web_search_call" {
                signal = .working
                message = displayToolName(name)
                lastMeaningfulEventAt = eventDate ?? lastMeaningfulEventAt
            } else if payloadType.contains("reasoning") || payloadType.contains("user_message") || payloadType == "message" || payloadType == "agent_message" || payloadType == "task_started" {
                signal = .thinking
                message = "正在理解任务"
                lastMeaningfulEventAt = eventDate ?? lastMeaningfulEventAt
            } else if payloadType == "stop" || payloadType == "task_complete" || payloadType.contains("completed") || payloadType.contains("done") {
                signal = .done
                message = "任务完成"
                lastMeaningfulEventAt = eventDate ?? lastMeaningfulEventAt
            }

            if shouldCountTool(payloadType: payloadType, name: name) {
                if name.contains("write_stdin") {
                    toolStats.writeStdin += 1
                } else if name.contains("web") || name.contains("browser") {
                    toolStats.webRequests += 1
                } else if name.contains("search") || name.contains("grep") || name == "rg" || name.contains("ripgrep") {
                    toolStats.searchOperations += 1
                } else if name.contains("read") || name.contains("open") || name.contains("view") || name.contains("cat") {
                    toolStats.readOperations += 1
                } else if name.contains("exec") || name.contains("bash") || name.contains("shell") || name.contains("terminal") || name.contains("command") {
                    toolStats.terminalCommands += 1
                } else if name.contains("edit") || name.contains("write") || name.contains("patch") {
                    toolStats.fileChanges += 1
                } else if !name.isEmpty {
                    toolStats.other += 1
                }
            }

            if let usage = payload["usage"] as? [String: Any] {
                tokens += intValue(usage["input_tokens"])
                tokens += intValue(usage["output_tokens"])
                cost += decimalValue(usage["cost"])
            }
        }

        return CodexParseResult(
            signal: signal,
            usage: UsageSnapshot(
                todayCost: cost == 0 ? nil : cost,
                todayTokens: tokens == 0 ? nil : tokens,
                thirtyDayCost: cost == 0 ? nil : cost,
                thirtyDayTokens: tokens == 0 ? nil : tokens,
                quota5hRemainingPercent: nil,
                quotaWeekRemainingPercent: nil,
                dailyTokenUsage: tokens == 0 ? [] : [
                    UsageSnapshot.DailyTokenUsage(date: Self.todayKey(), tokens: tokens)
                ]
            ),
            toolStats: toolStats,
            eventMessage: message,
            lastMeaningfulEventAt: lastMeaningfulEventAt
        )
    }

    private static func todayKey() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    private static func toolName(in payload: [String: Any]) -> String {
        for key in ["name", "tool", "tool_name", "toolName", "function", "command"] {
            if let value = payload[key] as? String, !value.isEmpty {
                return value
            }
        }
        if let call = payload["call"] as? [String: Any] {
            return toolName(in: call)
        }
        if let item = payload["item"] as? [String: Any] {
            return toolName(in: item)
        }
        if let type = payload["type"] as? String,
           type.contains("patch") || type.contains("tool") || type.contains("function") {
            return type
        }
        return ""
    }

    private static func shouldCountTool(payloadType: String, name: String) -> Bool {
        if payloadType.contains("output") || payloadType.hasSuffix("_end") {
            return false
        }
        if payloadType.contains("function_call") || payloadType == "custom_tool_call" || payloadType == "web_search_call" {
            return true
        }
        return !name.isEmpty && (
            name.contains("exec")
            || name.contains("bash")
            || name.contains("shell")
            || name.contains("terminal")
            || name.contains("command")
            || name.contains("write_stdin")
            || name.contains("read")
            || name.contains("open")
            || name.contains("view")
            || name.contains("cat")
            || name.contains("edit")
            || name.contains("write")
            || name.contains("patch")
            || name.contains("search")
            || name.contains("grep")
            || name.contains("ripgrep")
            || name.contains("web")
            || name.contains("browser")
        )
    }

    private static func isPermissionRequest(payloadType: String, searchable: String) -> Bool {
        payloadType.contains("permission")
        || payloadType.contains("approval")
        || searchable.contains("requires approval")
        || searchable.contains("approval required")
        || searchable.contains("permission required")
        || searchable.contains("waiting for approval")
    }

    private static func isRateLimited(payloadType: String, searchable: String) -> Bool {
        payloadType.contains("rate_limit")
        || searchable.contains("rate_limit_reached")
        || searchable.contains("rate limit")
        || searchable.contains("quota exceeded")
    }

    private static func isFailureEvent(payloadType: String, searchable: String) -> Bool {
        payloadType.contains("error")
        || payloadType.contains("failure")
        || payloadType == "turn_aborted"
        || searchable.contains("command failed")
        || searchable.contains("tool failed")
        || searchable.contains("execution failed")
    }

    private static func searchableText(payload: [String: Any], name: String) -> String {
        [
            payload["type"] as? String,
            payload["message"] as? String,
            payload["error"] as? String,
            payload["status"] as? String,
            payload["subtype"] as? String,
            name
        ]
        .compactMap { $0 }
        .joined(separator: " ")
        .lowercased()
    }

    private static func displayToolName(_ name: String) -> String {
        if name.isEmpty { return "正在调用工具" }
        if name.contains("write_stdin") { return "正在写入终端输入" }
        if name.contains("exec") || name.contains("bash") || name.contains("shell") || name.contains("terminal") || name.contains("command") {
            return "正在执行终端命令"
        }
        if name.contains("apply_patch") || name.contains("patch") {
            return "正在修改文件"
        }
        if name.contains("edit") || name.contains("write") {
            return "正在写入文件"
        }
        if name.contains("web_search") || name.contains("search") {
            return "正在搜索"
        }
        return name
    }

    private static func intValue(_ value: Any?) -> Int {
        if let int = value as? Int { return int }
        if let double = value as? Double { return Int(double) }
        if let string = value as? String { return Int(string) ?? 0 }
        return 0
    }

    private static func decimalValue(_ value: Any?) -> Decimal {
        if let decimal = value as? Decimal { return decimal }
        if let double = value as? Double { return Decimal(double) }
        if let int = value as? Int { return Decimal(int) }
        if let string = value as? String { return Decimal(string: string) ?? 0 }
        return 0
    }

    private static func dateValue(_ value: Any?) -> Date? {
        if let string = value as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: string) { return date }
            let fallback = ISO8601DateFormatter()
            fallback.formatOptions = [.withInternetDateTime]
            return fallback.date(from: string)
        }
        if let double = value as? Double {
            return Date(timeIntervalSince1970: double > 10_000_000_000 ? double / 1000 : double)
        }
        if let int = value as? Int {
            let double = Double(int)
            return Date(timeIntervalSince1970: double > 10_000_000_000 ? double / 1000 : double)
        }
        return nil
    }
}
