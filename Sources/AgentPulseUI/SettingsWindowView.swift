import SwiftUI
import AppKit
import ServiceManagement
import AgentPulseCore

private struct AgentPulseSettingsKey: EnvironmentKey {
    static let defaultValue = AgentPulseSettings()
}

private extension EnvironmentValues {
    var agentPulseSettings: AgentPulseSettings {
        get { self[AgentPulseSettingsKey.self] }
        set { self[AgentPulseSettingsKey.self] = newValue }
    }
}

public struct SettingsWindowView: View {
    @ObservedObject private var store: AgentPulseStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var selected: SettingsPage = .dashboard

    public init(store: AgentPulseStore) {
        self.store = store
    }

    public var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().opacity(0.45)
            VStack(spacing: 0) {
                TopBar(store: store, selected: selected)
                Divider().opacity(0.45)
                ZStack {
                    tabContent(.dashboard) { DashboardPage(store: store) }
                    tabContent(.agents) { AgentsPage(store: store) }
                    tabContent(.usage) { UsagePage(store: store) }
                    tabContent(.connections) { ConnectionsPage(store: store) }
                    tabContent(.preferences) { PreferencesPage(store: store) }
                    tabContent(.about) { AboutPage() }
                }
            }
        }
        .frame(width: 860, height: 590)
        .background(store.settings.settingsBackdrop(system: colorScheme))
        .foregroundStyle(store.settings.primaryText(system: colorScheme))
        .preferredColorScheme(store.settings.preferredColorScheme)
        .environment(\.agentPulseSettings, store.settings)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "waveform.path.ecg.rectangle")
                    .font(.system(size: 27, weight: .semibold))
                    .foregroundStyle(AgentPulseColors.token)
                VStack(alignment: .leading, spacing: 1) {
                    Text("AgentPulse")
                        .font(.system(size: 17, weight: .semibold))
                    Text("Local monitor")
                        .font(.caption)
                        .foregroundStyle(store.settings.secondaryText(system: colorScheme))
                }
            }
            .padding(.bottom, 8)

            ForEach(SettingsPage.allCases) { page in
                SidebarButton(page: page, selected: selected == page) {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        selected = page
                    }
                }
            }

            Spacer()

            VStack(alignment: .leading, spacing: 8) {
                StatusPill(title: "Codex", good: store.settings.codexMonitoringEnabled)
                Text("Local / not notarized")
                    .font(.caption2)
                    .foregroundStyle(store.settings.tertiaryText(system: colorScheme))
            }
        }
        .padding(18)
        .frame(width: 188)
        .background(store.settings.panelFill(system: colorScheme))
    }

    @ViewBuilder
    private func tabContent<Content: View>(_ page: SettingsPage, @ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            content()
                .padding(20)
        }
        .opacity(selected == page ? 1 : 0)
        .allowsHitTesting(selected == page)
        .accessibilityHidden(selected != page)
    }
}

private enum SettingsPage: String, CaseIterable, Identifiable {
    case dashboard
    case agents
    case usage
    case connections
    case preferences
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: "总览"
        case .agents: "Agent"
        case .usage: "Usage Center"
        case .connections: "连接"
        case .preferences: "设置"
        case .about: "关于"
        }
    }

    var icon: String {
        switch self {
        case .dashboard: "gauge.with.dots.needle.bottom.50percent"
        case .agents: "rectangle.stack.badge.person.crop"
        case .usage: "chart.bar.xaxis"
        case .connections: "link"
        case .preferences: "switch.2"
        case .about: "info.circle"
        }
    }
}

private struct TopBar: View {
    @ObservedObject var store: AgentPulseStore
    @Environment(\.colorScheme) private var colorScheme
    let selected: SettingsPage

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(selected.title)
                    .font(.title2.weight(.semibold))
                Text(summary)
                    .font(.system(size: 13))
                    .foregroundStyle(store.settings.secondaryText(system: colorScheme))
            }
            Spacer()
            Button("显示胶囊") {
                var copy = store.settings
                copy.showFloatingWindow = true
                store.updateSettings(copy)
                NotificationCenter.default.post(name: Notification.Name("AgentPulseResetFloatingWindow"), object: nil)
            }
            Button(store.settings.monitoringPaused ? "恢复监控" : "暂停监控") {
                store.setPaused(!store.settings.monitoringPaused)
            }
            .keyboardShortcut("p", modifiers: [.command])
            Button("刷新") {
                store.refresh()
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    private var summary: String {
        if store.settings.monitoringPaused { return "监控已暂停，悬浮胶囊保留最后一次状态。" }
        return store.visibleAgents.map { "\($0.kind.displayName) \($0.signal.title)" }.joined(separator: " · ")
    }
}

private struct DashboardPage: View {
    @ObservedObject var store: AgentPulseStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                HeroStatusCard(store: store)
                QuickActionsCard(store: store)
            }
            UsageForecastCard(store: store)
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 12) {
                    ForEach(store.visibleAgents) { agent in
                        AgentCard(agent: agent)
                    }
                    if store.visibleAgents.isEmpty {
                        EmptyState(text: "还没有启用任何 Agent。打开 Codex 自动监控后即可开始。")
                    }
                }
                .frame(maxWidth: .infinity)
                RecentEventsCard(events: events)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var events: [AgentEvent] {
        store.agents.flatMap(\.recentEvents).sorted { $0.date > $1.date }.prefix(8).map { $0 }
    }
}

private struct AgentsPage: View {
    @ObservedObject var store: AgentPulseStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            AgentToggleCard(
                title: "Codex",
                subtitle: "免 Hook 读取本地会话日志，适合 Desktop / CLI 场景。",
                enabled: binding(\.codexMonitoringEnabled),
                installed: true,
                actions: {
                    Button("打开日志目录") { NSWorkspace.shared.open(store.codexSessionRoot) }
                    Button("诊断事件") { copyCodexHint() }
                }
            )
            GlassPanel(title: "本地脚本") {
                Text("可通过 CLI 写入本地状态文件，适合临时脚本或自动化任务接入。")
                    .font(.system(size: 13))
                    .foregroundStyle(store.settings.secondaryText(system: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                StatusPill(title: "文件接入", good: true)
                HStack {
                    Button("复制状态路径") { copy(store.stateFileURL.path) }
                    Button("复制示例命令") { copy(".build/debug/agentpulse-cli set local working 正在执行本地任务") }
                }
            }
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<AgentPulseSettings, Value>) -> Binding<Value> {
        Binding {
            store.settings[keyPath: keyPath]
        } set: { value in
            var copy = store.settings
            copy[keyPath: keyPath] = value
            store.updateSettings(copy)
        }
    }

    private func copyCodexHint() {
        copy("cd /Users/m5/Documents/AgentPulse && .build/debug/agentpulse-cli diagnose-codex")
    }
}

private struct UsageCenterSummary {
    let todayTokens: Int
    let weekTokens: Int
    let monthTokens: Int
    let todayCost: Decimal?
    let weekCost: Decimal?
    let monthCost: Decimal?
    let last7Days: [UsageSnapshot.DailyTokenUsage]
    let last30Days: [UsageSnapshot.DailyTokenUsage]
    let averageDailyTokens: Int
    let averageDailyCost: Decimal?
    let projectedMonthTokens: Int
    let projectedMonthCost: Decimal?

    init(usage: UsageSnapshot?, calendar: Calendar = Calendar(identifier: .gregorian), now: Date = Date()) {
        let daily = usage?.dailyTokenUsage ?? []
        let dayMap = Dictionary(uniqueKeysWithValues: daily.map { ($0.date, $0) })
        let todayKey = Self.dayKey(now, calendar: calendar)
        let startOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? now
        let dayOfMonth = max(calendar.component(.day, from: now), 1)
        let daysInMonth = calendar.range(of: .day, in: .month, for: now)?.count ?? 30

        last7Days = Self.days(count: 7, endingAt: now, calendar: calendar, dayMap: dayMap)
        last30Days = Self.days(count: 30, endingAt: now, calendar: calendar, dayMap: dayMap)
        let monthDays = Self.days(from: startOfMonth, through: now, calendar: calendar, dayMap: dayMap)

        todayTokens = dayMap[todayKey]?.tokens ?? usage?.todayTokens ?? 0
        todayCost = dayMap[todayKey]?.cost ?? usage?.todayCost
        weekTokens = last7Days.reduce(0) { $0 + $1.tokens }
        weekCost = Self.sumCost(last7Days)
        monthTokens = monthDays.reduce(0) { $0 + $1.tokens }
        monthCost = Self.sumCost(monthDays)
        averageDailyTokens = monthTokens / max(dayOfMonth, 1)
        averageDailyCost = monthCost.map { $0 / Decimal(max(dayOfMonth, 1)) }
        projectedMonthTokens = averageDailyTokens * daysInMonth
        projectedMonthCost = averageDailyCost.map { $0 * Decimal(daysInMonth) }
    }

    private static func days(count: Int, endingAt endDate: Date, calendar: Calendar, dayMap: [String: UsageSnapshot.DailyTokenUsage]) -> [UsageSnapshot.DailyTokenUsage] {
        (0..<count).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: endDate) else { return nil }
            let key = dayKey(date, calendar: calendar)
            return dayMap[key] ?? UsageSnapshot.DailyTokenUsage(date: key, tokens: 0)
        }
    }

    private static func days(from startDate: Date, through endDate: Date, calendar: Calendar, dayMap: [String: UsageSnapshot.DailyTokenUsage]) -> [UsageSnapshot.DailyTokenUsage] {
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

    private static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

private struct UsageForecastCard: View {
    @ObservedObject var store: AgentPulseStore
    @Environment(\.colorScheme) private var colorScheme

    private var codex: AgentSnapshot? { store.agents.first(where: { $0.kind == .codex }) }
    private var usage: UsageCenterSummary { UsageCenterSummary(usage: codex?.usage) }

    var body: some View {
        GlassPanel(title: "Usage Center") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                compactMetric("本月累计消耗", AgentPulseFormatters.money(usage.monthCost, privacy: store.settings.privacyMode), AgentPulseColors.working)
                compactMetric("预计本月消耗", AgentPulseFormatters.money(usage.projectedMonthCost, privacy: store.settings.privacyMode), AgentPulseColors.thinking)
                compactMetric("预计剩余额度", remainingQuotaText, quotaTint)
                compactMetric("平均每日 Token", AgentPulseFormatters.tokens(usage.averageDailyTokens), AgentPulseColors.token)
                compactMetric("平均每日 Cost", AgentPulseFormatters.money(usage.averageDailyCost, privacy: store.settings.privacyMode), AgentPulseColors.working)
            }
            Text("全部基于本地 Codex 会话日志聚合；不接入第三方服务。")
                .font(.caption)
                .foregroundStyle(store.settings.secondaryText(system: colorScheme))
        }
    }

    private func compactMetric(_ title: String, _ value: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(store.settings.secondaryText(system: colorScheme))
            Text(value)
                .font(.system(size: 17, weight: .semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.78)
            RoundedRectangle(cornerRadius: 2)
                .fill(tint.opacity(0.72))
                .frame(height: 3)
        }
        .padding(12)
        .background(store.settings.isDarkMode(system: colorScheme) ? Color.white.opacity(0.045) : Color.black.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }

    private var remainingQuotaText: String {
        if let week = codex?.usage.quotaWeekRemainingPercent {
            return "\(week)% 本周"
        }
        if let fiveHour = codex?.usage.quota5hRemainingPercent {
            return "\(fiveHour)% 5小时"
        }
        return "待确认"
    }

    private var quotaTint: Color {
        let value = codex?.usage.quotaWeekRemainingPercent ?? codex?.usage.quota5hRemainingPercent ?? 0
        if value <= 20 { return AgentPulseColors.attention }
        if value <= 50 { return AgentPulseColors.thinking }
        return AgentPulseColors.working
    }
}

private struct UsagePage: View {
	    @ObservedObject var store: AgentPulseStore
	    @Environment(\.colorScheme) private var colorScheme
	    var codex: AgentSnapshot? { store.agents.first(where: { $0.kind == .codex }) }
	    var usageCenter: UsageCenterSummary { UsageCenterSummary(usage: codex?.usage) }
	
	    var body: some View {
	        VStack(alignment: .leading, spacing: 16) {
	            UsageHealthCard(
	                title: usageHealthTitle,
	                detail: usageHealthDetail,
	                tint: usageHealthTint
	            )
	            LazyVGrid(columns: metricColumns, spacing: 12) {
	                MetricTile(title: "Today Tokens", value: AgentPulseFormatters.tokens(usageCenter.todayTokens), tint: AgentPulseColors.token)
	                MetricTile(title: "Week Tokens", value: AgentPulseFormatters.tokens(usageCenter.weekTokens), tint: AgentPulseColors.thinking)
	                MetricTile(title: "Month Tokens", value: AgentPulseFormatters.tokens(usageCenter.monthTokens), tint: AgentPulseColors.working)
	                MetricTile(title: "Today Cost", value: AgentPulseFormatters.money(usageCenter.todayCost, privacy: store.settings.privacyMode), tint: AgentPulseColors.working)
	                MetricTile(title: "Week Cost", value: AgentPulseFormatters.money(usageCenter.weekCost, privacy: store.settings.privacyMode), tint: AgentPulseColors.token)
	                MetricTile(title: "Month Cost", value: AgentPulseFormatters.money(usageCenter.monthCost, privacy: store.settings.privacyMode), tint: AgentPulseColors.thinking)
	            }
	            GlassPanel(title: "数据来源") {
                HStack {
                    Text("本地扫描")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(store.settings.secondaryText(system: colorScheme))
                    Spacer()
                    Button(store.isRefreshingUsage ? "刷新中…" : "刷新用量") { store.refreshUsageNow() }
                        .disabled(store.isRefreshingUsage)
                }
                SourceRow(title: "Token", value: codex?.usage.tokenDataSource ?? "~/.codex/sessions JSONL", detail: scannedFileDetail)
                SourceRow(title: "额度", value: codex?.usage.quotaDataSource ?? "等待首次刷新", detail: quotaUpdateDetail)
            }
            GlassPanel(title: "额度") {
                HStack {
                    Text("Codex WHAM")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(store.settings.secondaryText(system: colorScheme))
                    Spacer()
                    Button(store.isRefreshingCodexQuota ? "刷新中…" : "刷新额度") { store.refreshCodexQuotaNow() }
                        .disabled(store.isRefreshingCodexQuota)
                }
                QuotaLine(title: "5 小时额度", value: codex?.usage.quota5hRemainingPercent ?? 0, detail: quotaResetDetail(codex?.usage.quota5hResetAt, windowSeconds: codex?.usage.quota5hWindowSeconds))
                QuotaLine(title: "本周额度", value: codex?.usage.quotaWeekRemainingPercent ?? 0, detail: quotaResetDetail(codex?.usage.quotaWeekResetAt, windowSeconds: codex?.usage.quotaWeekWindowSeconds, includesDate: true))
                if let quotaErrorDetail {
                    StatusNote(text: quotaErrorDetail, tone: .warning)
                }
                if let lowQuotaDetail {
                    StatusNote(text: lowQuotaDetail, tone: .warning)
                }
                Text("优先显示 Codex WHAM 实时额度；接口不可用时，使用本地会话 token 给出临时参考。")
                    .font(.caption)
                    .foregroundStyle(store.settings.secondaryText(system: colorScheme))
            }
	            GlassPanel(title: "最近 7 天趋势") {
	                if usageCenter.last7Days.allSatisfy({ $0.tokens == 0 }) {
	                    EmptyState(text: "最近 7 天暂无 token 数据。")
	                } else {
	                    UsageBarChart(values: usageCenter.last7Days.map(\.tokens), labels: usageCenter.last7Days.map(\.date), tint: AgentPulseColors.working)
	                    HStack {
	                        Text(usageCenter.last7Days.first?.date ?? "")
	                        Spacer()
	                        Text("按日 token 使用量")
	                        Spacer()
	                        Text(usageCenter.last7Days.last?.date ?? "")
	                    }
	                    .font(.caption)
	                    .foregroundStyle(store.settings.secondaryText(system: colorScheme))
	                }
	            }
	            GlassPanel(title: "最近 30 天趋势") {
	                if usageCenter.last30Days.allSatisfy({ $0.tokens == 0 }) {
	                    EmptyState(text: "暂无每日 token 数据。运行产生 usage 字段的 Codex 会话后，这里才会绘制柱状图。")
	                } else {
	                    UsageBarChart(values: usageCenter.last30Days.map(\.tokens), labels: usageCenter.last30Days.map(\.date), tint: AgentPulseColors.token)
	                    HStack {
	                        Text(usageCenter.last30Days.first?.date ?? "")
	                        Spacer()
	                        Text("按日 token 使用量")
	                        Spacer()
	                        Text(usageCenter.last30Days.last?.date ?? "")
	                    }
                    .font(.caption)
                    .foregroundStyle(store.settings.secondaryText(system: colorScheme))
                }
            }
            GlassPanel(title: "Token 结构") {
                if tokenBreakdownTotal == 0 {
                    EmptyState(text: "暂未解析到 input / cached / output 明细。")
                } else {
                    TokenBreakdownRow(title: "Input", value: codex?.usage.inputTokens ?? 0, total: tokenBreakdownTotal, tint: AgentPulseColors.thinking)
                    TokenBreakdownRow(title: "Cached", value: codex?.usage.cachedInputTokens ?? 0, total: tokenBreakdownTotal, tint: AgentPulseColors.token)
                    TokenBreakdownRow(title: "Output", value: codex?.usage.outputTokens ?? 0, total: tokenBreakdownTotal, tint: AgentPulseColors.working)
                }
            }
            GlassPanel(title: "模型明细") {
                if modelValues.isEmpty {
                    EmptyState(text: "暂未解析到模型字段。新的 Codex 会话刷新后，这里会显示各模型 token 占比。")
                } else {
                    ForEach(modelValues) { item in
                        ModelUsageRow(item: item, total: totalModelTokens, privacy: store.settings.privacyMode)
                    }
                }
            }
            GlassPanel(title: "工具调用") {
                Text(toolStatsDetail)
                    .font(.caption)
                    .foregroundStyle(store.settings.secondaryText(system: colorScheme))
                ToolRow("终端命令", codex?.toolStats.terminalCommands ?? 0)
                ToolRow("修改文件", codex?.toolStats.fileChanges ?? 0)
                ToolRow("write_stdin", codex?.toolStats.writeStdin ?? 0)
                ToolRow("其他", codex?.toolStats.other ?? 0)
            }
        }
    }

    private var modelValues: [UsageSnapshot.ModelTokenUsage] {
        codex?.usage.modelTokenUsage.prefix(6).map { $0 } ?? []
    }

    private var totalModelTokens: Int {
        max(codex?.usage.modelTokenUsage.reduce(0) { $0 + $1.tokens } ?? 0, 1)
    }

    private var tokenBreakdownTotal: Int {
        (codex?.usage.inputTokens ?? 0)
        + (codex?.usage.cachedInputTokens ?? 0)
        + (codex?.usage.outputTokens ?? 0)
    }

    private var metricColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 150), spacing: 12)]
    }

    private var usageHealthTitle: String {
        guard codex?.usage.usageScannedAt != nil else { return "等待首次用量扫描" }
        guard let latest = codex?.usage.latestSessionModifiedAt else { return "用量数据已就绪" }
        let age = Date().timeIntervalSince(latest)
        if age < 90 { return "实时数据正在更新" }
        if age < 900 { return "用量数据已同步" }
        return "最近暂无新会话写入"
    }

    private var usageHealthDetail: String {
        let tokens = AgentPulseFormatters.tokens(codex?.usage.todayTokens)
        let scanned = codex?.usage.scannedFileCount ?? 0
        if let scanDate = codex?.usage.usageScannedAt {
            return "今日 \(tokens) · 已索引 \(scanned) 个会话 · \(scanDate.formatted(date: .omitted, time: .standard)) 更新"
        }
        return "打开或继续一次 Codex 会话后，AgentPulse 会自动读取本地 usage 数据。"
    }

    private var usageHealthTint: Color {
        guard let latest = codex?.usage.latestSessionModifiedAt else { return AgentPulseColors.thinking }
        return Date().timeIntervalSince(latest) < 900 ? AgentPulseColors.working : AgentPulseColors.token
    }

    private func quotaMetricTint(_ value: Int) -> Color {
        if value <= 20 { return AgentPulseColors.attention }
        if value <= 50 { return AgentPulseColors.thinking }
        return AgentPulseColors.working
    }

    private var scannedFileDetail: String {
        let count = codex?.usage.scannedFileCount ?? 0
        let scanText = codex?.usage.usageScannedAt.map { " · 更新于 \($0.formatted(date: .omitted, time: .standard))" } ?? ""
        let latestText = latestSessionDetail
        return count > 0 ? "已索引 \(count) 个会话文件\(scanText)\(latestText)。" : "还没有索引到可用 usage 数据。"
    }

    private var latestSessionDetail: String {
        guard let path = codex?.usage.latestSessionPath else { return "" }
        let file = URL(fileURLWithPath: path).lastPathComponent
        if let date = codex?.usage.latestSessionModifiedAt {
            return " · 最新 \(file) \(date.formatted(date: .omitted, time: .shortened))"
        }
        return " · 最新 \(file)"
    }

    private var toolStatsDetail: String {
        guard let path = codex?.usage.latestSessionPath else {
            return "来自最新 Codex session。"
        }
        let file = URL(fileURLWithPath: path).lastPathComponent
        if let date = codex?.usage.latestSessionModifiedAt {
            return "来自最新 session：\(file) · \(date.formatted(date: .omitted, time: .shortened))"
        }
        return "来自最新 session：\(file)"
    }

    private var quotaUpdateDetail: String {
        guard let date = codex?.usage.quotaUpdatedAt else {
            return "首次刷新后会优先尝试 Codex WHAM 额度接口。"
        }
        return "更新于 \(date.formatted(date: .omitted, time: .standard))。"
    }

    private var quotaErrorDetail: String? {
        guard let error = codex?.usage.quotaLastError, !error.isEmpty else { return nil }
        if let date = codex?.usage.quotaLastErrorAt {
            return "WHAM 刷新失败：\(error) · \(date.formatted(date: .omitted, time: .shortened))"
        }
        return "WHAM 刷新失败：\(error)"
    }

    private var lowQuotaDetail: String? {
        guard codex?.usage.quotaDataSource == "Codex WHAM 实时接口" else { return nil }
        let fiveHour = codex?.usage.quota5hRemainingPercent
        let week = codex?.usage.quotaWeekRemainingPercent
        if let fiveHour, fiveHour <= 20 {
            return "5 小时额度 ≤20%，建议等重置后再进行大任务。"
        }
        if let week, week <= 20 {
            return "本周额度 ≤20%，建议保留给必要任务。"
        }
        return nil
    }

    private func quotaResetDetail(_ resetAt: Date?, windowSeconds: Int?, includesDate: Bool = false) -> String? {
        guard let resetAt else { return nil }
        let resetText = includesDate
            ? resetAt.formatted(.dateTime.month(.defaultDigits).day().weekday(.wide).hour().minute())
            : resetAt.formatted(date: .omitted, time: .shortened)
        if let windowSeconds {
            return "\(windowTitle(seconds: windowSeconds))窗口 · 重置于 \(resetText)"
        }
        return "重置于 \(resetText)"
    }

    private func windowTitle(seconds: Int) -> String {
        if seconds >= 86_400 {
            return "\(seconds / 86_400) 天"
        }
        if seconds >= 3_600 {
            return "\(seconds / 3_600) 小时"
        }
        return "\(seconds / 60) 分钟"
    }

}

private struct ConnectionsPage: View {
    @ObservedObject var store: AgentPulseStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var message: String?
    @State private var sessionSummaries: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ConnectionCard(
                title: "Codex",
                status: store.settings.codexMonitoringEnabled ? "自动监控已开启" : "已关闭",
                detail: "读取 ~/.codex/sessions 最近 7 天的本地会话日志。",
                good: store.settings.codexMonitoringEnabled,
                actions: {
                    Button("打开目录") { NSWorkspace.shared.open(store.codexSessionRoot) }
                    Button("刷新") { store.refresh() }
                }
            )

            GlassPanel(title: "诊断") {
                VStack(spacing: 8) {
                    ForEach(store.healthChecks()) { item in
                        HealthCheckRow(item: item)
                    }
                }
                Divider()
                    .opacity(0.45)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("最近活跃 session")
                            .font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Button("刷新") { reloadSessions() }
                    }
                    if sessionSummaries.isEmpty {
                        EmptyState(text: "还没有找到最近的 Codex session。")
                    } else {
                        ForEach(sessionSummaries, id: \.self) { session in
                            Text(session)
                                .font(.caption)
                                .foregroundStyle(store.settings.secondaryText(system: colorScheme))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                Divider()
                    .opacity(0.45)
                PathRow(title: "状态文件", url: store.stateFileURL)
                PathRow(title: "设置文件", url: store.settingsFileURL)
                PathRow(title: "Codex 日志", url: store.codexSessionRoot)
                HStack {
                    Button("复制诊断摘要") { copyDiagnostics() }
                    Button("打开 Application Support") { NSWorkspace.shared.open(AppStoragePaths().root) }
                    Button("重扫用量") { store.resetUsageCache() }
                    Button("导出诊断") { exportDiagnostics() }
                    Spacer()
                }
            }
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(message.contains("失败") ? store.settings.errorText(system: colorScheme) : store.settings.secondaryText(system: colorScheme))
            }
        }
        .onAppear {
            reloadSessions()
        }
    }

    private func run(_ success: String, action: () throws -> Void) {
        do {
            try action()
            message = success
        } catch {
            message = "操作失败：\(error.localizedDescription)"
        }
    }

    private func copyDiagnostics() {
        copy(store.diagnosticSummary())
        message = "诊断摘要已复制"
    }

    private func reloadSessions() {
        store.loadRecentCodexSessionSummaries(limit: 5) { summaries in
            sessionSummaries = summaries
        }
    }

    private func exportDiagnostics() {
        let paths = AppStoragePaths()
        do {
            try FileManager.default.createDirectory(at: paths.logs, withIntermediateDirectories: true)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let url = paths.logs.appendingPathComponent("diagnostics-\(formatter.string(from: Date())).txt")
            try store.diagnosticSummary().write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            message = "诊断已导出"
        } catch {
            message = "导出失败：\(error.localizedDescription)"
        }
    }
}

private struct PreferencesPage: View {
    @ObservedObject var store: AgentPulseStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var loginItemStatusText = "系统登录项：待检测"
    @State private var loginItemLastStatus: String?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            GlassPanel(title: "显示") {
                Picker("外观", selection: binding(\.theme)) {
                    ForEach(AgentPulseSettings.Theme.allCases) { theme in
                        Text(theme.title).tag(theme)
                    }
                }
                .pickerStyle(.segmented)
                HStack {
                    Toggle("显示悬浮胶囊", isOn: binding(\.showFloatingWindow))
                    Spacer()
                    Button("显示并重置") {
                        var copy = store.settings
                        copy.showFloatingWindow = true
                        store.updateSettings(copy)
                        NotificationCenter.default.post(name: Notification.Name("AgentPulseResetFloatingWindow"), object: nil)
                    }
                }
                Toggle("显示菜单栏图标", isOn: binding(\.showStatusBarIcon))
                Toggle("隐藏金额", isOn: binding(\.privacyMode))
                Toggle("玻璃效果", isOn: binding(\.glassEnabled))
                Picker("玻璃强度", selection: binding(\.glassIntensity)) {
                    ForEach(AgentPulseSettings.GlassIntensity.allCases) { value in
                        Text(value.title).tag(value)
                    }
                }
            }
            GlassPanel(title: "行为") {
                Toggle("暂停监控", isOn: binding(\.monitoringPaused))
                HStack {
                    Toggle("完成提示音", isOn: binding(\.doneSoundEnabled))
                    Spacer()
                    Button("试听") { playPreview(.done) }
                        .disabled(!store.settings.doneSoundEnabled)
                }
                HStack {
                    Toggle("需处理提示音", isOn: binding(\.attentionSoundEnabled))
                    Spacer()
                    Button("试听") { playPreview(.attention) }
                        .disabled(!store.settings.attentionSoundEnabled)
                }
                Picker("提示音音量", selection: binding(\.soundVolume)) {
                    ForEach(AgentPulseSettings.SoundVolume.allCases) { volume in
                        Text(volume.title).tag(volume)
                    }
                }
                .pickerStyle(.segmented)
                Toggle("开机自启动", isOn: binding(\.launchAtLogin))
                Text(loginItemStatusText)
                    .font(.caption)
                    .foregroundStyle(store.settings.secondaryText(system: colorScheme))
                if let loginItemLastStatus {
                    Text(loginItemLastStatus)
                        .font(.caption)
                        .foregroundStyle(store.settings.secondaryText(system: colorScheme))
                }
                Picker("完成态保持", selection: binding(\.doneHoldSeconds)) {
                    Text("15 秒").tag(15)
                    Text("30 秒").tag(30)
                    Text("60 秒").tag(60)
                }
            }
        }
        .onAppear {
            Task.detached {
                let status = Self.loginItemStatusSnapshot()
                await MainActor.run {
                    loginItemStatusText = status.text
                    loginItemLastStatus = status.lastStatus
                }
            }
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<AgentPulseSettings, Value>) -> Binding<Value> {
        Binding {
            store.settings[keyPath: keyPath]
        } set: { value in
            var copy = store.settings
            copy[keyPath: keyPath] = value
            store.updateSettings(copy)
        }
    }

    nonisolated private static func loginItemStatusSnapshot() -> (text: String, lastStatus: String?) {
        guard #available(macOS 13.0, *) else {
            return (
                "当前系统不支持自动同步登录项。",
                UserDefaults.standard.string(forKey: "loginItem.lastStatus")
            )
        }
        let text = switch SMAppService.mainApp.status {
        case .enabled:
            "系统登录项：已启用"
        case .requiresApproval:
            "系统登录项：需要在系统设置中批准"
        case .notRegistered:
            "系统登录项：未注册"
        case .notFound:
            "系统登录项：当前调试构建不可用"
        @unknown default:
            "系统登录项：未知状态"
        }
        return (text, UserDefaults.standard.string(forKey: "loginItem.lastStatus"))
    }

    private enum PreviewSound {
        case done
        case attention
    }

    private func playPreview(_ sound: PreviewSound) {
        let names: [String]
        switch sound {
        case .done:
            names = ["Glass", "Hero", "Ping"]
        case .attention:
            names = ["Basso", "Funk", "Sosumi"]
        }
        SettingsSoundPreviewPlayer.play(names: names, volume: store.settings.soundVolume)
    }
}

@MainActor
private enum SettingsSoundPreviewPlayer {
    private static var activeSounds: [NSSound] = []

    static func play(names: [String], volume: AgentPulseSettings.SoundVolume) {
        guard let sound = names.compactMap({ NSSound(named: NSSound.Name($0)) }).first else {
            NSSound.beep()
            return
        }
        sound.volume = volume.level
        activeSounds.append(sound)
        sound.play()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            activeSounds.removeAll { $0 === sound }
        }
    }
}

private struct AboutPage: View {
    @Environment(\.agentPulseSettings) private var settings
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 30)
            Image(systemName: "waveform.path.ecg.rectangle")
                .font(.system(size: 60, weight: .semibold))
                .foregroundStyle(AgentPulseColors.token)
            Text("AgentPulse")
                .font(.largeTitle.weight(.bold))
            Text("版本 1.0.0 · Codex usage center")
                .foregroundStyle(settings.secondaryText(system: colorScheme))
            HStack {
                Button("打开配置目录") {
                    NSWorkspace.shared.open(AppStoragePaths().root)
                }
                Button("复制版本信息") {
                    copy("AgentPulse 1.0.0\nConfig: \(AppStoragePaths().root.path)")
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

private struct SidebarButton: View {
    @Environment(\.agentPulseSettings) private var settings
    @Environment(\.colorScheme) private var colorScheme
    let page: SettingsPage
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: page.icon)
                    .frame(width: 18)
                Text(page.title)
                Spacer()
            }
            .font(.system(size: 14, weight: selected ? .semibold : .regular))
            .foregroundStyle(selected ? settings.primaryText(system: colorScheme) : settings.secondaryText(system: colorScheme))
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(selected ? settings.panelFill(system: colorScheme).opacity(settings.isDarkMode(system: colorScheme) ? 1.0 : 0.72) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(selected ? Color.white.opacity(0.72) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct HeroStatusCard: View {
    @ObservedObject var store: AgentPulseStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GlassPanel(title: "当前状态") {
            HStack(spacing: 14) {
                Circle()
                    .fill(primarySignal.pulseColor)
                    .frame(width: 34, height: 34)
                    .shadow(color: primarySignal.pulseColor.opacity(0.45), radius: 10)
                VStack(alignment: .leading, spacing: 4) {
                    Text(primarySignal.title)
                        .font(.title3.weight(.semibold))
                    Text(store.settings.monitoringPaused ? "监控已暂停" : "正在监听本地 Agent 活动")
                        .foregroundStyle(store.settings.secondaryText(system: colorScheme))
                }
                Spacer()
            }
        }
    }

    private var primarySignal: AgentSignal {
        store.visibleAgents.map(\.signal).max() ?? .idle
    }
}

private struct QuickActionsCard: View {
    @ObservedObject var store: AgentPulseStore

    var body: some View {
        GlassPanel(title: "快捷操作") {
            HStack {
                Button("显示胶囊") {
                    var copy = store.settings
                    copy.showFloatingWindow = true
                    store.updateSettings(copy)
                    NotificationCenter.default.post(name: Notification.Name("AgentPulseResetFloatingWindow"), object: nil)
                }
                Button("打开日志") { NSWorkspace.shared.open(store.codexSessionRoot) }
                Button("复制诊断") {
                    copy("State: \(store.stateFileURL.path)\nCodex: \(store.codexSessionRoot.path)")
                }
            }
        }
    }
}

private struct AgentCard: View {
    @Environment(\.agentPulseSettings) private var settings
    @Environment(\.colorScheme) private var colorScheme
    let agent: AgentSnapshot

    var body: some View {
        GlassPanel(title: agent.kind.displayName) {
            HStack(spacing: 12) {
                Circle().fill(agent.signal.pulseColor).frame(width: 16, height: 16)
                VStack(alignment: .leading, spacing: 4) {
                    Text(agent.signal.title).font(.headline)
                    Text(agent.currentCommand ?? "Agent 空闲")
                        .foregroundStyle(settings.secondaryText(system: colorScheme))
                        .lineLimit(2)
                    Text("更新于 \(agent.updatedAt.formatted(date: .omitted, time: .standard))")
                        .font(.caption)
                        .foregroundStyle(settings.tertiaryText(system: colorScheme))
                }
                Spacer()
                Text("本地")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(settings.isDarkMode(system: colorScheme) ? Color.white.opacity(0.08) : Color.black.opacity(0.06), in: Capsule())
            }
        }
    }
}

private struct AgentToggleCard<Actions: View>: View {
    @Environment(\.agentPulseSettings) private var settings
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let subtitle: String
    @Binding var enabled: Bool
    let installed: Bool
    @ViewBuilder let actions: Actions

    var body: some View {
        GlassPanel(title: title) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(subtitle)
                        .foregroundStyle(settings.secondaryText(system: colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        StatusPill(title: enabled ? "监控开启" : "监控关闭", good: enabled)
                        StatusPill(title: installed ? "可用" : "未配置", good: installed)
                    }
                }
                Spacer()
                Toggle("", isOn: $enabled)
                    .labelsHidden()
            }
            HStack { actions }
        }
    }
}

private struct RecentEventsCard: View {
    let events: [AgentEvent]

    var body: some View {
        GlassPanel(title: "最近事件") {
            VStack(spacing: 8) {
                ForEach(events) { event in
                    EventRow(event: event)
                }
                if events.isEmpty {
                    EmptyState(text: "暂无事件。运行一次 Codex 任务后，这里会出现状态变化。")
                }
            }
        }
    }
}

private struct EventRow: View {
    @Environment(\.agentPulseSettings) private var settings
    @Environment(\.colorScheme) private var colorScheme
    let event: AgentEvent

    var body: some View {
        HStack(spacing: 9) {
            Circle().fill(event.signal.pulseColor).frame(width: 8, height: 8)
            Text(event.kind.displayName)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 58, alignment: .leading)
            Text(event.message)
                .lineLimit(1)
            Spacer()
            Text(AgentPulseFormatters.relativeDate(event.date))
                .foregroundStyle(settings.tertiaryText(system: colorScheme))
        }
        .font(.system(size: 13))
        .padding(.vertical, 3)
    }
}

private struct MetricTile: View {
    @Environment(\.agentPulseSettings) private var settings
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(settings.secondaryText(system: colorScheme))
            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
            RoundedRectangle(cornerRadius: 2)
                .fill(tint.opacity(0.75))
                .frame(height: 4)
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(settings.primaryText(system: colorScheme))
        .background(settings.panelFill(system: colorScheme), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(settings.panelStrokeOpacity(system: colorScheme)), lineWidth: 1))
        .shadow(color: .black.opacity(settings.panelShadowOpacity(system: colorScheme)), radius: 12, y: 6)
    }
}

private struct UsageHealthCard: View {
    @Environment(\.agentPulseSettings) private var settings
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let detail: String
    let tint: Color

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.14))
                    .frame(width: 34, height: 34)
                Circle()
                    .fill(tint)
                    .frame(width: 10, height: 10)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(settings.secondaryText(system: colorScheme))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(settings.primaryText(system: colorScheme))
        .background(settings.panelFill(system: colorScheme), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(settings.panelStrokeOpacity(system: colorScheme)), lineWidth: 1))
    }
}

private struct GlassPanel<Content: View>: View {
    @Environment(\.agentPulseSettings) private var settings
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            content
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(settings.primaryText(system: colorScheme))
        .background(settings.panelFill(system: colorScheme), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(settings.panelStrokeOpacity(system: colorScheme)), lineWidth: 1))
        .shadow(color: .black.opacity(settings.panelShadowOpacity(system: colorScheme)), radius: 14, y: 7)
    }
}

private struct UsageBarChart: View {
    let values: [Int]
    let labels: [String]
    let tint: Color
    @State private var hoveredIndex: Int?

    var body: some View {
        ZStack(alignment: .topLeading) {
            GeometryReader { geometry in
                let maxValue = max(values.max() ?? 1, 1)
                HStack(alignment: .bottom, spacing: 8) {
                    ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(barFill(index: index))
                            .frame(
                                width: 9,
                                height: max(7, geometry.size.height * CGFloat(value) / CGFloat(maxValue))
                            )
                            .contentShape(Rectangle().inset(by: -5))
                            .onHover { inside in
                                hoveredIndex = inside ? index : (hoveredIndex == index ? nil : hoveredIndex)
                            }
                            .help(helpText(index: index, value: value))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
            if let hoveredIndex, values.indices.contains(hoveredIndex) {
                ChartHoverBubble(
                    title: labels.indices.contains(hoveredIndex) ? labels[hoveredIndex] : "第 \(hoveredIndex + 1) 天",
                    value: AgentPulseFormatters.tokens(values[hoveredIndex])
                )
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topLeading)))
                .animation(.easeOut(duration: 0.12), value: hoveredIndex)
            }
        }
        .frame(height: 150)
        .padding(.vertical, 4)
        .drawingGroup()
    }

    private func barFill(index: Int) -> LinearGradient {
        let emphasis = hoveredIndex == index || index > values.count - 8
        return LinearGradient(
            colors: [
                tint.opacity(emphasis ? 0.48 : 0.22),
                tint.opacity(emphasis ? 1.00 : 0.55)
            ],
            startPoint: .bottom,
            endPoint: .top
        )
    }

    private func helpText(index: Int, value: Int) -> String {
        let label = labels.indices.contains(index) ? labels[index] : "第 \(index + 1) 天"
        return "\(label) · \(AgentPulseFormatters.tokens(value))"
    }
}

private struct ChartHoverBubble: View {
    @Environment(\.agentPulseSettings) private var settings
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(settings.secondaryText(system: colorScheme))
            Text(value)
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
        }
        .foregroundStyle(settings.primaryText(system: colorScheme))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.7), lineWidth: 1))
    }
}

private struct ConnectionCard<Actions: View>: View {
    @Environment(\.agentPulseSettings) private var settings
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let status: String
    let detail: String
    let good: Bool
    @ViewBuilder let actions: Actions

    var body: some View {
        GlassPanel(title: title) {
            StatusPill(title: status, good: good)
            Text(detail)
                .font(.system(size: 13))
                .foregroundStyle(settings.secondaryText(system: colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            HStack { actions }
        }
    }
}

private struct StatusPill: View {
    @Environment(\.agentPulseSettings) private var settings
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let good: Bool

    var body: some View {
        let tint = good ? AgentPulseColors.working : AgentPulseColors.thinking
        Text(title)
            .font(.caption)
            .foregroundStyle(tint.opacity(settings.isDarkMode(system: colorScheme) ? 0.90 : 0.85))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(tint.opacity(0.12), in: Capsule())
            .overlay(Capsule().stroke(tint.opacity(0.18), lineWidth: 1))
    }
}

private struct QuotaLine: View {
    @Environment(\.agentPulseSettings) private var settings
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let value: Int
    var detail: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 76, alignment: .leading)
                Spacer()
                Text("\(value)%")
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                    .foregroundStyle(accent)
                    .frame(width: 42, alignment: .trailing)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(settings.dividerColor(system: colorScheme))
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [accent.opacity(0.55), accent],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: barWidth(totalWidth: geometry.size.width))
                }
            }
            .frame(height: 8)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(settings.secondaryText(system: colorScheme))
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }

    private var accent: Color {
        if value <= 20 { return AgentPulseColors.attention }
        if value <= 50 { return AgentPulseColors.thinking }
        return AgentPulseColors.working
    }

    private func barWidth(totalWidth: CGFloat) -> CGFloat {
        guard value > 0 else { return 0 }
        return max(8, totalWidth * CGFloat(min(max(value, 0), 100)) / 100)
    }
}

private struct SourceRow: View {
    @Environment(\.agentPulseSettings) private var settings
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let value: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 48, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(value)
                    .font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(settings.secondaryText(system: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
        }
    }
}

private struct StatusNote: View {
    @Environment(\.agentPulseSettings) private var settings
    @Environment(\.colorScheme) private var colorScheme
    enum Tone {
        case warning
    }

    let text: String
    let tone: Tone

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(color)
                .padding(.top, 1)
            Text(text)
                .font(.caption)
                .foregroundStyle(settings.errorText(system: colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(color.opacity(0.22), lineWidth: 1))
    }

    private var color: Color {
        switch tone {
        case .warning: AgentPulseColors.attention
        }
    }
}

private struct HealthCheckRow: View {
    @Environment(\.agentPulseSettings) private var settings
    @Environment(\.colorScheme) private var colorScheme
    let item: AgentPulseHealthCheck

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(color)
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(item.title)
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text(item.status.title)
                        .font(.caption)
                        .foregroundStyle(color)
                }
                Text(item.detail)
                    .font(.caption)
                    .foregroundStyle(settings.secondaryText(system: colorScheme))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 2)
    }

    private var color: Color {
        switch item.status {
        case .ok: AgentPulseColors.working
        case .warning: AgentPulseColors.thinking
        }
    }
}

private struct ModelUsageRow: View {
    @Environment(\.agentPulseSettings) private var settings
    @Environment(\.colorScheme) private var colorScheme
    let item: UsageSnapshot.ModelTokenUsage
    let total: Int
    let privacy: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(item.model)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text("\(percent)%")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(AgentPulseColors.token)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(settings.dividerColor(system: colorScheme))
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [AgentPulseColors.token.opacity(0.55), AgentPulseColors.token],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(8, geometry.size.width * CGFloat(percent) / 100))
                }
            }
            .frame(height: 7)
            HStack {
                Text(AgentPulseFormatters.tokens(item.tokens))
                Spacer()
                Text(AgentPulseFormatters.money(item.cost, privacy: privacy))
            }
            .font(.caption)
            .foregroundStyle(settings.secondaryText(system: colorScheme))
            Text("Input \(AgentPulseFormatters.tokens(item.inputTokens)) · Cached \(AgentPulseFormatters.tokens(item.cachedInputTokens)) · Output \(AgentPulseFormatters.tokens(item.outputTokens))")
                .font(.caption2)
                .foregroundStyle(settings.tertiaryText(system: colorScheme))
                .lineLimit(1)
        }
        .padding(.vertical, 4)
    }

    private var percent: Int {
        Int((Double(item.tokens) / Double(max(total, 1)) * 100).rounded())
    }
}

private struct TokenBreakdownRow: View {
    @Environment(\.agentPulseSettings) private var settings
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let value: Int
    let total: Int
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Text("\(AgentPulseFormatters.tokens(value)) · \(percent)%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(settings.secondaryText(system: colorScheme))
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(settings.dividerColor(system: colorScheme))
                    Capsule()
                        .fill(tint.opacity(0.8))
                        .frame(width: max(value == 0 ? 0 : 7, geometry.size.width * CGFloat(percent) / 100))
                }
            }
            .frame(height: 7)
        }
        .padding(.vertical, 3)
    }

    private var percent: Int {
        guard total > 0 else { return 0 }
        return Int((Double(value) / Double(total) * 100).rounded())
    }
}

private struct ToolRow: View {
    let title: String
    let count: Int

    init(_ title: String, _ count: Int) {
        self.title = title
        self.count = count
    }

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text("\(count)").monospacedDigit()
        }
    }
}

private struct PathRow: View {
    @Environment(\.agentPulseSettings) private var settings
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let url: URL

    var body: some View {
        HStack {
            Text(title).frame(width: 86, alignment: .leading)
            Text(url.path)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(settings.secondaryText(system: colorScheme))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button("复制") { copy(url.path) }
        }
    }
}

private struct EmptyState: View {
    @Environment(\.agentPulseSettings) private var settings
    @Environment(\.colorScheme) private var colorScheme
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(settings.secondaryText(system: colorScheme))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(13)
            .background(settings.isDarkMode(system: colorScheme) ? Color.white.opacity(0.06) : Color.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }
}

private func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}
