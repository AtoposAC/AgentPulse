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
                    Text("本地监控")
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
                Text("本地构建 / 未公证")
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
        case .dashboard: AppStrings.Pages.overview
        case .agents: AppStrings.Pages.agents
        case .usage: AppStrings.Pages.usageCenter
        case .connections: AppStrings.Pages.connection
        case .preferences: AppStrings.Pages.settings
        case .about: AppStrings.Pages.about
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
    @State private var message: String?
    @State private var recentClaudeHookEvents: [ClaudeHookEvent] = []
    @State private var activityFilter: AgentActivityFilter = .all

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            AgentToggleCard(
                title: "Codex",
                subtitle: "免 Hook 读取本地会话日志，适合 Desktop / CLI 场景。",
                enabled: binding(\.codexMonitoringEnabled),
                installed: true,
                actions: {
                    Button("打开日志目录") { NSWorkspace.shared.open(store.codexSessionRoot) }
                    Button("刷新状态") { store.refresh() }
                    Button("诊断事件") { copyCodexHint() }
                }
            )
            AgentMonitoringStatusView(status: codexMonitoringStatus)

            AgentToggleCard(
                title: "Claude",
                subtitle: "通过 Claude Code Hooks 监听状态事件；当前仅监测状态，不统计 Token / Cost。",
                enabled: binding(\.claudeMonitoringEnabled),
                installed: claudeHookInstalled,
                actions: {
                    Button(claudeHookInstalled ? "重装 Hook" : "安装 Hook") { installClaudeHook() }
                    Button("测试 Hook") { testClaudeHook() }
                    Button("卸载 Hook") { uninstallClaudeHook() }
                    Button("打开 Hook 日志") { NSWorkspace.shared.open(store.claudeHookLogURL.deletingLastPathComponent()) }
                }
            )
            AgentMonitoringStatusView(status: claudeMonitoringStatus)
            Text("Claude Hook 会写入 \(store.claudeHookLogURL.path)")
                .font(.caption)
                .foregroundStyle(store.settings.secondaryText(system: colorScheme))
                .lineLimit(1)
                .truncationMode(.middle)
            if !claudeHookInstalled, claudeHookStatus.settingsExists {
                Text("检测到 Claude 配置，但 AgentPulse Hook 脚本不可用；点击安装 Hook 可修复。")
                    .font(.caption)
                    .foregroundStyle(store.settings.secondaryText(system: colorScheme))
            }
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(message.contains("失败") ? store.settings.errorText(system: colorScheme) : store.settings.secondaryText(system: colorScheme))
            }
            if !recentClaudeHookEvents.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("最近 Claude Hook 事件")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(store.settings.secondaryText(system: colorScheme))
                    ForEach(recentClaudeHookEvents.prefix(3), id: \.date) { event in
                        HStack {
                            Text(event.displayTitle)
                                .font(.caption)
                                .lineLimit(1)
                                .help(event.type)
                            Spacer()
                            Text(event.date.formatted(date: .omitted, time: .shortened))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(store.settings.tertiaryText(system: colorScheme))
                        }
                    }
                }
            } else if store.settings.claudeMonitoringEnabled, claudeHookInstalled {
                Text("Hook 已就绪，等待 Claude Code 产生可追踪事件。")
                    .font(.caption)
                    .foregroundStyle(store.settings.secondaryText(system: colorScheme))
            }
            AgentActivityTimeline(
                events: activityEvents,
                filter: $activityFilter,
                claudeMonitoringEnabled: store.settings.claudeMonitoringEnabled,
                claudeHookInstalled: claudeHookInstalled
            )
        }
        .onAppear {
            refreshRecentClaudeHookEvents()
        }
    }

    private var claudeHookInstalled: Bool {
        claudeHookStatus.hookInstalled
    }

    private var claudeHookStatus: HookManager.ClaudeHookStatus {
        HookManager.diagnoseClaudeHook()
    }

    private var activityEvents: [AgentEvent] {
        store.agents
            .flatMap(\.recentEvents)
            .filter { activityFilter.matches($0.kind) }
            .sorted { $0.date > $1.date }
            .prefix(12)
            .map { $0 }
    }

    private var codexMonitoringStatus: AgentMonitoringStatus {
        guard store.settings.codexMonitoringEnabled else {
            return AgentMonitoringStatus(
                title: "Codex 监测已关闭",
                detail: "开启后会读取 ~/.codex/sessions 中最近 7 天的本地会话日志。",
                isHealthy: false
            )
        }

        guard let codex = store.agents.first(where: { $0.kind == .codex }),
              let path = codex.usage.latestSessionPath else {
            return AgentMonitoringStatus(
                title: "尚未检测到 Codex 会话",
                detail: "完成一次 Codex 对话或任务后，AgentPulse 会在下一次扫描时显示活动和用量。",
                isHealthy: false
            )
        }

        var details = ["最新会话：\(URL(fileURLWithPath: path).lastPathComponent)"]
        if let modifiedAt = codex.usage.latestSessionModifiedAt {
            details.append("最新写入：\(statusDate(modifiedAt))")
        }
        if let scannedAt = codex.usage.usageScannedAt {
            details.append("上次扫描：\(statusDate(scannedAt))")
        } else {
            details.append("用量扫描：等待首次完成")
        }
        details.append("已索引 \(codex.usage.scannedFileCount ?? 0) 个会话文件")

        return AgentMonitoringStatus(
            title: "本地会话已检测",
            detail: "AgentPulse 正在读取 Codex 本地会话日志。",
            isHealthy: true,
            details: details
        )
    }

    private var claudeMonitoringStatus: AgentMonitoringStatus {
        let status = claudeHookStatus
        guard store.settings.claudeMonitoringEnabled else {
            return AgentMonitoringStatus(
                title: "Claude 监测已关闭",
                detail: "开启监测并安装 Hook 后，AgentPulse 会显示 Claude 的状态与工具事件。",
                isHealthy: false
            )
        }
        guard status.hookInstalled else {
            let detail = status.settingsExists
                ? "检测到 Claude 配置，但 AgentPulse Hook 脚本不可用；点击安装 Hook 可修复。"
                : "安装 Hook 后，Claude Code 的状态与工具事件会写入本地日志。"
            return AgentMonitoringStatus(
                title: status.settingsExists ? "Claude Hook 需要修复" : "Claude Hook 尚未安装",
                detail: detail,
                isHealthy: false
            )
        }
        guard status.logWritable else {
            return AgentMonitoringStatus(
                title: "Claude Hook 日志不可写",
                detail: "请检查 Application Support 目录权限，然后重新安装 Hook。",
                isHealthy: false
            )
        }

        var details = ["Hook 脚本：可执行", "事件日志：可写"]
        if let eventAt = status.latestEventAt {
            details.append("最近事件：\(statusDate(eventAt))")
        } else {
            details.append("最近事件：尚未收到")
        }
        return AgentMonitoringStatus(
            title: status.latestEventAt == nil ? "Claude Hook 已就绪，等待活动" : "Claude Hook 正在接收事件",
            detail: "Claude 当前只提供状态和工具事件，不统计 Token / Cost。",
            isHealthy: true,
            details: details
        )
    }

    private func statusDate(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
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

    private func installClaudeHook() {
        do {
            try store.installClaudeHook()
            message = "Claude Hook 已安装并启用监控。"
            refreshRecentClaudeHookEvents()
        } catch {
            message = "安装 Claude Hook 失败：\(error.localizedDescription)"
        }
    }

    private func uninstallClaudeHook() {
        do {
            try store.uninstallClaudeHook()
            message = "Claude Hook 已卸载。"
            refreshRecentClaudeHookEvents()
        } catch {
            message = "卸载 Claude Hook 失败：\(error.localizedDescription)"
        }
    }

    private func testClaudeHook() {
        do {
            try HookManager.writeTestClaudeHookEvent()
            message = "已写入 Claude Hook 测试事件。"
            refreshRecentClaudeHookEvents()
            store.refresh()
        } catch {
            message = "写入 Claude Hook 测试事件失败：\(error.localizedDescription)"
        }
    }

    private func refreshRecentClaudeHookEvents() {
        recentClaudeHookEvents = HookManager.recentClaudeHookEvents(limit: 3)
    }
}

private struct AgentMonitoringStatus {
    let title: String
    let detail: String
    let isHealthy: Bool
    var details: [String] = []
}

private struct AgentMonitoringStatusView: View {
    @Environment(\.agentPulseSettings) private var settings
    @Environment(\.colorScheme) private var colorScheme
    let status: AgentMonitoringStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Circle()
                    .fill(status.isHealthy ? AgentPulseColors.working : settings.secondaryText(system: colorScheme))
                    .frame(width: 7, height: 7)
                Text(status.title)
                    .font(.caption.weight(.medium))
            }
            Text(status.detail)
                .font(.caption)
                .foregroundStyle(settings.secondaryText(system: colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            ForEach(status.details, id: \.self) { detail in
                Text(detail)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(settings.tertiaryText(system: colorScheme))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 4)
    }
}

private enum AgentActivityFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case codex = "Codex"
    case claude = "Claude"

    var id: String { rawValue }

    func matches(_ kind: AgentKind) -> Bool {
        switch self {
        case .all: true
        case .codex: kind == .codex
        case .claude: kind == .claude
        }
    }
}

private struct AgentActivityTimeline: View {
    @Environment(\.agentPulseSettings) private var settings
    @Environment(\.colorScheme) private var colorScheme
    let events: [AgentEvent]
    @Binding var filter: AgentActivityFilter
    let claudeMonitoringEnabled: Bool
    let claudeHookInstalled: Bool

    var body: some View {
        GlassPanel(title: "最近活动") {
            Picker("活动来源", selection: $filter) {
                ForEach(AgentActivityFilter.allCases) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 300)

            Text("Codex 显示状态变化；Claude 显示 Hook 事件。Codex 工作段请在用量中心的 Agent 日志中查看。")
                .font(.caption)
                .foregroundStyle(settings.secondaryText(system: colorScheme))
                .fixedSize(horizontal: false, vertical: true)

            if events.isEmpty {
                EmptyState(text: emptyText)
            } else {
                ForEach(events) { event in
                    activityRow(event)
                    if event.id != events.last?.id {
                        Divider().opacity(0.35)
                    }
                }
            }
        }
    }

    private var emptyText: String {
        switch filter {
        case .codex:
            "尚未记录 Codex 状态变化。运行一次 Codex 任务后会显示在这里。"
        case .claude where !claudeMonitoringEnabled:
            "Claude 监测尚未启用。"
        case .claude where !claudeHookInstalled:
            "安装 Claude Hook 后会显示 Claude 活动。"
        default:
            "尚未记录可展示的 Agent 活动。"
        }
    }

    private func activityRow(_ event: AgentEvent) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Circle()
                .fill(event.signal.pulseColor)
                .frame(width: 8, height: 8)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(event.kind.displayName)
                        .font(.caption.weight(.semibold))
                    Text(event.kind == .codex ? "状态变化" : "Hook 事件")
                        .font(.caption)
                        .foregroundStyle(settings.tertiaryText(system: colorScheme))
                }
                Text(event.message)
                    .font(.system(size: 13))
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(AgentPulseFormatters.relativeDate(event.date))
                    .font(.caption.monospacedDigit())
                Text(event.date.formatted(date: .omitted, time: .shortened))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(settings.tertiaryText(system: colorScheme))
            }
        }
    }
}

private struct UsageForecastCard: View {
    @ObservedObject var store: AgentPulseStore
    @Environment(\.colorScheme) private var colorScheme

    private var codex: AgentSnapshot? { store.agents.first(where: { $0.kind == .codex }) }
    private var usage: UsageDomainModel { UsageDomainService.makeDomainModel(usage: codex?.usage) }

    var body: some View {
        GlassPanel(title: AppStrings.Sections.usageCenter) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                compactMetric("本月累计消耗", AgentPulseFormatters.money(usage.trend.monthCost, privacy: store.settings.privacyMode), AgentPulseColors.working)
                compactMetric("预计本月消耗", AgentPulseFormatters.money(usage.trend.projectedMonthCost, privacy: store.settings.privacyMode), AgentPulseColors.thinking)
                compactMetric("预计剩余额度", remainingQuotaText, quotaTint)
                compactMetric("平均每日 Token", AgentPulseFormatters.tokens(usage.trend.averageDailyTokens), AgentPulseColors.token)
                compactMetric(AppStrings.Metrics.averageDailyCost, AgentPulseFormatters.money(usage.trend.averageDailyCost, privacy: store.settings.privacyMode), AgentPulseColors.working)
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
        if let week = usage.quota.weekRemainingPercent {
            return "\(week)% 本周"
        }
        if let fiveHour = usage.quota.fiveHourRemainingPercent {
            return "\(fiveHour)% 5小时"
        }
        return "待确认"
    }

    private var quotaTint: Color {
        let value = usage.quota.weekRemainingPercent ?? usage.quota.fiveHourRemainingPercent ?? 0
        if value <= 20 { return AgentPulseColors.attention }
        if value <= 50 { return AgentPulseColors.thinking }
        return AgentPulseColors.working
    }
}

private enum UsageAgentFilter: String, CaseIterable, Identifiable {
    case codex = "Codex"
    case claude = "Claude"
    case all = "All"

    var id: String { rawValue }
}

private struct ClaudeUsageStatusCard: View {
    @Environment(\.agentPulseSettings) private var settings
    @Environment(\.colorScheme) private var colorScheme
    let agent: AgentSnapshot?
    let monitoringEnabled: Bool

    var body: some View {
        GlassPanel(title: "Claude") {
            HStack(spacing: 12) {
                Circle()
                    .fill((agent?.signal ?? .idle).pulseColor)
                    .frame(width: 14, height: 14)
                VStack(alignment: .leading, spacing: 3) {
                    Text(statusTitle)
                        .font(.system(size: 14, weight: .semibold))
                    Text(statusDetail)
                        .font(.caption)
                        .foregroundStyle(settings.secondaryText(system: colorScheme))
                        .lineLimit(2)
                }
                Spacer()
                StatusPill(title: agent?.hookInstalled == true ? "Hook 已安装" : "Hook 未安装", good: agent?.hookInstalled == true)
            }

            Divider().opacity(0.35)

            EmptyState(text: "Claude 暂未提供可用 token 数据")

            if let agent {
                HStack {
                    Text("工具事件")
                        .font(.caption)
                        .foregroundStyle(settings.secondaryText(system: colorScheme))
                    Spacer()
                    Text("\(agent.toolStats.total)")
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                }
                if agent.recentEvents.isEmpty {
                    EmptyState(text: "暂无 Claude Hook 活动。")
                } else {
                    ForEach(agent.recentEvents.prefix(4)) { event in
                        HStack {
                            Text(event.signal.title)
                                .font(.system(size: 12, weight: .medium))
                            Text(event.message)
                                .font(.caption)
                                .foregroundStyle(settings.secondaryText(system: colorScheme))
                                .lineLimit(1)
                            Spacer()
                            Text(event.date.formatted(date: .omitted, time: .shortened))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(settings.tertiaryText(system: colorScheme))
                        }
                    }
                }
            }
        }
    }

    private var statusTitle: String {
        if !monitoringEnabled { return "Claude 监控未启用" }
        return agent?.signal.title ?? "等待 Claude Hook 事件"
    }

    private var statusDetail: String {
        if !monitoringEnabled { return "在 Agent 页启用 Claude，并安装 Claude Code Hook。" }
        return agent?.currentCommand ?? "Claude 仅提供状态、工具事件和最近活动。"
    }
}

private struct UsagePage: View {
	    @ObservedObject var store: AgentPulseStore
	    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedAgent: UsageAgentFilter = .codex
	    var codex: AgentSnapshot? { store.agents.first(where: { $0.kind == .codex }) }
    var claude: AgentSnapshot? { store.agents.first(where: { $0.kind == .claude }) }
	    var usageCenter: UsageDomainModel { UsageDomainService.makeDomainModel(usage: codex?.usage) }
	
	    var body: some View {
	        VStack(alignment: .leading, spacing: 16) {
            Picker("Agent", selection: $selectedAgent) {
                ForEach(UsageAgentFilter.allCases) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 320)

            if selectedAgent == .all || selectedAgent == .claude {
                ClaudeUsageStatusCard(agent: claude, monitoringEnabled: store.settings.claudeMonitoringEnabled)
            }

            if selectedAgent == .all || selectedAgent == .codex {
	            UsageHealthCard(
	                title: usageHealthTitle,
	                detail: usageHealthDetail,
	                tint: usageHealthTint
	            )
            UsageStoryCard(
                todayTokens: usageCenter.today.tokens,
                currentModel: usageCenter.today.currentModel,
                totalCost: usageCenter.today.cost,
                totalToolCalls: usageCenter.tool.totalCalls,
                privacy: store.settings.privacyMode
            )
	            LazyVGrid(columns: metricColumns, spacing: 12) {
                MetricTile(title: AppStrings.Metrics.todayActiveTime, value: AgentPulseFormatters.duration(usageCenter.today.activeSeconds), tint: AgentPulseColors.working)
                MetricTile(title: AppStrings.Metrics.todayTokens, value: AgentPulseFormatters.tokens(usageCenter.today.tokens), tint: AgentPulseColors.token)
                MetricTile(title: AppStrings.Metrics.todayCost, value: AgentPulseFormatters.money(usageCenter.today.cost, privacy: store.settings.privacyMode), tint: AgentPulseColors.working)
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
                QuotaLine(title: "5 小时额度", value: usageCenter.quota.fiveHourRemainingPercent, detail: quotaResetDetail(usageCenter.quota.fiveHourResetAt, windowSeconds: usageCenter.quota.fiveHourWindowSeconds))
                QuotaLine(title: "本周额度", value: usageCenter.quota.weekRemainingPercent, detail: quotaResetDetail(usageCenter.quota.weekResetAt, windowSeconds: usageCenter.quota.weekWindowSeconds, includesDate: true))
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
            GlassPanel(title: AppStrings.Sections.tokenBreakdown) {
                if usageCenter.token.totalBreakdownTokens == 0 {
                    EmptyState(text: "暂未解析到 input / cached / output 明细。")
                } else {
                    TokenBreakdownRow(title: "输入", value: usageCenter.token.inputTokens, total: usageCenter.token.totalBreakdownTokens, tint: AgentPulseColors.thinking)
                    TokenBreakdownRow(title: "缓存输入", value: usageCenter.token.cachedInputTokens, total: usageCenter.token.totalBreakdownTokens, tint: AgentPulseColors.token)
                    TokenBreakdownRow(title: "输出", value: usageCenter.token.outputTokens, total: usageCenter.token.totalBreakdownTokens, tint: AgentPulseColors.working)
                }
            }
            GlassPanel(title: "Model Usage") {
                if usageCenter.model.items.isEmpty {
                    EmptyState(text: "暂无模型使用数据")
                } else {
                    ModelUsageInsight(model: usageCenter.model.topModel?.model)
                    ForEach(usageCenter.model.items) { item in
                        ModelUsageRow(item: item, total: usageCenter.model.totalTokens, privacy: store.settings.privacyMode)
                    }
                }
            }
            GlassPanel(title: "工具调用") {
                Text("总调用次数：\(usageCenter.tool.totalCalls)")
                    .font(.caption)
                    .foregroundStyle(store.settings.secondaryText(system: colorScheme))
                if usageCenter.tool.items.isEmpty {
                    EmptyState(text: "暂无工具调用数据")
                } else {
                    ForEach(usageCenter.tool.items) { item in
                        ToolUsageRow(item: item)
                    }
                }
            }
            AgentJournalCard(
                journal: usageCenter.journal,
                todayTokens: usageCenter.today.tokens,
                privacy: store.settings.privacyMode
            )
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
            GlassPanel(title: "最近 7 天趋势") {
                if usageCenter.trend.last7Days.allSatisfy({ $0.tokens == 0 }) {
                    EmptyState(text: "最近 7 天暂无 token 数据。")
                } else {
                    UsageBarChart(values: usageCenter.trend.last7Days.map(\.tokens), labels: usageCenter.trend.last7Days.map(\.date), tint: AgentPulseColors.working)
                    HStack {
                        Text(usageCenter.trend.last7Days.first?.date ?? "")
                        Spacer()
                        Text("按日 token 使用量")
                        Spacer()
                        Text(usageCenter.trend.last7Days.last?.date ?? "")
                    }
                    .font(.caption)
                    .foregroundStyle(store.settings.secondaryText(system: colorScheme))
                }
            }
            GlassPanel(title: "最近 30 天趋势") {
                if usageCenter.trend.last30Days.allSatisfy({ $0.tokens == 0 }) {
                    EmptyState(text: "暂无每日 token 数据。运行产生 usage 字段的 Codex 会话后，这里才会绘制柱状图。")
                } else {
                    UsageBarChart(values: usageCenter.trend.last30Days.map(\.tokens), labels: usageCenter.trend.last30Days.map(\.date), tint: AgentPulseColors.token)
                    HStack {
                        Text(usageCenter.trend.last30Days.first?.date ?? "")
                        Spacer()
                        Text("按日 token 使用量")
                        Spacer()
                        Text(usageCenter.trend.last30Days.last?.date ?? "")
                    }
                    .font(.caption)
                    .foregroundStyle(store.settings.secondaryText(system: colorScheme))
                }
            }
            }
        }
    }

    private var metricColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 150), spacing: 12)]
    }

    private var usageHealthTitle: String {
        if store.isRefreshingUsage { return "正在刷新本地用量" }
        if store.isRefreshingCodexState { return "正在读取最新 Codex 状态" }
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
        if store.isRefreshingUsage {
            if let scanDate = codex?.usage.usageScannedAt {
                return "先显示 " + scanDate.formatted(date: .omitted, time: .standard) + " 的本地数据，完成后自动更新。"
            }
            return "正在首次扫描本地 Codex 会话日志。"
        }
        if store.isRefreshingCodexState {
            return "先显示缓存数据；正在检查最近的 Codex 会话活动。"
        }
        if let scanDate = codex?.usage.usageScannedAt {
            return "今日 \(tokens) · 已索引 \(scanned) 个会话 · \(scanDate.formatted(date: .omitted, time: .standard)) 更新"
        }
        return "打开或继续一次 Codex 会话后，AgentPulse 会自动读取本地 usage 数据。"
    }

    private var usageHealthTint: Color {
        guard let latest = codex?.usage.latestSessionModifiedAt else { return AgentPulseColors.thinking }
        return Date().timeIntervalSince(latest) < 900 ? AgentPulseColors.working : AgentPulseColors.token
    }

    private var scannedFileDetail: String {
        let count = codex?.usage.scannedFileCount ?? 0
        if store.isRefreshingUsage {
            return "正在后台刷新；当前显示上次成功扫描的数据。"
        }
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

    private var quotaUpdateDetail: String {
        if store.isRefreshingCodexQuota {
            return "正在刷新 Codex WHAM；当前显示上次成功获取的额度数据。"
        }
        guard let date = usageCenter.quota.updatedAt else {
            return "首次刷新后会优先尝试 Codex WHAM 额度接口。"
        }
        return "更新于 \(date.formatted(date: .omitted, time: .standard))。"
    }

    private var quotaErrorDetail: String? {
        guard let error = usageCenter.quota.lastError, !error.isEmpty else { return nil }
        if let date = usageCenter.quota.lastErrorAt {
            return "WHAM 刷新失败：\(error) · \(date.formatted(date: .omitted, time: .shortened))"
        }
        return "WHAM 刷新失败：\(error)"
    }

    private var lowQuotaDetail: String? {
        guard usageCenter.quota.dataSource == "Codex WHAM 实时接口" else { return nil }
        let fiveHour = usageCenter.quota.fiveHourRemainingPercent
        let week = usageCenter.quota.weekRemainingPercent
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
    @State private var showResetUsageConfirmation = false

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
                    Button("重建用量缓存") { showResetUsageConfirmation = true }
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
        .confirmationDialog("重建用量缓存？", isPresented: $showResetUsageConfirmation) {
            Button("重建用量缓存", role: .destructive) {
                store.resetUsageCache()
                message = "已重建用量缓存"
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这会清空本地 usage cache 并重新扫描 Codex 会话日志。不会删除 Codex 日志。")
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
    @State private var updateStatus: String?
    @State private var checkingUpdate = false

    var body: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 30)
            Image(systemName: "waveform.path.ecg.rectangle")
                .font(.system(size: 60, weight: .semibold))
                .foregroundStyle(AgentPulseColors.token)
            Text("AgentPulse")
                .font(.largeTitle.weight(.bold))
            Text("版本 \(currentVersion) · Codex 用量中心")
                .foregroundStyle(settings.secondaryText(system: colorScheme))
            HStack {
                Button(checkingUpdate ? "检查中…" : "检查更新") {
                    checkForUpdates()
                }
                .disabled(checkingUpdate)
                Button("打开下载页面") {
                    AgentPulseUpdateChecker.openReleasesPage()
                }
                Button("项目主页") {
                    AgentPulseUpdateChecker.openProjectPage()
                }
            }
            if let updateStatus {
                Text(updateStatus)
                    .font(.caption)
                    .foregroundStyle(settings.secondaryText(system: colorScheme))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.4"
    }

    private func checkForUpdates() {
        checkingUpdate = true
        updateStatus = "正在检查 GitHub Release…"
        Task {
            do {
                let result = try await AgentPulseUpdateChecker.check(currentVersion: currentVersion)
                await MainActor.run {
                    checkingUpdate = false
                    updateStatus = result.message
                }
                if result.hasUpdate {
                    let downloadedAssetName = try await AgentPulseUpdateChecker.downloadAndOpenInstaller(from: result.release)
                    await MainActor.run {
                        updateStatus = """
                        已下载并打开安装包。
                        当前版本：\(currentVersion)
                        最新版本：\(result.release.displayVersion)
                        DMG：\(downloadedAssetName)
                        Release 页面：\(result.release.htmlURL.absoluteString)
                        请关闭 AgentPulse 后，将 DMG 中的新版本拖拽替换到 Applications。
                        """
                    }
                }
            } catch AgentPulseUpdateChecker.UpdateError.noDMGAsset(let url) {
                await MainActor.run {
                    checkingUpdate = false
                    updateStatus = "发现新版本，但 Release 没有 DMG 安装包。已打开下载页面。"
                    _ = NSWorkspace.shared.open(url)
                }
            } catch {
                await MainActor.run {
                    checkingUpdate = false
                    updateStatus = "检查更新失败：\(error.localizedDescription)"
                }
            }
        }
    }
}

private enum AgentPulseUpdateChecker {
    private static let latestReleaseURL = URL(string: "https://api.github.com/repos/AtoposAC/AgentPulse/releases/latest")!
    private static let releasesPageURL = URL(string: "https://github.com/AtoposAC/AgentPulse/releases")!
    private static let projectPageURL = URL(string: "https://github.com/AtoposAC/AgentPulse")!

    enum UpdateError: LocalizedError {
        case networkUnavailable
        case rateLimited
        case releaseNotFound
        case noDMGAsset(URL)
        case badServerResponse(Int)
        case invalidReleaseData

        var errorDescription: String? {
            switch self {
            case .networkUnavailable:
                "无法连接网络或 GitHub，请检查网络后重试。"
            case .rateLimited:
                "GitHub API 暂时限流，请稍后重试或打开下载页面。"
            case .releaseNotFound:
                "没有找到可用的 GitHub Release。"
            case .noDMGAsset:
                "最新 Release 没有 DMG 安装包。"
            case .badServerResponse(let status):
                "GitHub 返回异常状态码 \(status)。"
            case .invalidReleaseData:
                "GitHub Release 数据格式无法识别。"
            }
        }
    }

    struct Result {
        let hasUpdate: Bool
        let message: String
        let release: GitHubRelease
    }

    struct GitHubRelease: Decodable {
        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: URL

            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }

        let tagName: String
        let htmlURL: URL
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case assets
        }

        var displayVersion: String {
            tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        }

        var dmgAsset: Asset? {
            assets.first { $0.name.lowercased().hasSuffix(".dmg") }
        }
    }

    static func check(currentVersion: String) async throws -> Result {
        var request = URLRequest(url: latestReleaseURL)
        request.timeoutInterval = 12
        request.setValue("AgentPulse", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        } catch let error as URLError {
            throw classifiedNetworkError(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw UpdateError.invalidReleaseData
        }
        switch http.statusCode {
        case 200..<300:
            break
        case 403, 429:
            throw UpdateError.rateLimited
        case 404:
            throw UpdateError.releaseNotFound
        default:
            throw UpdateError.badServerResponse(http.statusCode)
        }
        let release: GitHubRelease
        do {
            release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        } catch {
            throw UpdateError.invalidReleaseData
        }
        let hasUpdate = compare(release.displayVersion, currentVersion) == .orderedDescending
        let assetName = release.dmgAsset?.name ?? "未找到 DMG"
        let message = hasUpdate
            ? """
            发现新版本，正在准备下载…
            当前版本：\(currentVersion)
            最新版本：\(release.displayVersion)
            DMG：\(assetName)
            Release 页面：\(release.htmlURL.absoluteString)
            """
            : """
            当前已是最新版本。
            当前版本：\(currentVersion)
            最新版本：\(release.displayVersion)
            Release 页面：\(release.htmlURL.absoluteString)
            """
        return Result(hasUpdate: hasUpdate, message: message, release: release)
    }

    static func downloadAndOpenInstaller(from release: GitHubRelease) async throws -> String {
        guard let asset = release.dmgAsset else {
            throw UpdateError.noDMGAsset(release.htmlURL)
        }
        let temporaryURL: URL
        let response: URLResponse
        do {
            (temporaryURL, response) = try await URLSession(configuration: .ephemeral).download(from: asset.browserDownloadURL)
        } catch let error as URLError {
            throw classifiedNetworkError(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw UpdateError.invalidReleaseData
        }
        switch http.statusCode {
        case 200..<300:
            break
        case 403, 429:
            throw UpdateError.rateLimited
        case 404:
            throw UpdateError.noDMGAsset(release.htmlURL)
        default:
            throw UpdateError.badServerResponse(http.statusCode)
        }
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
        let destination = downloads.appendingPathComponent(asset.name)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        await MainActor.run {
            _ = NSWorkspace.shared.open(destination)
        }
        return asset.name
    }

    static func openReleasesPage() {
        NSWorkspace.shared.open(releasesPageURL)
    }

    static func openProjectPage() {
        NSWorkspace.shared.open(projectPageURL)
    }

    private static func classifiedNetworkError(_ error: URLError) -> Error {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .timedOut:
            UpdateError.networkUnavailable
        default:
            error
        }
    }

    private static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = versionParts(lhs)
        let right = versionParts(rhs)
        let count = max(left.count, right.count)
        for index in 0..<count {
            let leftValue = index < left.count ? left[index] : 0
            let rightValue = index < right.count ? right[index] : 0
            if leftValue > rightValue { return .orderedDescending }
            if leftValue < rightValue { return .orderedAscending }
        }
        return .orderedSame
    }

    private static func versionParts(_ version: String) -> [Int] {
        version
            .trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            .split(separator: ".")
            .map { Int($0) ?? 0 }
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

private enum JournalRange: String, CaseIterable, Identifiable {
    case today = "今天"
    case yesterday = "昨天"
    case last7Days = "近 7 天"

    var id: String { rawValue }
}

private struct AgentJournalCard: View {
    @Environment(\.agentPulseSettings) private var settings
    @Environment(\.colorScheme) private var colorScheme
    let journal: UsageDomainModel.JournalSummary
    let todayTokens: Int
    let privacy: Bool

    @State private var range: JournalRange = .today
    @State private var expandedCurrentDay = false
    @State private var expandedYesterday = false
    @State private var expandedGroups: Set<String> = []
    @State private var didInitializeExpandedGroups = false
    @State private var exportMessage: String?

    var body: some View {
        GlassPanel(title: AppStrings.Sections.agentJournal) {
            HStack {
                Picker("Journal 范围", selection: $range) {
                    ForEach(JournalRange.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                Spacer()
                Button("导出") {
                    exportJournal()
                }
                .disabled(selectedEntries.isEmpty)
            }

            if let exportMessage {
                Text(exportMessage)
                    .font(.caption)
                    .foregroundStyle(exportMessage.contains("失败") ? settings.errorText(system: colorScheme) : settings.secondaryText(system: colorScheme))
            }

            switch range {
            case .today:
                journalList(
                    entries: journal.todayEntries,
                    totalTokens: todayTokens,
                    expanded: $expandedCurrentDay,
                    emptyText: "今天还没有可展示的 Codex 工作段。"
                )
            case .yesterday:
                journalList(
                    entries: journal.yesterdayEntries,
                    totalTokens: journal.yesterdayEntries.reduce(0) { $0 + $1.tokens },
                    expanded: $expandedYesterday,
                    emptyText: "昨天没有可展示的 Codex 工作段。"
                )
            case .last7Days:
                last7DayList
            }
        }
    }

    private var last7DayList: some View {
        VStack(alignment: .leading, spacing: 10) {
            if journal.last7DayGroups.isEmpty {
                EmptyState(text: "最近 7 天还没有可展示的 Codex 工作段。")
            } else {
                ForEach(journal.last7DayGroups) { group in
                    journalGroup(group)
                    if group.id != journal.last7DayGroups.last?.id {
                        Divider().opacity(0.35)
                    }
                }
            }
        }
        .onAppear {
            guard !didInitializeExpandedGroups, let first = journal.last7DayGroups.first else { return }
            didInitializeExpandedGroups = true
            expandedGroups.insert(first.date)
        }
    }

    private func journalGroup(_ group: UsageDomainModel.JournalSummary.DayGroup) -> some View {
        let isExpanded = expandedGroups.contains(group.date)
        return VStack(alignment: .leading, spacing: 10) {
            Button {
                if expandedGroups.contains(group.date) {
                    expandedGroups.remove(group.date)
                } else {
                    expandedGroups.insert(group.date)
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 12)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(dayTitle(group.date))
                            .font(.system(size: 13, weight: .semibold))
                        Text("\(group.entries.count) 个工作段 · \(AgentPulseFormatters.duration(group.totalDurationSeconds)) · \(AgentPulseFormatters.tokens(group.totalTokens))")
                            .font(.caption)
                            .foregroundStyle(settings.secondaryText(system: colorScheme))
                    }
                    Spacer()
                    Text(AgentPulseFormatters.money(group.totalCost, privacy: privacy))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(settings.secondaryText(system: colorScheme))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                journalEntries(group.entries, totalTokens: group.totalTokens, limit: nil)
                    .padding(.leading, 22)
            }
        }
    }

    private func journalList(entries: [UsageSnapshot.JournalEntry], totalTokens: Int, expanded: Binding<Bool>, emptyText: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if entries.isEmpty {
                EmptyState(text: emptyText)
            } else {
                HStack {
                    Text("\(entries.count) 个工作段")
                        .font(.caption)
                        .foregroundStyle(settings.secondaryText(system: colorScheme))
                    Spacer()
                    if entries.count > collapsedLimit {
                        Button(expanded.wrappedValue ? "收起" : "展开全部 \(entries.count) 条") {
                            expanded.wrappedValue.toggle()
                        }
                        .font(.caption)
                    }
                }
                journalEntries(entries, totalTokens: totalTokens, limit: expanded.wrappedValue ? nil : collapsedLimit)
            }
        }
    }

    private func journalEntries(_ entries: [UsageSnapshot.JournalEntry], totalTokens: Int, limit: Int?) -> some View {
        let visibleEntries = limit.map { Array(entries.prefix($0)) } ?? entries
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(visibleEntries) { entry in
                JournalEntryRow(entry: entry, dayTokens: totalTokens, privacy: privacy)
                if entry.id != visibleEntries.last?.id {
                    Divider().opacity(0.35)
                }
            }
        }
    }

    private var collapsedLimit: Int { 5 }

    private var selectedEntries: [UsageSnapshot.JournalEntry] {
        switch range {
        case .today:
            return journal.todayEntries
        case .yesterday:
            return journal.yesterdayEntries
        case .last7Days:
            return journal.last7DayGroups.flatMap(\.entries)
        }
    }

    private func exportJournal() {
        let entries = selectedEntries.sorted { $0.startedAt < $1.startedAt }
        guard !entries.isEmpty else { return }
        do {
            let paths = AppStoragePaths()
            try FileManager.default.createDirectory(at: paths.logs, withIntermediateDirectories: true)
            let timestamp = exportTimestamp()
            let fileName = "journal-\(rangeFileName)-\(timestamp).md"
            let url = paths.logs.appendingPathComponent(fileName)
            try journalMarkdown(entries: entries).write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            exportMessage = "Journal 已导出"
        } catch {
            exportMessage = "导出失败：\(error.localizedDescription)"
        }
    }

    private var rangeFileName: String {
        switch range {
        case .today: return "today"
        case .yesterday: return "yesterday"
        case .last7Days: return "last-7-days"
        }
    }

    private func journalMarkdown(entries: [UsageSnapshot.JournalEntry]) -> String {
        var lines = [
            "# AgentPulse Journal - \(dayKey(Date()))",
            "",
            "Range: \(range.rawValue)",
            "Exported: \(Date().formatted(date: .numeric, time: .standard))",
            ""
        ]
        var currentDay = ""
        for entry in entries {
            let day = dayKey(entry.startedAt)
            if day != currentDay {
                currentDay = day
                lines.append("## \(day)")
                lines.append("")
            }
            lines.append("### \(entry.startedAt.formatted(date: .omitted, time: .shortened)) - \(entry.endedAt.formatted(date: .omitted, time: .shortened))")
            lines.append("Duration: \(AgentPulseFormatters.duration(entry.durationSeconds))")
            lines.append("Tokens: \(AgentPulseFormatters.tokens(entry.tokens))")
            lines.append("Cost: \(AgentPulseFormatters.money(entry.cost, privacy: privacy))")
            lines.append("Model: \(entry.model ?? "未知")")
            lines.append("Source: \(URL(fileURLWithPath: entry.sourcePath).lastPathComponent)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private func exportTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private func dayTitle(_ day: String) -> String {
        if day == dayKey(Date()) {
            return "今天"
        }
        if let yesterday = Calendar(identifier: .gregorian).date(byAdding: .day, value: -1, to: Date()),
           day == dayKey(yesterday) {
            return "昨天"
        }
        return day
    }

    private func dayKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

private struct JournalEntryRow: View {
    @Environment(\.agentPulseSettings) private var settings
    @Environment(\.colorScheme) private var colorScheme
    let entry: UsageSnapshot.JournalEntry
    let dayTokens: Int
    let privacy: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(AgentPulseColors.working.opacity(0.75))
                    .frame(width: 4, height: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(time(entry.startedAt)) - \(time(entry.endedAt)) · \(AgentPulseFormatters.duration(entry.durationSeconds))")
                        .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    if let model = entry.model {
                        Text("主要模型：\(model)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(settings.secondaryText(system: colorScheme))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Text(URL(fileURLWithPath: entry.sourcePath).lastPathComponent)
                        .font(.system(size: 11))
                        .foregroundStyle(settings.tertiaryText(system: colorScheme))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text(AgentPulseFormatters.tokens(entry.tokens))
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    Text(AgentPulseFormatters.money(entry.cost, privacy: privacy))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(settings.secondaryText(system: colorScheme))
                }
            }
            HStack(spacing: 8) {
                journalMetric("Token", AgentPulseFormatters.tokens(entry.tokens), tint: AgentPulseColors.token)
                journalMetric("占本日", tokenShareText, tint: AgentPulseColors.working)
                journalMetric("Cost", AgentPulseFormatters.money(entry.cost, privacy: privacy), tint: AgentPulseColors.thinking)
            }
        }
        .padding(.vertical, 4)
    }

    private func journalMetric(_ title: String, _ value: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(tint.opacity(0.8))
                .frame(width: 6, height: 6)
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(settings.secondaryText(system: colorScheme))
            Text(value)
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(settings.primaryText(system: colorScheme))
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(settings.isDarkMode(system: colorScheme) ? Color.white.opacity(0.045) : Color.black.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }

    private func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    private var tokenShareText: String {
        guard dayTokens > 0 else { return "--" }
        let percent = Double(entry.tokens) / Double(dayTokens) * 100
        if percent > 0, percent < 0.1 {
            return "<0.1%"
        }
        return String(format: "%.0f%%", percent.rounded())
    }
}

private struct UsageStoryCard: View {
    @Environment(\.agentPulseSettings) private var settings
    @Environment(\.colorScheme) private var colorScheme
    let todayTokens: Int
    let currentModel: String?
    let totalCost: Decimal?
    let totalToolCalls: Int
    let privacy: Bool

    var body: some View {
        GlassPanel(title: "今日使用概览") {
            VStack(alignment: .leading, spacing: 8) {
                storyLine("今日使用 \(AgentPulseFormatters.tokens(todayTokens))")
                storyLine("当前模型：\(currentModel ?? "暂无模型数据")")
                storyLine("主要活动：\(activityText)")
                storyLine("今日花费：\(AgentPulseFormatters.money(totalCost, privacy: privacy))")
            }
        }
    }

    private var activityText: String {
        totalToolCalls > 0 ? "编码与工具调用" : "编码"
    }

    private func storyLine(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(settings.primaryText(system: colorScheme))
            .lineLimit(1)
            .minimumScaleFactor(0.82)
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
    let value: Int?
    var detail: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 76, alignment: .leading)
                Spacer()
                Text(valueText)
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
            Text(quotaBalanceText)
                .font(.caption)
                .foregroundStyle(settings.secondaryText(system: colorScheme))
                .lineLimit(1)
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
        guard let value else { return settings.secondaryText(system: colorScheme) }
        if value <= 20 { return AgentPulseColors.attention }
        if value <= 50 { return AgentPulseColors.thinking }
        return AgentPulseColors.working
    }

    private var valueText: String {
        value.map { "\($0)%" } ?? "--"
    }

    private var quotaBalanceText: String {
        guard let value else {
            return "已使用 -- · 剩余 --"
        }
        let remaining = min(max(value, 0), 100)
        return "已使用 \(100 - remaining)% · 剩余 \(remaining)%"
    }

    private func barWidth(totalWidth: CGFloat) -> CGFloat {
        guard let value else { return 0 }
        guard value > 0 else { return 0 }
        return totalWidth * CGFloat(min(max(value, 0), 100)) / 100
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
                Text(AgentPulseFormatters.money(item.cost, privacy: privacy))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(settings.secondaryText(system: colorScheme))
            }
            HStack(alignment: .firstTextBaseline) {
                Text(AgentPulseFormatters.tokens(item.tokens))
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                    .foregroundStyle(settings.primaryText(system: colorScheme))
                Spacer()
                Text(percentText)
                    .font(.caption.monospacedDigit())
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
                        .frame(width: max(8, geometry.size.width * CGFloat(clampedPercentValue) / 100))
                }
            }
            .frame(height: 7)
            Text("输入 \(AgentPulseFormatters.tokens(item.inputTokens)) · 缓存输入 \(AgentPulseFormatters.tokens(item.cachedInputTokens)) · 输出 \(AgentPulseFormatters.tokens(item.outputTokens))")
                .font(.caption2)
                .foregroundStyle(settings.tertiaryText(system: colorScheme))
                .lineLimit(1)
        }
        .padding(.vertical, 4)
    }

    private var percentValue: Double {
        Double(item.tokens) / Double(max(total, 1)) * 100
    }

    private var clampedPercentValue: Double {
        min(max(percentValue, 0), 100)
    }

    private var percentText: String {
        if percentValue > 0, percentValue < 0.1 {
            return "<0.1%"
        }
        return String(format: "%.1f%%", percentValue)
    }
}

private struct ModelUsageInsight: View {
    @Environment(\.agentPulseSettings) private var settings
    @Environment(\.colorScheme) private var colorScheme
    let model: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("最常用模型")
                .font(.caption)
                .foregroundStyle(settings.secondaryText(system: colorScheme))
            Text(model ?? "暂无模型数据")
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Text("按 Token 使用量排序")
                .font(.caption)
                .foregroundStyle(settings.tertiaryText(system: colorScheme))
        }
        .padding(.bottom, 4)
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
                Text("\(AgentPulseFormatters.tokens(value)) · \(percentText)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(settings.secondaryText(system: colorScheme))
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(settings.dividerColor(system: colorScheme))
                    Capsule()
                        .fill(tint.opacity(0.8))
                        .frame(width: max(value == 0 ? 0 : 7, geometry.size.width * CGFloat(clampedPercentValue) / 100))
                }
            }
            .frame(height: 7)
        }
        .padding(.vertical, 3)
    }

    private var percent: Int {
        Int(percentValue.rounded())
    }

    private var percentValue: Double {
        guard total > 0 else { return 0 }
        return Double(value) / Double(total) * 100
    }

    private var clampedPercentValue: Double {
        min(max(percentValue, 0), 100)
    }

    private var percentText: String {
        guard total > 0 else { return "0%" }
        if value > 0, percentValue < 0.1 {
            return "<0.1%"
        }
        if percentValue < 10, percentValue.rounded() != percentValue {
            return String(format: "%.1f%%", percentValue)
        }
        return "\(percent)%"
    }
}

private struct ToolUsageRow: View {
    @Environment(\.agentPulseSettings) private var settings
    @Environment(\.colorScheme) private var colorScheme
    let item: UsageDomainModel.ToolSummary.Item

    var body: some View {
        HStack {
            Text(item.name)
                .font(.system(size: 13, weight: .medium))
            Spacer()
            Text("\(item.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(settings.secondaryText(system: colorScheme))
                .frame(width: 48, alignment: .trailing)
            Text("\(item.percentage)%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(AgentPulseColors.token)
                .frame(width: 42, alignment: .trailing)
        }
        .padding(.vertical, 3)
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
