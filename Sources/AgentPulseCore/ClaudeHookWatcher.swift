import Foundation

public struct ClaudeHookEvent: Sendable {
    public var type: String
    public var signal: AgentSignal
    public var message: String
    public var date: Date
    public var toolName: String?

    public init(type: String, signal: AgentSignal, message: String, date: Date = Date(), toolName: String? = nil) {
        self.type = type
        self.signal = signal
        self.message = message
        self.date = date
        self.toolName = toolName
    }

    public var displayTitle: String {
        switch type {
        case "UserPromptSubmit":
            return "提交提示词"
        case "PreToolUse":
            return toolName.map { "准备调用工具 · \($0)" } ?? "准备调用工具"
        case "PostToolUse":
            return toolName.map { "工具调用完成 · \($0)" } ?? "工具调用完成"
        case "Notification":
            return "需要关注"
        case "Stop":
            return "响应完成"
        default:
            return "Claude 事件 · \(type)"
        }
    }
}

public struct ClaudeHookDiagnostics: Codable, Equatable, Sendable {
    public var lastEventType: String?
    public var lastEventAt: Date?
    public var lastStateChangeAt: Date?
    public var lastHookUpdateAt: Date?
    public var lastUnknownEventType: String?

    public init(
        lastEventType: String? = nil,
        lastEventAt: Date? = nil,
        lastStateChangeAt: Date? = nil,
        lastHookUpdateAt: Date? = nil,
        lastUnknownEventType: String? = nil
    ) {
        self.lastEventType = lastEventType
        self.lastEventAt = lastEventAt
        self.lastStateChangeAt = lastStateChangeAt
        self.lastHookUpdateAt = lastHookUpdateAt
        self.lastUnknownEventType = lastUnknownEventType
    }
}

public enum ClaudeHookEventParser {
    public static func parse(_ line: String) -> ClaudeHookEvent? {
        guard
            let data = line.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        guard let eventType = eventType(in: object) else {
            return nil
        }

        let date = dateValue(object["timestamp"]) ?? Date()
        let toolName = stringValue(in: object, keys: ["tool_name", "toolName", "tool", "name"])

        switch eventType {
        case "UserPromptSubmit":
            return ClaudeHookEvent(type: eventType, signal: .thinking, message: "Claude 正在分析提示词", date: date, toolName: toolName)
        case "PreToolUse":
            return ClaudeHookEvent(type: eventType, signal: .working, message: toolName.map { "Claude 准备调用工具 · \($0)" } ?? "Claude 准备调用工具", date: date, toolName: toolName)
        case "PostToolUse":
            return ClaudeHookEvent(type: eventType, signal: .working, message: toolName.map { "Claude 工具调用完成 · \($0)" } ?? "Claude 工具调用完成", date: date, toolName: toolName)
        case "Notification":
            return ClaudeHookEvent(type: eventType, signal: .attention, message: "Claude 需要关注", date: date, toolName: toolName)
        case "Stop":
            return ClaudeHookEvent(type: eventType, signal: .done, message: "Claude 响应完成", date: date, toolName: toolName)
        default:
            return ClaudeHookEvent(type: eventType, signal: .thinking, message: "Claude 事件 · \(eventType)", date: date, toolName: toolName)
        }
    }

    private static func eventType(in object: [String: Any]) -> String? {
        if let direct = stringValue(in: object, keys: ["hook_event_name", "hookEventName", "event", "event_type", "type"]) {
            return direct
        }
        if let payload = object["payload"] as? [String: Any] {
            return eventType(in: payload)
        }
        return nil
    }

    private static func stringValue(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = object[key] as? String, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func dateValue(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: string) {
            return date
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: string)
    }
}

public final class ClaudeHookWatcher: @unchecked Sendable {
    private let logURL: URL
    private let queue = DispatchQueue(label: "app.agentpulse.claude-hook-watcher", qos: .utility)
    private let onEvent: @MainActor @Sendable (ClaudeHookEvent) -> Void
    private let onDiagnostics: @MainActor @Sendable (ClaudeHookDiagnostics) -> Void
    private var fileDescriptor: CInt = -1
    private var source: DispatchSourceFileSystemObject?
    private var offset: UInt64 = 0
    private let startupReplayWindow: TimeInterval = 180

    public init(
        logURL: URL,
        onEvent: @escaping @MainActor @Sendable (ClaudeHookEvent) -> Void,
        onDiagnostics: @escaping @MainActor @Sendable (ClaudeHookDiagnostics) -> Void
    ) {
        self.logURL = logURL
        self.onEvent = onEvent
        self.onDiagnostics = onDiagnostics
    }

    deinit {
        stop()
    }

    public func start() {
        stop()
        queue.async { [weak self] in
            self?.startOnQueue()
        }
    }

    public func stop() {
        queue.async { [weak self] in
            self?.source?.cancel()
            self?.source = nil
            self?.fileDescriptor = -1
        }
    }

    private func startOnQueue() {
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        replayLatestRecentEvent()
        offset = fileSize(logURL)
        fileDescriptor = open(logURL.path, O_EVTONLY)
        guard fileDescriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .extend, .rename, .delete],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            self?.readNewLines()
        }
        source.setCancelHandler { [fileDescriptor] in
            if fileDescriptor >= 0 {
                close(fileDescriptor)
            }
        }
        self.source = source
        source.resume()
    }

    private func readNewLines() {
        let size = fileSize(logURL)
        if size < offset {
            offset = size
            return
        }
        guard size > offset,
              let handle = try? FileHandle(forReadingFrom: logURL) else {
            return
        }
        do {
            try handle.seek(toOffset: offset)
            let data = try handle.readToEnd() ?? Data()
            offset = try handle.offset()
            try handle.close()
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            let hookUpdateAt = Date()
            Task { @MainActor in
                onDiagnostics(ClaudeHookDiagnostics(lastHookUpdateAt: hookUpdateAt))
            }
            for line in lines {
                guard let event = ClaudeHookEventParser.parse(line) else { continue }
                Task { @MainActor in
                    onEvent(event)
                }
            }
        } catch {
            try? handle.close()
        }
    }

    private func fileSize(_ url: URL) -> UInt64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return UInt64(values?.fileSize ?? 0)
    }

    private func replayLatestRecentEvent() {
        guard let text = try? String(contentsOf: logURL, encoding: .utf8),
              let event = text.split(separator: "\n", omittingEmptySubsequences: true)
                .reversed()
                .lazy
                .compactMap({ ClaudeHookEventParser.parse(String($0)) })
                .first,
              Date().timeIntervalSince(event.date) <= startupReplayWindow else {
            return
        }
        Task { @MainActor in
            onDiagnostics(ClaudeHookDiagnostics(
                lastEventType: event.type,
                lastEventAt: event.date,
                lastStateChangeAt: event.date,
                lastHookUpdateAt: event.date
            ))
            onEvent(event)
        }
    }
}
