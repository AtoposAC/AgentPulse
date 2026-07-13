import Foundation

public struct CodexQuotaSnapshot: Sendable {
    public var quota5hRemainingPercent: Int?
    public var quotaWeekRemainingPercent: Int?
    public var quota5hResetAt: Date?
    public var quotaWeekResetAt: Date?
    public var quota5hWindowSeconds: Int?
    public var quotaWeekWindowSeconds: Int?
    public var updatedAt: Date

    public init(
        quota5hRemainingPercent: Int?,
        quotaWeekRemainingPercent: Int?,
        quota5hResetAt: Date? = nil,
        quotaWeekResetAt: Date? = nil,
        quota5hWindowSeconds: Int? = nil,
        quotaWeekWindowSeconds: Int? = nil,
        updatedAt: Date = Date()
    ) {
        self.quota5hRemainingPercent = quota5hRemainingPercent
        self.quotaWeekRemainingPercent = quotaWeekRemainingPercent
        self.quota5hResetAt = quota5hResetAt
        self.quotaWeekResetAt = quotaWeekResetAt
        self.quota5hWindowSeconds = quota5hWindowSeconds
        self.quotaWeekWindowSeconds = quotaWeekWindowSeconds
        self.updatedAt = updatedAt
    }
}

public enum CodexQuotaFetcher {
    public static func fetch() async throws -> CodexQuotaSnapshot {
        let credentials = try loadCredentials()
        var request = URLRequest(url: usageURL())
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("AgentPulse", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let accountID = credentials.accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw URLError(.badServerResponse)
        }
        return try parseSnapshot(data)
    }

    public static func fetchDebugDescription() async throws -> String {
        let credentials = try loadCredentials()
        var request = URLRequest(url: usageURL())
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("AgentPulse", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let accountID = credentials.accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        let parsed = try parseUsageResponse(data)
        return """
        HTTP \(statusCode)
        Raw primary window: \(parsed.rawPrimaryWindow?.debugDescription ?? "missing")
        Raw secondary window: \(parsed.rawSecondaryWindow?.debugDescription ?? "missing")
        Classified 5h window: \(parsed.fiveHourWindow?.debugDescription ?? "missing")
        Classified weekly window: \(parsed.weekWindow?.debugDescription ?? "missing")
        """
    }

    static func parseSnapshot(_ data: Data, updatedAt: Date = Date()) throws -> CodexQuotaSnapshot {
        let parsed = try parseUsageResponse(data)
        return CodexQuotaSnapshot(
            quota5hRemainingPercent: parsed.fiveHourWindow?.remainingPercent,
            quotaWeekRemainingPercent: parsed.weekWindow?.remainingPercent,
            quota5hResetAt: parsed.fiveHourWindow?.resetAt,
            quotaWeekResetAt: parsed.weekWindow?.resetAt,
            quota5hWindowSeconds: parsed.fiveHourWindow?.limitWindowSeconds,
            quotaWeekWindowSeconds: parsed.weekWindow?.limitWindowSeconds,
            updatedAt: updatedAt
        )
    }

    private struct Credentials {
        var accessToken: String
        var accountID: String?
    }

    private static func loadCredentials() throws -> Credentials {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/auth.json")
        let data = try Data(contentsOf: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = json["tokens"] as? [String: Any],
              let accessToken = stringValue(in: tokens, keys: ["access_token", "accessToken"]),
              !accessToken.isEmpty else {
            throw URLError(.userAuthenticationRequired)
        }
        return Credentials(
            accessToken: accessToken,
            accountID: stringValue(in: tokens, keys: ["account_id", "accountId"])
        )
    }

    private static func usageURL() -> URL {
        URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    }

    private static func stringValue(in dictionary: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = dictionary[key] as? String {
                return value
            }
        }
        return nil
    }

    private static func remainingPercent(usedPercent: Double) -> Double {
        let normalizedUsed = usedPercent < 1 ? usedPercent * 100 : usedPercent
        return max(0, min(100, 100 - max(0, min(100, normalizedUsed)))).rounded()
    }

    private static func parseUsageResponse(_ data: Data) throws -> ParsedUsageResponse {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        let container = dictionaryValue(root["rate_limit"])
            ?? dictionaryValue(root["rateLimit"])
            ?? dictionaryValue(root["usage"])
            ?? root
        let rawPrimary = parseWindow(
            dictionaryValue(container["primary_window"])
                ?? dictionaryValue(container["primaryWindow"])
        )
        let rawSecondary = parseWindow(
            dictionaryValue(container["secondary_window"])
                ?? dictionaryValue(container["secondaryWindow"])
        )
        let explicitFiveHour = parseWindow(
            dictionaryValue(container["five_hour_window"])
                ?? dictionaryValue(container["fiveHourWindow"])
        )
        let explicitWeek = parseWindow(
            dictionaryValue(container["weekly_window"])
                ?? dictionaryValue(container["weeklyWindow"])
        )
        let genericWindows = [rawPrimary, rawSecondary].compactMap { $0 }
        var fiveHour = explicitFiveHour ?? genericWindows.first(where: isFiveHourWindow)
        var week = explicitWeek ?? genericWindows.first(where: isWeekWindow)

        // Preserve the historical primary/secondary convention only when both windows exist
        // and neither includes enough metadata to classify safely.
        if fiveHour == nil,
           week == nil,
           let rawPrimary,
           let rawSecondary,
           rawPrimary.limitWindowSeconds == nil,
           rawSecondary.limitWindowSeconds == nil {
            fiveHour = rawPrimary
            week = rawSecondary
        }

        return ParsedUsageResponse(
            rawPrimaryWindow: rawPrimary,
            rawSecondaryWindow: rawSecondary,
            fiveHourWindow: fiveHour,
            weekWindow: week
        )
    }

    private static func isFiveHourWindow(_ window: ParsedWindow) -> Bool {
        guard let seconds = window.limitWindowSeconds else { return false }
        return (4 * 60 * 60)...(6 * 60 * 60) ~= seconds
    }

    private static func isWeekWindow(_ window: ParsedWindow) -> Bool {
        guard let seconds = window.limitWindowSeconds else { return false }
        return (5 * 24 * 60 * 60)...(8 * 24 * 60 * 60) ~= seconds
    }

    private static func parseWindow(_ window: [String: Any]?) -> ParsedWindow? {
        guard let window else { return nil }
        let remaining = numberValue(in: window, keys: ["remaining_percent", "remainingPercent"]).map { value in
            Int(max(0, min(100, value < 1 ? value * 100 : value)).rounded())
        }
        let used = numberValue(in: window, keys: ["used_percent", "usedPercent", "usage_percent", "usagePercent"])
        let resetAt = dateValue(in: window, keys: ["reset_at", "resetAt", "resets_at", "resetsAt", "end_time", "endTime", "ends_at", "endsAt"])
        let seconds = numberValue(in: window, keys: ["limit_window_seconds", "limitWindowSeconds", "window_seconds", "windowSeconds", "duration_seconds", "durationSeconds"]).map(Int.init)
        return ParsedWindow(
            remainingPercent: remaining ?? used.map { Int(remainingPercent(usedPercent: $0)) },
            resetAt: resetAt,
            limitWindowSeconds: seconds,
            rawKeys: window.keys.sorted()
        )
    }

    private static func dictionaryValue(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    private static func numberValue(in dictionary: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let value = dictionary[key] as? Double { return value }
            if let value = dictionary[key] as? Int { return Double(value) }
            if let value = dictionary[key] as? String, let double = Double(value) { return double }
        }
        return nil
    }

    private static func dateValue(in dictionary: [String: Any], keys: [String]) -> Date? {
        for key in keys {
            guard let value = dictionary[key] else { continue }
            if let double = value as? Double { return dateFromTimestamp(double) }
            if let int = value as? Int { return dateFromTimestamp(Double(int)) }
            if let string = value as? String {
                if let double = Double(string) {
                    return dateFromTimestamp(double)
                }
                if let date = isoDate(string) {
                    return date
                }
            }
        }
        return nil
    }

    private static func dateFromTimestamp(_ value: Double) -> Date {
        let seconds = value > 10_000_000_000 ? value / 1000 : value
        return Date(timeIntervalSince1970: seconds)
    }

    private static func isoDate(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime]
        return fallback.date(from: string)
    }
}

private struct ParsedUsageResponse {
    var rawPrimaryWindow: ParsedWindow?
    var rawSecondaryWindow: ParsedWindow?
    var fiveHourWindow: ParsedWindow?
    var weekWindow: ParsedWindow?
}

private struct ParsedWindow {
    var remainingPercent: Int?
    var resetAt: Date?
    var limitWindowSeconds: Int?
    var rawKeys: [String]

    var debugDescription: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return "remaining=\(remainingPercent.map(String.init) ?? "unknown")%, reset=\(resetAt.map { formatter.string(from: $0) } ?? "unknown"), windowSeconds=\(limitWindowSeconds.map(String.init) ?? "unknown"), keys=\(rawKeys.joined(separator: ","))"
    }
}
