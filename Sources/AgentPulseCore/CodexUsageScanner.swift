import Foundation

public enum CodexUsageScanner {
    private struct FileUsage {
        var tokens: Int = 0
        var inputTokens: Int = 0
        var cachedInputTokens: Int = 0
        var outputTokens: Int = 0
        var cost: Decimal?
        var modelTokens: [String: Int] = [:]
        var modelInputTokens: [String: Int] = [:]
        var modelCachedInputTokens: [String: Int] = [:]
        var modelOutputTokens: [String: Int] = [:]
        var modelCosts: [String: Decimal] = [:]
        var dailyTokens: [String: Int] = [:]
        var dailyCosts: [String: Decimal] = [:]
        var firstEventAt: Date?
        var lastEventAt: Date?
        var journalSegments: [JournalSegment] = []

        mutating func add(_ breakdown: TokenBreakdown, cost: Decimal?, model: String? = nil, day: String? = nil, eventDate: Date? = nil) {
            self.tokens += breakdown.total
            inputTokens += breakdown.input
            cachedInputTokens += breakdown.cached
            outputTokens += breakdown.output
            if let cost {
                self.cost = (self.cost ?? 0) + cost
            }
            if let eventDate, breakdown.total > 0 {
                recordJournalUsage(at: eventDate, tokens: breakdown.total, cost: cost)
            }
            if let day, breakdown.total > 0 {
                dailyTokens[day, default: 0] += breakdown.total
                if let cost {
                    dailyCosts[day, default: 0] += cost
                }
            }
            guard let model = model?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty, breakdown.total > 0 else { return }
            modelTokens[model, default: 0] += breakdown.total
            modelInputTokens[model, default: 0] += breakdown.input
            modelCachedInputTokens[model, default: 0] += breakdown.cached
            modelOutputTokens[model, default: 0] += breakdown.output
            if let cost {
                modelCosts[model, default: 0] += cost
            }
        }

        mutating func addCachedEntry(_ entry: UsageCache.FileEntry) {
            tokens += entry.tokens
            inputTokens += entry.inputTokens
            cachedInputTokens += entry.cachedInputTokens
            outputTokens += entry.outputTokens
            if let cost = entry.cost {
                self.cost = (self.cost ?? 0) + cost
            }
            addModelTokens(
                entry.modelTokens,
                input: entry.modelInputTokens,
                cached: entry.modelCachedInputTokens,
                output: entry.modelOutputTokens,
                costs: entry.modelCosts
            )
            addDailyTokens(entry.dailyTokens, costs: entry.dailyCosts)
        }

        mutating func merge(_ other: FileUsage) {
            tokens += other.tokens
            inputTokens += other.inputTokens
            cachedInputTokens += other.cachedInputTokens
            outputTokens += other.outputTokens
            if let cost = other.cost {
                self.cost = (self.cost ?? 0) + cost
            }
            addModelTokens(
                other.modelTokens,
                input: other.modelInputTokens,
                cached: other.modelCachedInputTokens,
                output: other.modelOutputTokens,
                costs: other.modelCosts
            )
            addDailyTokens(other.dailyTokens, costs: other.dailyCosts)
            noteEventRange(first: other.firstEventAt, last: other.lastEventAt)
        }

        mutating func addDailyTokens(_ tokens: [String: Int], costs: [String: Decimal]) {
            for (day, value) in tokens {
                guard value > 0 else { continue }
                dailyTokens[day, default: 0] += value
            }
            for (day, value) in costs {
                dailyCosts[day, default: 0] += value
            }
        }

        mutating func addModelTokens(_ tokens: [String: Int], input: [String: Int], cached: [String: Int], output: [String: Int], costs: [String: Decimal]) {
            for (model, value) in tokens {
                guard value > 0 else { continue }
                modelTokens[model, default: 0] += value
            }
            for (model, value) in input {
                modelInputTokens[model, default: 0] += value
            }
            for (model, value) in cached {
                modelCachedInputTokens[model, default: 0] += value
            }
            for (model, value) in output {
                modelOutputTokens[model, default: 0] += value
            }
            for (model, value) in costs {
                modelCosts[model, default: 0] += value
            }
        }

        mutating func noteEvent(at date: Date, day: String, fallbackDay: String) {
            if firstEventAt == nil || date < firstEventAt! {
                firstEventAt = date
            }
            if lastEventAt == nil || date > lastEventAt! {
                lastEventAt = date
            }
        }

        mutating func noteEventRange(first: Date?, last: Date?) {
            if let first, firstEventAt == nil || first < firstEventAt! {
                firstEventAt = first
            }
            if let last, lastEventAt == nil || last > lastEventAt! {
                lastEventAt = last
            }
        }

        mutating func recordJournalUsage(at date: Date, tokens: Int, cost: Decimal?) {
            guard tokens > 0 else { return }
            if let last = journalSegments.indices.last,
               date.timeIntervalSince(journalSegments[last].endedAt) <= journalMergeWindowSeconds {
                journalSegments[last].endedAt = max(journalSegments[last].endedAt, date)
                journalSegments[last].tokens += tokens
                if let cost {
                    journalSegments[last].cost = (journalSegments[last].cost ?? 0) + cost
                }
                return
            }
            journalSegments.append(JournalSegment(startedAt: date, endedAt: date, tokens: tokens, cost: cost))
        }
    }

    private struct JournalSegment {
        var startedAt: Date
        var endedAt: Date
        var tokens: Int
        var cost: Decimal?
    }

    private static let journalMergeWindowSeconds: TimeInterval = 5 * 60
    private static let journalHistoryDays = 7

    public struct Options: Sendable {
        public var estimateInternalModelCost: Bool
        public var internalCostPerMillionTokens: Decimal

        public init(estimateInternalModelCost: Bool = true, internalCostPerMillionTokens: Decimal = 0.75) {
            self.estimateInternalModelCost = estimateInternalModelCost
            self.internalCostPerMillionTokens = internalCostPerMillionTokens
        }
    }

    public static func scanDailyTokens(root: URL, days: Int = 30, options: Options = Options()) -> [UsageSnapshot.DailyTokenUsage] {
        scanDailyTokens(root: root, days: days, options: options, cache: nil).daily
    }

    public static func scanDailyTokens(root: URL, days: Int = 30, options: Options = Options(), cache: UsageCache?) -> (daily: [UsageSnapshot.DailyTokenUsage], models: [UsageSnapshot.ModelTokenUsage], cache: UsageCache) {
        let result = scanUsage(root: root, days: days, options: options, cache: cache)
        return (result.daily, result.models, result.cache)
    }

    public static func scanUsage(root: URL, days: Int = 30, options: Options = Options(), cache: UsageCache?) -> (daily: [UsageSnapshot.DailyTokenUsage], models: [UsageSnapshot.ModelTokenUsage], journalEntries: [UsageSnapshot.JournalEntry], cache: UsageCache) {
        let calendar = Calendar(identifier: .gregorian)
        var totals: [String: FileUsage] = [:]
        var modelTotals = FileUsage()
        var journalEntries: [UsageSnapshot.JournalEntry] = []
        var nextCache = cache ?? UsageCache()
        if nextCache.schemaVersion < UsageCache.currentSchemaVersion {
            nextCache = UsageCache()
        } else {
            nextCache.schemaVersion = UsageCache.currentSchemaVersion
        }
        var seenPaths = Set<String>()
        let today = dayKey(Date())
        let journalCutoffDay = calendar.date(byAdding: .day, value: -(journalHistoryDays - 1), to: Date()).map(dayKey) ?? today

        for offset in 0..<days {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: Date()) else { continue }
            let key = dayKey(date)
            let directory = dayDirectory(root: root, date: date, calendar: calendar)
            guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else {
                continue
            }
            for file in files where file.pathExtension == "jsonl" && file.lastPathComponent.hasPrefix("rollout-") {
                let path = file.path
                seenPaths.insert(path)
                let metadata = fileMetadata(file)
                if let entry = nextCache.files[path],
                   entry.modifiedAt == metadata.modifiedAt,
                   entry.size == metadata.size,
                   entry.hasCurrentUsageDetails {
                    if key >= journalCutoffDay || entry.dailyTokens.keys.contains(where: { $0 >= journalCutoffDay }) {
                        let fileUsage = usage(in: file, options: options, fallbackDay: key)
                        appendJournalEntries(from: fileUsage, path: path, cutoffDay: journalCutoffDay, into: &journalEntries)
                    }
                    if entry.dailyTokens.isEmpty {
                        totals[entry.day, default: FileUsage()].addCachedEntry(entry)
                    } else {
                        for day in entry.dailyTokens.keys {
                            totals[day, default: FileUsage()].addDailyTokens(
                                [day: entry.dailyTokens[day] ?? 0],
                                costs: [day: entry.dailyCosts[day]].compactMapValues { $0 }
                            )
                        }
                    }
                    modelTotals.addCachedEntry(entry)
                    continue
                }
                let fileUsage = usage(in: file, options: options, fallbackDay: key)
                if key >= journalCutoffDay || fileUsage.dailyTokens.keys.contains(where: { $0 >= journalCutoffDay }) {
                    appendJournalEntries(from: fileUsage, path: path, cutoffDay: journalCutoffDay, into: &journalEntries)
                }
                if fileUsage.dailyTokens.isEmpty {
                    totals[key, default: FileUsage()].merge(fileUsage)
                } else {
                    for day in fileUsage.dailyTokens.keys {
                        totals[day, default: FileUsage()].addDailyTokens(
                            [day: fileUsage.dailyTokens[day] ?? 0],
                            costs: [day: fileUsage.dailyCosts[day]].compactMapValues { $0 }
                        )
                    }
                }
                modelTotals.merge(fileUsage)
                nextCache.files[path] = UsageCache.FileEntry(
                    path: path,
                    modifiedAt: metadata.modifiedAt,
                    size: metadata.size,
                    day: key,
                    tokens: fileUsage.tokens,
                    inputTokens: fileUsage.inputTokens,
                    cachedInputTokens: fileUsage.cachedInputTokens,
                    outputTokens: fileUsage.outputTokens,
                    cost: fileUsage.cost,
                    modelTokens: fileUsage.modelTokens,
                    modelInputTokens: fileUsage.modelInputTokens,
                    modelCachedInputTokens: fileUsage.modelCachedInputTokens,
                    modelOutputTokens: fileUsage.modelOutputTokens,
                    modelCosts: fileUsage.modelCosts,
                    dailyTokens: fileUsage.dailyTokens,
                    dailyCosts: fileUsage.dailyCosts
                )
            }
        }

        nextCache.files = nextCache.files.filter { seenPaths.contains($0.key) }
        let daily = totals
            .map { key, value in
                (
                    key: key,
                    tokens: value.dailyTokens[key] ?? value.tokens,
                    cost: value.dailyCosts[key] ?? value.cost
                )
            }
            .filter { $0.tokens > 0 }
            .sorted { $0.key < $1.key }
            .map { UsageSnapshot.DailyTokenUsage(date: $0.key, tokens: $0.tokens, cost: $0.cost) }
        let models = modelTotals.modelTokens
            .sorted { left, right in
                if left.value == right.value { return left.key < right.key }
                return left.value > right.value
            }
            .map {
                UsageSnapshot.ModelTokenUsage(
                    model: $0.key,
                    tokens: $0.value,
                    inputTokens: modelTotals.modelInputTokens[$0.key] ?? 0,
                    cachedInputTokens: modelTotals.modelCachedInputTokens[$0.key] ?? 0,
                    outputTokens: modelTotals.modelOutputTokens[$0.key] ?? 0,
                    cost: modelTotals.modelCosts[$0.key]
                )
            }
        return (
            daily,
            models,
            journalEntries.sorted { $0.endedAt > $1.endedAt },
            nextCache
        )
    }

    private static func fileMetadata(_ url: URL) -> (modifiedAt: Date, size: Int64) {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return (
            values?.contentModificationDate ?? .distantPast,
            Int64(values?.fileSize ?? 0)
        )
    }

    private static func appendJournalEntries(from fileUsage: FileUsage, path: String, cutoffDay: String, into entries: inout [UsageSnapshot.JournalEntry]) {
        if !fileUsage.journalSegments.isEmpty {
            for (index, segment) in fileUsage.journalSegments.enumerated() where segment.tokens > 0 {
                guard dayKey(segment.startedAt) >= cutoffDay else { continue }
                entries.append(
                    UsageSnapshot.JournalEntry(
                        id: "\(path)#\(index)",
                        startedAt: segment.startedAt,
                        endedAt: segment.endedAt,
                        tokens: segment.tokens,
                        cost: segment.cost,
                        sourcePath: path
                    )
                )
            }
            return
        }
        guard fileUsage.tokens > 0,
              let startedAt = fileUsage.firstEventAt,
              let endedAt = fileUsage.lastEventAt else {
            return
        }
        guard dayKey(startedAt) >= cutoffDay else { return }
        entries.append(
            UsageSnapshot.JournalEntry(
                id: path,
                startedAt: startedAt,
                endedAt: endedAt,
                tokens: fileUsage.tokens,
                cost: fileUsage.cost,
                sourcePath: path
            )
        )
    }

    private static func usage(in file: URL, options: Options, fallbackDay: String) -> FileUsage {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return FileUsage() }
        var usage = FileUsage()
        var maxTotalTokens = 0
        var lastModel: String?
        for line in text.split(separator: "\n") {
            guard
                let data = String(line).data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            let eventDate = dateValue(object["timestamp"])
            let eventDay = eventDate.map(dayKey) ?? dayKey(fromTimestamp: object["timestamp"]) ?? fallbackDay
            if let eventDate {
                usage.noteEvent(at: eventDate, day: eventDay, fallbackDay: fallbackDay)
            }

            if let payload = object["payload"] as? [String: Any] {
                lastModel = modelName(in: object) ?? lastModel
                lastModel = modelName(in: payload) ?? lastModel
                if let info = payload["info"] as? [String: Any] {
                    lastModel = modelName(in: info) ?? lastModel
                    let lastUsage = info["last_token_usage"] as? [String: Any]
                    let last = tokenBreakdown(lastUsage)
                    if last.total > 0 {
                        usage.add(last, cost: cost(model: lastModel, usage: last, rawUsage: lastUsage, options: options), model: lastModel, day: eventDay, eventDate: eventDate)
                    }
                    let total = tokenBreakdown(info["total_token_usage"])
                    maxTotalTokens = max(maxTotalTokens, total.total)
                }
                let directLastUsage = payload["last_token_usage"] as? [String: Any]
                let directLast = tokenBreakdown(directLastUsage)
                if directLast.total > 0 {
                    usage.add(directLast, cost: cost(model: lastModel, usage: directLast, rawUsage: directLastUsage, options: options), model: lastModel, day: eventDay, eventDate: eventDate)
                }
                let directTotal = tokenBreakdown(payload["total_token_usage"])
                maxTotalTokens = max(maxTotalTokens, directTotal.total)
                let directUsage = payload["usage"] as? [String: Any]
                let usageField = tokenBreakdown(directUsage)
                if usageField.total > 0 {
                    lastModel = directUsage.flatMap { modelName(in: $0) } ?? lastModel
                    usage.add(usageField, cost: cost(model: lastModel, usage: usageField, rawUsage: directUsage, options: options), model: lastModel, day: eventDay, eventDate: eventDate)
                }
            }
        }
        if usage.tokens == 0, maxTotalTokens > 0 {
            usage.tokens = maxTotalTokens
            usage.dailyTokens[fallbackDay, default: 0] += maxTotalTokens
            if let lastModel = normalizedModel(lastModel) {
                usage.modelTokens[lastModel, default: 0] += maxTotalTokens
            }
            if let first = usage.firstEventAt, let last = usage.lastEventAt {
                usage.journalSegments.append(JournalSegment(startedAt: first, endedAt: last, tokens: maxTotalTokens, cost: nil))
            }
        }
        return usage
    }

    private static func modelName(in object: [String: Any]) -> String? {
        for key in ["model", "model_slug", "model_name", "model_id"] {
            if let value = object[key] as? String,
               let normalized = normalizedModel(value) {
                return normalized
            }
        }
        return nil
    }

    private static func normalizedModel(_ model: String?) -> String? {
        guard let model = model?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty else {
            return nil
        }
        return model
    }

    private struct TokenBreakdown {
        var input: Int
        var cached: Int
        var output: Int
        var total: Int { input + output }
    }

    private static func tokenBreakdown(_ value: Any?) -> TokenBreakdown {
        guard let usage = value as? [String: Any] else {
            return TokenBreakdown(input: 0, cached: 0, output: 0)
        }
        let input = intValue(usage["input_tokens"])
        let cached = intValue(usage["cached_input_tokens"] ?? usage["cache_read_input_tokens"])
        let output = intValue(usage["output_tokens"])
        let total = intValue(usage["total_tokens"])
        if input == 0, output == 0, total > 0 {
            return TokenBreakdown(input: max(total - cached, 0), cached: cached, output: 0)
        }
        return TokenBreakdown(input: input, cached: cached, output: output)
    }

    private static func actualCost(in usage: [String: Any]?) -> Decimal? {
        guard let usage else { return nil }
        for key in ["cost", "total_cost", "cost_usd", "total_cost_usd", "estimated_cost"] {
            let value = decimalValue(usage[key])
            if value != 0 { return value }
        }
        return nil
    }

    private static func cost(model: String?, usage: TokenBreakdown, rawUsage: [String: Any]?, options: Options) -> Decimal? {
        actualCost(in: rawUsage) ?? estimatedCost(model: model, usage: usage, options: options)
    }

    private static func estimatedCost(model: String?, usage: TokenBreakdown, options: Options) -> Decimal? {
        guard let pricing = pricing(for: model, options: options) else { return nil }
        switch pricing {
        case .flatTotal(let totalPerMillion):
            return Decimal(usage.total) / 1_000_000 * totalPerMillion
        case .tokenClass(let inputPerMillion, let cachedInputPerMillion, let outputPerMillion):
            let billableInput = max(usage.input - usage.cached, 0)
            let inputCost = Decimal(billableInput) / 1_000_000 * inputPerMillion
            let cachedCost = Decimal(usage.cached) / 1_000_000 * cachedInputPerMillion
            let outputCost = Decimal(usage.output) / 1_000_000 * outputPerMillion
            return inputCost + cachedCost + outputCost
        }
    }

    private enum Pricing {
        case flatTotal(Decimal)
        case tokenClass(input: Decimal, cachedInput: Decimal, output: Decimal)
    }

    private static func pricing(for model: String?, options: Options) -> Pricing? {
        guard let model = model?.lowercased() else { return nil }
        if model.contains("gpt-5.5") {
            return .flatTotal(options.internalCostPerMillionTokens)
        }
        if model.contains("codex-auto-review") {
            return .flatTotal(0)
        }
        if model.contains("gpt-5-nano") {
            return .tokenClass(input: 0.05, cachedInput: 0.005, output: 0.4)
        }
        if model.contains("gpt-5-mini") {
            return .tokenClass(input: 0.25, cachedInput: 0.025, output: 2)
        }
        if model.contains("gpt-5") {
            return .tokenClass(input: 1.25, cachedInput: 0.125, output: 10)
        }
        if model.contains("gpt-4.1") {
            return .tokenClass(input: 2, cachedInput: 0.5, output: 8)
        }
        if model.contains("gpt-4o") {
            return .tokenClass(input: 2.5, cachedInput: 1.25, output: 10)
        }
        if model.contains("o3") {
            return .tokenClass(input: 2, cachedInput: 0.5, output: 8)
        }
        if model.contains("o4-mini") {
            return .tokenClass(input: 1.1, cachedInput: 0.275, output: 4.4)
        }
        if options.estimateInternalModelCost, model.contains("codex") {
            return .flatTotal(options.internalCostPerMillionTokens)
        }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int {
        if let int = value as? Int { return int }
        if let double = value as? Double { return Int(double) }
        if let string = value as? String { return Int(string) ?? 0 }
        return 0
    }

    private static func decimalValue(_ value: Any?) -> Decimal {
        if let decimal = value as? Decimal { return decimal }
        if let number = value as? NSNumber { return number.decimalValue }
        if let string = value as? String {
            return Decimal(string: string) ?? 0
        }
        return 0
    }

    private static func dayDirectory(root: URL, date: Date, calendar: Calendar) -> URL {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return root
            .appendingPathComponent(String(format: "%04d", parts.year ?? 0))
            .appendingPathComponent(String(format: "%02d", parts.month ?? 0))
            .appendingPathComponent(String(format: "%02d", parts.day ?? 0))
    }

    private static func dayKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func dayKey(fromTimestamp value: Any?) -> String? {
        let date = dateValue(value)
        guard let date else { return nil }
        return dayKey(date)
    }

    private static func dateValue(_ value: Any?) -> Date? {
        if let string = value as? String {
            return isoDate(string)
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

    private static func isoDate(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime]
        return fallback.date(from: string)
    }
}
