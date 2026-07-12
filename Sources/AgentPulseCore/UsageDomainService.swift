import Foundation

public struct UsageDomainModel: Sendable {
    public struct TodaySummary: Sendable {
        public let tokens: Int
        public let cost: Decimal?
        public let activeSeconds: TimeInterval
        public let currentModel: String?
    }

    public struct TrendSummary: Sendable {
        public let last7Days: [UsageSnapshot.DailyTokenUsage]
        public let last30Days: [UsageSnapshot.DailyTokenUsage]
        public let weekTokens: Int
        public let weekCost: Decimal?
        public let monthTokens: Int
        public let monthCost: Decimal?
        public let averageDailyTokens: Int
        public let averageDailyCost: Decimal?
        public let projectedMonthTokens: Int
        public let projectedMonthCost: Decimal?
    }

    public struct TokenSummary: Sendable {
        public let inputTokens: Int
        public let cachedInputTokens: Int
        public let outputTokens: Int
        public let totalBreakdownTokens: Int
    }

    public struct ToolSummary: Sendable {
        public struct Item: Identifiable, Sendable {
            public var id: String { name }
            public let name: String
            public let count: Int
            public let percentage: Int
        }

        public let totalCalls: Int
        public let items: [Item]
    }

    public struct ModelSummary: Sendable {
        public let items: [UsageSnapshot.ModelTokenUsage]
        public let totalTokens: Int
        public let topModel: UsageSnapshot.ModelTokenUsage?
    }

    public struct JournalSummary: Sendable {
        public struct DayGroup: Identifiable, Sendable {
            public var id: String { date }
            public let date: String
            public let entries: [UsageSnapshot.JournalEntry]
            public let totalDurationSeconds: TimeInterval
            public let totalTokens: Int
            public let totalCost: Decimal?
            public let attributedTokens: Int
            public let attributedCost: Decimal?
            public let reconciliationTokens: Int
            public let reconciliationCost: Decimal?
        }

        public let entries: [UsageSnapshot.JournalEntry]
        public let todayEntries: [UsageSnapshot.JournalEntry]
        public let yesterdayEntries: [UsageSnapshot.JournalEntry]
        public let last7DayGroups: [DayGroup]
    }

    public struct QuotaSummary: Sendable {
        public let fiveHourRemainingPercent: Int?
        public let weekRemainingPercent: Int?
        public let fiveHourResetAt: Date?
        public let weekResetAt: Date?
        public let fiveHourWindowSeconds: Int?
        public let weekWindowSeconds: Int?
        public let dataSource: String?
        public let updatedAt: Date?
        public let lastError: String?
        public let lastErrorAt: Date?
    }

    public let today: TodaySummary
    public let trend: TrendSummary
    public let token: TokenSummary
    public let tool: ToolSummary
    public let model: ModelSummary
    public let journal: JournalSummary
    public let quota: QuotaSummary
}

public enum UsageDomainService {
    public static func makeDomainModel(
        usage: UsageSnapshot?,
        calendar: Calendar = Calendar(identifier: .gregorian),
        now: Date = Date()
    ) -> UsageDomainModel {
        let daily = usage?.dailyTokenUsage ?? []
        let dayMap = Dictionary(uniqueKeysWithValues: daily.map { ($0.date, $0) })
        let todayKey = dayKey(now, calendar: calendar)
        let startOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? now
        let dayOfMonth = max(calendar.component(.day, from: now), 1)
        let daysInMonth = calendar.range(of: .day, in: .month, for: now)?.count ?? 30

        let last7Days = days(count: 7, endingAt: now, calendar: calendar, dayMap: dayMap)
        let last30Days = days(count: 30, endingAt: now, calendar: calendar, dayMap: dayMap)
        let monthDays = days(from: startOfMonth, through: now, calendar: calendar, dayMap: dayMap)

        let todayTokens = dayMap[todayKey]?.tokens ?? usage?.todayTokens ?? 0
        let todayCost = dayMap[todayKey]?.cost ?? usage?.todayCost
        let weekTokens = last7Days.reduce(0) { $0 + $1.tokens }
        let weekCost = sumCost(last7Days)
        let monthTokens = monthDays.reduce(0) { $0 + $1.tokens }
        let monthCost = sumCost(monthDays)
        let averageDailyTokens = monthTokens / max(dayOfMonth, 1)
        let averageDailyCost = monthCost.map { $0 / Decimal(max(dayOfMonth, 1)) }

        let inputTokens = usage?.inputTokens ?? 0
        let cachedInputTokens = usage?.cachedInputTokens ?? 0
        let outputTokens = usage?.outputTokens ?? 0
        let modelItems = modelItems(from: usage?.modelTokenUsage ?? [])
        let totalModelTokens = max(modelItems.reduce(0) { $0 + $1.tokens }, 1)
        let toolStats = usage?.toolStats ?? ToolStats()
        let journalEntries = usage?.journalEntries ?? []
        let yesterdayKey = calendar.date(byAdding: .day, value: -1, to: now).map { dayKey($0, calendar: calendar) } ?? todayKey
        let todayJournalActiveSeconds = journalEntries
            .filter { dayKey($0.startedAt, calendar: calendar) == todayKey }
            .reduce(0) { $0 + $1.durationSeconds }
        let todayActiveSeconds = max(usage?.todayActiveSeconds ?? 0, todayJournalActiveSeconds)

        return UsageDomainModel(
            today: UsageDomainModel.TodaySummary(
                tokens: todayTokens,
                cost: todayCost,
                activeSeconds: todayActiveSeconds,
                currentModel: usage?.currentModel
            ),
            trend: UsageDomainModel.TrendSummary(
                last7Days: last7Days,
                last30Days: last30Days,
                weekTokens: weekTokens,
                weekCost: weekCost,
                monthTokens: monthTokens,
                monthCost: monthCost,
                averageDailyTokens: averageDailyTokens,
                averageDailyCost: averageDailyCost,
                projectedMonthTokens: averageDailyTokens * daysInMonth,
                projectedMonthCost: averageDailyCost.map { $0 * Decimal(daysInMonth) }
            ),
            token: UsageDomainModel.TokenSummary(
                inputTokens: inputTokens,
                cachedInputTokens: cachedInputTokens,
                outputTokens: outputTokens,
                totalBreakdownTokens: inputTokens + cachedInputTokens + outputTokens
            ),
            tool: UsageDomainModel.ToolSummary(
                totalCalls: toolStats.total,
                items: toolItems(from: toolStats)
            ),
            model: UsageDomainModel.ModelSummary(
                items: modelItems,
                totalTokens: totalModelTokens,
                topModel: modelItems.first
            ),
            journal: UsageDomainModel.JournalSummary(
                entries: journalEntries,
                todayEntries: journalEntries.filter { dayKey($0.startedAt, calendar: calendar) == todayKey },
                yesterdayEntries: journalEntries.filter { dayKey($0.startedAt, calendar: calendar) == yesterdayKey },
                last7DayGroups: journalDayGroups(from: journalEntries, dailyUsage: dayMap, calendar: calendar, now: now)
            ),
            quota: UsageDomainModel.QuotaSummary(
                fiveHourRemainingPercent: usage?.quota5hRemainingPercent,
                weekRemainingPercent: usage?.quotaWeekRemainingPercent,
                fiveHourResetAt: usage?.quota5hResetAt,
                weekResetAt: usage?.quotaWeekResetAt,
                fiveHourWindowSeconds: usage?.quota5hWindowSeconds,
                weekWindowSeconds: usage?.quotaWeekWindowSeconds,
                dataSource: usage?.quotaDataSource,
                updatedAt: usage?.quotaUpdatedAt,
                lastError: usage?.quotaLastError,
                lastErrorAt: usage?.quotaLastErrorAt
            )
        )
    }

    private static func days(
        count: Int,
        endingAt endDate: Date,
        calendar: Calendar,
        dayMap: [String: UsageSnapshot.DailyTokenUsage]
    ) -> [UsageSnapshot.DailyTokenUsage] {
        (0..<count).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: endDate) else { return nil }
            let key = dayKey(date, calendar: calendar)
            return dayMap[key] ?? UsageSnapshot.DailyTokenUsage(date: key, tokens: 0)
        }
    }

    private static func days(
        from startDate: Date,
        through endDate: Date,
        calendar: Calendar,
        dayMap: [String: UsageSnapshot.DailyTokenUsage]
    ) -> [UsageSnapshot.DailyTokenUsage] {
        let start = calendar.startOfDay(for: startDate)
        let end = calendar.startOfDay(for: endDate)
        let count = (calendar.dateComponents([.day], from: start, to: end).day ?? 0) + 1
        return (0..<max(count, 1)).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
            let key = dayKey(date, calendar: calendar)
            return dayMap[key] ?? UsageSnapshot.DailyTokenUsage(date: key, tokens: 0)
        }
    }

    private static func sumCost(_ values: [UsageSnapshot.DailyTokenUsage]) -> Decimal? {
        let costs = values.compactMap(\.cost)
        guard !costs.isEmpty else { return nil }
        return costs.reduce(Decimal(0), +)
    }

    private static func sumJournalCost(_ values: [UsageSnapshot.JournalEntry]) -> Decimal? {
        let costs = values.compactMap(\.cost)
        guard !costs.isEmpty else { return nil }
        return costs.reduce(Decimal(0), +)
    }

    private static func journalDayGroups(
        from entries: [UsageSnapshot.JournalEntry],
        dailyUsage: [String: UsageSnapshot.DailyTokenUsage],
        calendar: Calendar,
        now: Date
    ) -> [UsageDomainModel.JournalSummary.DayGroup] {
        let grouped = Dictionary(grouping: entries) { dayKey($0.startedAt, calendar: calendar) }
        let cutoff = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)) ?? .distantPast
        let dates = Set(grouped.keys).union(
            dailyUsage.values
                .filter { $0.tokens > 0 && (date(fromDayKey: $0.date, calendar: calendar) ?? .distantPast) >= cutoff }
                .map(\.date)
        )
        return dates
            .map { date in
                let items = grouped[date] ?? []
                let sortedItems = items.sorted { $0.startedAt > $1.startedAt }
                let journalTokens = sortedItems.reduce(0) { $0 + $1.tokens }
                let journalCost = sumJournalCost(sortedItems)
                let daily = dailyUsage[date]
                let dailyTokens = daily?.tokens ?? journalTokens
                let dailyCost = daily?.cost ?? journalCost
                return UsageDomainModel.JournalSummary.DayGroup(
                    date: date,
                    entries: sortedItems,
                    totalDurationSeconds: unionDuration(sortedItems),
                    totalTokens: dailyTokens,
                    totalCost: dailyCost,
                    attributedTokens: journalTokens,
                    attributedCost: journalCost,
                    reconciliationTokens: dailyTokens - journalTokens,
                    reconciliationCost: difference(dailyCost, journalCost)
                )
            }
            .sorted { $0.date > $1.date }
    }

    private static func date(fromDayKey value: String, calendar: Calendar) -> Date? {
        let components = value.split(separator: "-").compactMap { Int($0) }
        guard components.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: components[0], month: components[1], day: components[2]))
    }

    private static func unionDuration(_ entries: [UsageSnapshot.JournalEntry]) -> TimeInterval {
        let intervals = entries
            .filter { $0.endedAt > $0.startedAt }
            .sorted { $0.startedAt < $1.startedAt }
        guard var currentStart = intervals.first?.startedAt,
              var currentEnd = intervals.first?.endedAt else {
            return 0
        }

        var total: TimeInterval = 0
        for entry in intervals.dropFirst() {
            if entry.startedAt <= currentEnd {
                currentEnd = max(currentEnd, entry.endedAt)
            } else {
                total += currentEnd.timeIntervalSince(currentStart)
                currentStart = entry.startedAt
                currentEnd = entry.endedAt
            }
        }
        return total + currentEnd.timeIntervalSince(currentStart)
    }

    private static func difference(_ total: Decimal?, _ attributed: Decimal?) -> Decimal? {
        guard let total else { return nil }
        return total - (attributed ?? 0)
    }

    private static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    private static func modelItems(from models: [UsageSnapshot.ModelTokenUsage]) -> [UsageSnapshot.ModelTokenUsage] {
        models
            .filter { $0.tokens > 0 }
            .sorted {
                if $0.tokens == $1.tokens { return $0.model < $1.model }
                return $0.tokens > $1.tokens
            }
    }

    private static func toolItems(from stats: ToolStats) -> [UsageDomainModel.ToolSummary.Item] {
        let total = stats.total
        guard total > 0 else { return [] }
        return [
            ("Bash", stats.terminalCommands),
            ("Read", stats.readOperations),
            ("Edit", stats.fileChanges),
            ("Write", stats.writeStdin),
            ("Search", stats.searchOperations),
            ("Web", stats.webRequests),
            ("Other", stats.other)
        ]
        .filter { $0.1 > 0 }
        .sorted {
            if $0.1 == $1.1 { return $0.0 < $1.0 }
            return $0.1 > $1.1
        }
        .map { name, count in
            UsageDomainModel.ToolSummary.Item(
                name: name,
                count: count,
                percentage: Int((Double(count) / Double(total) * 100).rounded())
            )
        }
    }

}
