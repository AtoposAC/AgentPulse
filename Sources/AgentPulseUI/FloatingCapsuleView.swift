import SwiftUI
import AgentPulseCore

public struct FloatingCapsuleStackView: View {
    @ObservedObject private var store: AgentPulseStore
    @State private var expanded = false
    @State private var hoverTimer: Timer?

    public init(store: AgentPulseStore) {
        self.store = store
    }

    public var body: some View {
        let agents = sortedAgents
        VStack(spacing: 8) {
            FloatingCapsuleView(agent: agents.first ?? AgentSnapshot(kind: .codex), agents: agents, settings: store.settings, expanded: expanded)
        }
        .contentShape(Rectangle())
        .onHover { inside in
            hoverTimer?.invalidate()
            hoverTimer = Timer.scheduledTimer(withTimeInterval: inside ? 0.2 : 0.3, repeats: false) { _ in
                Task { @MainActor in
                    withAnimation(.easeInOut(duration: 0.24)) {
                        expanded = inside
                    }
                }
            }
        }
        .onDisappear {
            hoverTimer?.invalidate()
            hoverTimer = nil
        }
        .preferredColorScheme(store.settings.preferredColorScheme)
    }

    private var sortedAgents: [AgentSnapshot] {
        store.visibleAgents.sorted {
            if $0.signal.priority == $1.signal.priority {
                return $0.kind.displayName < $1.kind.displayName
            }
            return $0.signal.priority > $1.signal.priority
        }
    }
}

public struct FloatingCapsuleView: View {
    @Environment(\.colorScheme) private var colorScheme
    let agent: AgentSnapshot
    let agents: [AgentSnapshot]
    let settings: AgentPulseSettings
    let expanded: Bool

    public init(agent: AgentSnapshot, agents: [AgentSnapshot] = [], settings: AgentPulseSettings, expanded: Bool) {
        self.agent = agent
        self.agents = agents
        self.settings = settings
        self.expanded = expanded
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            expandedBody
                .opacity(expanded ? 1 : 0)
                .offset(y: expanded ? 0 : -6)
                .frame(height: expanded ? nil : 0, alignment: .top)
                .clipped()
        }
        .frame(width: expanded ? 356 : 260, alignment: .leading)
        .padding(.horizontal, expanded ? 12 : 7)
        .padding(.vertical, expanded ? 10 : 7)
        .background(CapsuleGlassBackground(settings: settings, cornerRadius: expanded ? 20 : 15))
        .foregroundStyle(settings.primaryText(system: colorScheme))
        .fontDesign(.default)
        .help(capsuleHelpText)
    }

    private var header: some View {
        HStack(spacing: expanded ? 9 : 5) {
            StatusDot(signal: agent.signal, compact: !expanded)
            VStack(alignment: .leading, spacing: expanded ? 2 : 1) {
                Text("\(agent.kind.displayName) · \(agent.signal.title)")
                    .font(.system(size: 10))
                    .foregroundStyle(settings.secondaryText(system: colorScheme))
                    .lineLimit(1)
                Text(primaryMetricText)
                    .font(.system(size: 14, weight: .bold).monospacedDigit())
                    .lineLimit(1)
                Text(secondaryMetricText)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(AgentPulseColors.token)
                    .lineLimit(1)
            }
            Spacer(minLength: expanded ? 6 : 2)
            if agent.kind == .codex {
                quotaBadge(agent.usage.quota5hRemainingPercent)
            }
        }
    }

    private var primaryMetricText: String {
        agent.kind == .codex ? AgentPulseFormatters.money(agent.usage.todayCost, privacy: settings.privacyMode) : "状态监测"
    }

    private var secondaryMetricText: String {
        agent.kind == .codex ? "\(AgentPulseFormatters.tokens(agent.usage.todayTokens)) 今日" : "Token 暂未提供"
    }

    private var expandedBody: some View {
        VStack(alignment: .leading, spacing: 9) {
            if agents.count > 1 {
                DividerLine(settings: settings)
                Text("Agent 状态")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(settings.primaryText(system: colorScheme).opacity(0.68))
                ForEach(agents) { item in
                    agentStatusRow(item)
                }
            }
            DividerLine(settings: settings)
            if agent.kind == .codex {
                metricRow("费用", AgentPulseFormatters.money(agent.usage.todayCost, privacy: settings.privacyMode), title: "今日用量")
                metricRow("Token", AgentPulseFormatters.tokens(agent.usage.todayTokens))
                DividerLine(settings: settings)
                quotaRow("5小时", value: agent.usage.quota5hRemainingPercent ?? 0, detail: quotaResetText(agent.usage.quota5hResetAt, includesDate: false))
                quotaRow("本周", value: agent.usage.quotaWeekRemainingPercent ?? 0, detail: quotaResetText(agent.usage.quotaWeekResetAt, includesDate: true))
                if let lowQuotaText {
                    Text(lowQuotaText)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(AgentPulseColors.attention)
                        .lineLimit(1)
                }
            } else {
                metricRow("监测方式", "Claude Code Hook", title: "Claude 状态")
                metricRow("Token / Cost", "暂未提供")
            }
            DividerLine(settings: settings)
            Text("工具调用 · \(agent.toolStats.total) 次")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(settings.primaryText(system: colorScheme).opacity(0.68))
            metricRow("终端命令", "\(agent.toolStats.terminalCommands)")
            if agent.toolStats.readOperations > 0 {
                metricRow("读取文件", "\(agent.toolStats.readOperations)")
            }
            metricRow("修改文件", "\(agent.toolStats.fileChanges)")
            metricRow("write_stdin", "\(agent.toolStats.writeStdin)")
            if agent.toolStats.searchOperations > 0 {
                metricRow("搜索", "\(agent.toolStats.searchOperations)")
            }
            if agent.toolStats.webRequests > 0 {
                metricRow("网页", "\(agent.toolStats.webRequests)")
            }
            metricRow("其他", "\(agent.toolStats.other)")
            if agent.kind == .codex {
                DividerLine(settings: settings)
                metricRow("近30天费用", AgentPulseFormatters.money(agent.usage.thirtyDayCost, privacy: settings.privacyMode))
                metricRow("近30天 Token", AgentPulseFormatters.tokens(agent.usage.thirtyDayTokens))
            }
            Button(agent.kind == .codex ? "打开 Codex" : "打开 Claude") {
                openAgent()
            }
            .buttonStyle(.borderedProminent)
            .tint(settings.primaryText(system: colorScheme).opacity(0.14))
        }
        .padding(.top, 9)
    }

    private func agentStatusRow(_ item: AgentSnapshot) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(item.signal.pulseColor.opacity(0.85))
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.kind.displayName)
                    .font(.system(size: 11, weight: .medium))
                Text(agentRecentEventText(item))
                    .font(.system(size: 9))
                    .foregroundStyle(settings.tertiaryText(system: colorScheme))
                    .lineLimit(1)
            }
            Spacer()
            Text(item.signal.title)
                .font(.system(size: 11))
                .foregroundStyle(settings.secondaryText(system: colorScheme))
        }
    }

    private func agentRecentEventText(_ item: AgentSnapshot) -> String {
        let date = item.recentEvents.first?.date ?? item.updatedAt
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 {
            return "最近事件 \(seconds) 秒前"
        }
        if seconds < 3600 {
            return "最近事件 \(seconds / 60) 分钟前"
        }
        return "最近事件 \(date.formatted(date: .omitted, time: .shortened))"
    }

    private func metricRow(_ label: String, _ value: String, title: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let title {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(settings.primaryText(system: colorScheme).opacity(0.72))
            }
            HStack {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(settings.secondaryText(system: colorScheme))
                Spacer()
                Text(value)
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
            }
        }
    }

    private func quotaRow(_ label: String, value: Int, detail: String?) -> some View {
        let accent = quotaAccent(value)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(settings.secondaryText(system: colorScheme))
                    .frame(width: 36, alignment: .leading)
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(settings.dividerColor(system: colorScheme))
                        Capsule()
                            .fill(LinearGradient(colors: [accent.opacity(0.65), accent], startPoint: .leading, endPoint: .trailing))
                            .frame(width: quotaBarWidth(totalWidth: geometry.size.width, value: value))
                    }
                }
                .frame(height: 6)
                Text("\(value)%")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(accent)
                    .frame(width: 32, alignment: .trailing)
            }
            if let detail {
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(settings.secondaryText(system: colorScheme).opacity(0.82))
                    .lineLimit(1)
                    .padding(.leading, 44)
            }
        }
    }

    private func quotaAccent(_ value: Int) -> Color {
        if value <= 20 { return AgentPulseColors.attention }
        if value <= 50 { return AgentPulseColors.thinking }
        return AgentPulseColors.working
    }

    private func quotaBarWidth(totalWidth: CGFloat, value: Int) -> CGFloat {
        guard value > 0 else { return 0 }
        return max(7, totalWidth * CGFloat(max(0, min(value, 100))) / 100)
    }

    private func quotaResetText(_ date: Date?, includesDate: Bool) -> String? {
        guard let date else { return nil }
        if includesDate {
            return "重置 \(date.formatted(.dateTime.month(.defaultDigits).day().weekday(.abbreviated).hour().minute()))"
        }
        return "重置 \(date.formatted(date: .omitted, time: .shortened))"
    }

    private func quotaBadge(_ value: Int?) -> some View {
        let percent = value
        let accent = percent.map(quotaAccent) ?? settings.secondaryText(system: colorScheme)
        return Text(percent.map { "\($0)%" } ?? "--")
            .font(.system(size: 10, weight: .semibold).monospacedDigit())
            .foregroundStyle(accent)
            .frame(minWidth: 34)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(accent.opacity(0.08), in: Capsule())
            .overlay(Capsule().stroke(accent.opacity(0.82), lineWidth: 1))
            .help(quotaBadgeHelp(percent: percent))
    }

    private func quotaBadgeHelp(percent: Int?) -> String {
        var text = percent.map { "5 小时额度剩余 \($0)%" } ?? "5 小时额度剩余未知"
        if let reset = quotaResetText(agent.usage.quota5hResetAt, includesDate: false) {
            text += " · \(reset)"
        }
        if let source = agent.usage.quotaDataSource {
            text += " · \(source)"
        }
        return text
    }

    private var capsuleHelpText: String {
        [
            currentModelText,
            "当前状态：\(agent.signal.title)",
            "今日活跃：\(AgentPulseFormatters.duration(displayActiveSeconds))",
            toolActivityText
        ]
        .compactMap { $0 }
        .joined(separator: "\n")
    }

    private var displayActiveSeconds: TimeInterval {
        let today = dayKey(Date())
        let journalSeconds = agent.usage.journalEntries
            .filter { dayKey($0.startedAt) == today }
            .reduce(0) { $0 + $1.durationSeconds }
        return max(agent.usage.todayActiveSeconds, journalSeconds)
    }

    private func dayKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private var currentModelText: String? {
        guard let model = agent.usage.currentModel else { return nil }
        return "当前模型：\(model)"
    }

    private var toolActivityText: String? {
        guard agent.toolStats.total > 0 else { return nil }
        return "工具调用：今日 \(agent.toolStats.total) 次"
    }

    private var lowQuotaText: String? {
        guard agent.usage.quotaDataSource == "Codex WHAM 实时接口" else { return nil }
        if let value = agent.usage.quota5hRemainingPercent, value <= 20 {
            return "5 小时额度 ≤20%"
        }
        if let value = agent.usage.quotaWeekRemainingPercent, value <= 20 {
            return "本周额度 ≤20%"
        }
        return nil
    }

    private func openAgent() {
        if agent.kind == .claude {
            NSWorkspace.shared.open(HookManager.claudeHookLogURL.deletingLastPathComponent())
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}

private struct CapsuleGlassBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    let settings: AgentPulseSettings
    let cornerRadius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(settings.capsuleFill(system: colorScheme))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: settings.capsuleHighlight(system: colorScheme),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: settings.capsuleStroke(system: colorScheme),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .compositingGroup()
    }
}

private struct StatusDot: View {
    let signal: AgentSignal
    var compact = false
    @State private var phase = false

    var body: some View {
        ZStack {
            if signal.pulsePeriod > 0 {
                Circle()
                    .stroke(signal.pulseColor.opacity(phase ? 0.05 : 0.42), lineWidth: phase ? 1 : 2.2)
                    .frame(width: phase ? outerSize : coreSize, height: phase ? outerSize : coreSize)
                    .scaleEffect(phase ? 1.0 : 0.72)
                Circle()
                    .stroke(signal.pulseColor.opacity(phase ? 0.02 : 0.26), lineWidth: 1.5)
                    .frame(width: phase ? outerSize + outerPadding : coreSize + 2, height: phase ? outerSize + outerPadding : coreSize + 2)
                    .scaleEffect(phase ? 1.0 : 0.68)
            }
            Circle()
                .fill(signal.pulseColor)
                .frame(width: compact ? 7 : 11, height: compact ? 7 : 11)
        }
        .frame(width: compact ? 14 : 26, height: compact ? 14 : 26)
        .opacity(signal == .idle ? 0.62 : 1)
            .onAppear { animate() }
            .onChange(of: signal) { _, _ in animate() }
    }

    private func animate() {
        phase = false
        guard signal.pulsePeriod > 0 else { return }
        withAnimation(.easeOut(duration: signal.pulsePeriod).repeatForever(autoreverses: false)) {
            phase = true
        }
    }

    private var outerSize: CGFloat {
        switch signal {
        case .attention: compact ? 20 : 26
        case .thinking: compact ? 17 : 23
        case .working: compact ? 16 : 22
        case .done: compact ? 14 : 19
        case .idle: compact ? 8 : 11
        }
    }

    private var coreSize: CGFloat {
        compact ? 8 : 11
    }

    private var outerPadding: CGFloat {
        compact ? 6 : 9
    }
}

private struct DividerLine: View {
    @Environment(\.colorScheme) private var colorScheme
    let settings: AgentPulseSettings

    var body: some View {
        Rectangle()
            .fill(settings.dividerColor(system: colorScheme))
            .frame(height: 1)
    }
}
