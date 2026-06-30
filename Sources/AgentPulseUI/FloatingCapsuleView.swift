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
        VStack(spacing: 8) {
            ForEach(store.visibleAgents) { agent in
                FloatingCapsuleView(agent: agent, settings: store.settings, expanded: expanded)
            }
        }
        .contentShape(Rectangle())
        .onHover { inside in
            hoverTimer?.invalidate()
            hoverTimer = Timer.scheduledTimer(withTimeInterval: inside ? 0.2 : 0.3, repeats: false) { _ in
                Task { @MainActor in
                    withAnimation(.easeInOut(duration: inside ? 0.18 : 0.16)) {
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
}

public struct FloatingCapsuleView: View {
    @Environment(\.colorScheme) private var colorScheme
    let agent: AgentSnapshot
    let settings: AgentPulseSettings
    let expanded: Bool

    public init(agent: AgentSnapshot, settings: AgentPulseSettings, expanded: Bool) {
        self.agent = agent
        self.settings = settings
        self.expanded = expanded
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            expandedBody
                .opacity(expanded ? 1 : 0)
                .frame(height: expanded ? nil : 0, alignment: .top)
                .clipped()
        }
        .frame(width: 356, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, expanded ? 14 : 12)
        .background(CapsuleGlassBackground(settings: settings, cornerRadius: 24))
        .foregroundStyle(settings.primaryText(system: colorScheme))
        .fontDesign(.default)
    }

    private var header: some View {
        HStack(spacing: 12) {
            StatusDot(signal: agent.signal)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(agent.kind.displayName) · \(agent.signal.title)")
                    .font(.system(size: 13))
                    .foregroundStyle(settings.secondaryText(system: colorScheme))
                    .lineLimit(1)
                Text(AgentPulseFormatters.money(agent.usage.todayCost, privacy: settings.privacyMode))
                    .font(.system(size: 20, weight: .bold).monospacedDigit())
                    .lineLimit(1)
                Text("\(AgentPulseFormatters.tokens(agent.usage.todayTokens)) 今日")
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(AgentPulseColors.token)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            quotaBadge(agent.usage.quota5hRemainingPercent)
        }
    }

    private var expandedBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            DividerLine(settings: settings)
            metricRow("费用", AgentPulseFormatters.money(agent.usage.todayCost, privacy: settings.privacyMode), title: "今日用量")
            metricRow("Token", AgentPulseFormatters.tokens(agent.usage.todayTokens))
            DividerLine(settings: settings)
            quotaRow("5小时", value: agent.usage.quota5hRemainingPercent ?? 0, detail: quotaResetText(agent.usage.quota5hResetAt, includesDate: false))
            quotaRow("本周", value: agent.usage.quotaWeekRemainingPercent ?? 0, detail: quotaResetText(agent.usage.quotaWeekResetAt, includesDate: true))
            if let lowQuotaText {
                Text(lowQuotaText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AgentPulseColors.attention)
                    .lineLimit(1)
            }
            DividerLine(settings: settings)
            Text("工具调用 · \(agent.toolStats.total) 次")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(settings.primaryText(system: colorScheme).opacity(0.68))
            metricRow("终端命令", "\(agent.toolStats.terminalCommands)")
            metricRow("修改文件", "\(agent.toolStats.fileChanges)")
            metricRow("write_stdin", "\(agent.toolStats.writeStdin)")
            metricRow("其他", "\(agent.toolStats.other)")
            DividerLine(settings: settings)
            metricRow("近30天费用", AgentPulseFormatters.money(agent.usage.thirtyDayCost, privacy: settings.privacyMode))
            metricRow("近30天 Token", AgentPulseFormatters.tokens(agent.usage.thirtyDayTokens))
            Button("打开 Codex") {
                openAgent()
            }
            .buttonStyle(.borderedProminent)
            .tint(settings.primaryText(system: colorScheme).opacity(0.14))
        }
        .padding(.top, 12)
    }

    private func metricRow(_ label: String, _ value: String, title: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(settings.primaryText(system: colorScheme).opacity(0.72))
            }
            HStack {
                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(settings.secondaryText(system: colorScheme))
                Spacer()
                Text(value)
                    .font(.system(size: 14, weight: .medium).monospacedDigit())
            }
        }
    }

    private func quotaRow(_ label: String, value: Int, detail: String?) -> some View {
        let accent = quotaAccent(value)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(settings.secondaryText(system: colorScheme))
                    .frame(width: 42, alignment: .leading)
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(settings.dividerColor(system: colorScheme))
                        Capsule()
                            .fill(LinearGradient(colors: [accent.opacity(0.65), accent], startPoint: .leading, endPoint: .trailing))
                            .frame(width: quotaBarWidth(totalWidth: geometry.size.width, value: value))
                    }
                }
                .frame(height: 8)
                Text("\(value)%")
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(accent)
                    .frame(width: 38, alignment: .trailing)
            }
            if let detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(settings.secondaryText(system: colorScheme).opacity(0.82))
                    .lineLimit(1)
                    .padding(.leading, 52)
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
        let percent = value ?? 0
        let accent = quotaAccent(percent)
        return Text("\(percent)%")
            .font(.system(size: 11, weight: .semibold).monospacedDigit())
            .foregroundStyle(accent)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(accent.opacity(0.08), in: Capsule())
            .overlay(Capsule().stroke(accent.opacity(0.82), lineWidth: 1))
            .help(quotaBadgeHelp(percent: percent))
    }

    private func quotaBadgeHelp(percent: Int) -> String {
        var text = "5 小时额度剩余 \(percent)%"
        if let reset = quotaResetText(agent.usage.quota5hResetAt, includesDate: false) {
            text += " · \(reset)"
        }
        if let source = agent.usage.quotaDataSource {
            text += " · \(source)"
        }
        return text
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
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") {
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
                    .stroke(signal.pulseColor.opacity(phase ? 0.05 : 0.42), lineWidth: phase ? 1 : 3)
                    .frame(width: phase ? outerSize : 14, height: phase ? outerSize : 14)
                    .scaleEffect(phase ? 1.0 : 0.72)
                Circle()
                    .stroke(signal.pulseColor.opacity(phase ? 0.02 : 0.26), lineWidth: 2)
                    .frame(width: phase ? outerSize + 12 : 16, height: phase ? outerSize + 12 : 16)
                    .scaleEffect(phase ? 1.0 : 0.68)
            }
            Circle()
                .fill(signal.pulseColor)
                .frame(width: compact ? 10 : 14, height: compact ? 10 : 14)
        }
        .frame(width: compact ? 20 : 34, height: compact ? 20 : 34)
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
        case .attention: 34
        case .thinking: 30
        case .working: 28
        case .done: 24
        case .idle: 14
        }
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
