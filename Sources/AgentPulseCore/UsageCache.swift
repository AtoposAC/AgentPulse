import Foundation

public struct UsageCache: Codable, Sendable {
    public static let currentSchemaVersion = 6

    public struct FileEntry: Codable, Sendable {
        public var path: String
        public var modifiedAt: Date
        public var size: Int64
        public var day: String
        public var tokens: Int
        public var inputTokens: Int
        public var cachedInputTokens: Int
        public var outputTokens: Int
        public var cost: Decimal?
        public var modelTokens: [String: Int]
        public var modelInputTokens: [String: Int]
        public var modelCachedInputTokens: [String: Int]
        public var modelOutputTokens: [String: Int]
        public var modelCosts: [String: Decimal]
        public var dailyTokens: [String: Int]
        public var dailyCosts: [String: Decimal]

        enum CodingKeys: String, CodingKey {
            case path
            case modifiedAt
            case size
            case day
            case tokens
            case inputTokens
            case cachedInputTokens
            case outputTokens
            case cost
            case modelTokens
            case modelInputTokens
            case modelCachedInputTokens
            case modelOutputTokens
            case modelCosts
            case dailyTokens
            case dailyCosts
        }

        public init(
            path: String,
            modifiedAt: Date,
            size: Int64,
            day: String,
            tokens: Int,
            inputTokens: Int = 0,
            cachedInputTokens: Int = 0,
            outputTokens: Int = 0,
            cost: Decimal?,
            modelTokens: [String: Int] = [:],
            modelInputTokens: [String: Int] = [:],
            modelCachedInputTokens: [String: Int] = [:],
            modelOutputTokens: [String: Int] = [:],
            modelCosts: [String: Decimal] = [:],
            dailyTokens: [String: Int] = [:],
            dailyCosts: [String: Decimal] = [:]
        ) {
            self.path = path
            self.modifiedAt = modifiedAt
            self.size = size
            self.day = day
            self.tokens = tokens
            self.inputTokens = inputTokens
            self.cachedInputTokens = cachedInputTokens
            self.outputTokens = outputTokens
            self.cost = cost
            self.modelTokens = modelTokens
            self.modelInputTokens = modelInputTokens
            self.modelCachedInputTokens = modelCachedInputTokens
            self.modelOutputTokens = modelOutputTokens
            self.modelCosts = modelCosts
            self.dailyTokens = dailyTokens
            self.dailyCosts = dailyCosts
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            path = try container.decode(String.self, forKey: .path)
            modifiedAt = try container.decode(Date.self, forKey: .modifiedAt)
            size = try container.decode(Int64.self, forKey: .size)
            day = try container.decode(String.self, forKey: .day)
            tokens = try container.decode(Int.self, forKey: .tokens)
            inputTokens = try container.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0
            cachedInputTokens = try container.decodeIfPresent(Int.self, forKey: .cachedInputTokens) ?? 0
            outputTokens = try container.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
            cost = try container.decodeIfPresent(Decimal.self, forKey: .cost)
            modelTokens = try container.decodeIfPresent([String: Int].self, forKey: .modelTokens) ?? [:]
            modelInputTokens = try container.decodeIfPresent([String: Int].self, forKey: .modelInputTokens) ?? [:]
            modelCachedInputTokens = try container.decodeIfPresent([String: Int].self, forKey: .modelCachedInputTokens) ?? [:]
            modelOutputTokens = try container.decodeIfPresent([String: Int].self, forKey: .modelOutputTokens) ?? [:]
            modelCosts = try container.decodeIfPresent([String: Decimal].self, forKey: .modelCosts) ?? [:]
            dailyTokens = try container.decodeIfPresent([String: Int].self, forKey: .dailyTokens) ?? [:]
            dailyCosts = try container.decodeIfPresent([String: Decimal].self, forKey: .dailyCosts) ?? [:]
        }

        public var hasCurrentUsageDetails: Bool {
            tokens == 0 || (!modelTokens.isEmpty && !dailyTokens.isEmpty && inputTokens + cachedInputTokens + outputTokens > 0)
        }
    }

    public var schemaVersion: Int
    public var files: [String: FileEntry]

    public init(schemaVersion: Int = UsageCache.currentSchemaVersion, files: [String: FileEntry] = [:]) {
        self.schemaVersion = schemaVersion
        self.files = files
    }
}
