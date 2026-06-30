import Foundation

public struct AppStoragePaths: Sendable {
    public let root: URL
    public let state: URL
    public let usageCache: URL
    public let settings: URL
    public let logs: URL

    public init(fileManager: FileManager = .default) {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        root = support.appendingPathComponent("AgentPulse", isDirectory: true)
        state = root.appendingPathComponent("state.json")
        usageCache = root.appendingPathComponent("usage_cache.json")
        settings = root.appendingPathComponent("settings.json")
        logs = root.appendingPathComponent("logs", isDirectory: true)
    }
}

public final class JSONFileStore<Value: Codable>: @unchecked Sendable {
    private let url: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(url: URL) {
        self.url = url
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    public func load(default defaultValue: @autoclosure () -> Value) -> Value {
        guard let data = try? Data(contentsOf: url) else { return defaultValue() }
        return (try? decoder.decode(Value.self, from: data)) ?? defaultValue()
    }

    public func save(_ value: Value) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try encoder.encode(value)
        try data.write(to: url, options: [.atomic])
    }
}
