import Foundation

@MainActor
public final class AgentPulseStore: ObservableObject {
    @Published public var agents: [AgentSnapshot]
    @Published public var settings: AgentPulseSettings
    @Published public private(set) var isRefreshingCodexQuota = false
    @Published public private(set) var isRefreshingUsage = false

    private let paths: AppStoragePaths
    private let stateStore: JSONFileStore<[AgentSnapshot]>
    private let settingsStore: JSONFileStore<AgentPulseSettings>
    private let usageCacheStore: JSONFileStore<UsageCache>
    private var usageCache: UsageCache
    private var timer: Timer?
    private var stateWatcher: StateFileWatcher?
    private var claudeHookWatcher: ClaudeHookWatcher?
    private var lastQuotaFetchAt: Date?
    private var lastUsageScanAt: Date?
    private var forceNextUsageScan = false
    private var didRunLaunchHydration = false
    private var codexRefreshInFlight = false
    private var hasObservedCodexStateThisRun = false
    private let codexRefreshQueue = DispatchQueue(label: "app.agentpulse.codex-session-refresh", qos: .utility)
    private let usageScanInterval: TimeInterval = 45
    private let activeTimeMaxIncrement: TimeInterval = 5
    private let sessionMergeWindow: TimeInterval = 5 * 60
    private let fallbackQuota5hTokenBudget = 50_000_000
    private let fallbackQuotaWeekTokenBudget = 500_000_000

    public init(paths: AppStoragePaths = AppStoragePaths()) {
        self.paths = paths
        self.stateStore = JSONFileStore<[AgentSnapshot]>(url: paths.state)
        self.settingsStore = JSONFileStore<AgentPulseSettings>(url: paths.settings)
        self.usageCacheStore = JSONFileStore<UsageCache>(url: paths.usageCache)
        self.settings = settingsStore.load(default: AgentPulseSettings())
        self.usageCache = usageCacheStore.load(default: UsageCache())
        self.agents = stateStore.load(default: [
            AgentSnapshot(kind: .codex, signal: .idle, hookInstalled: false)
        ]).filter { $0.kind == .codex || $0.kind == .claude }
    }

    public func start() {
        refresh()
        stateWatcher = StateFileWatcher(stateFileURL: paths.state) { [weak self] in
            self?.mergePersistedState()
        }
        stateWatcher?.start()
        configureClaudeMonitoring()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    public func refreshLaunchDataOnce() {
        guard !didRunLaunchHydration else { return }
        didRunLaunchHydration = true
        guard settings.codexMonitoringEnabled else { return }
        refreshCodexQuota(force: true)
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        stateWatcher?.stop()
        stateWatcher = nil
        claudeHookWatcher?.stop()
        claudeHookWatcher = nil
    }

    public func refresh() {
        if settings.monitoringPaused {
            applyPausedState()
            persist()
            return
        }
        mergePersistedState()
        if settings.codexMonitoringEnabled {
            refreshCodex()
        } else {
            removeAgent(.codex)
        }
        refreshClaudeStatus()
        persist()
    }

    public func updateSettings(_ settings: AgentPulseSettings) {
        let oldSettings = self.settings
        self.settings = settings
        try? settingsStore.save(settings)
        if shouldRefreshAfterSettingsChange(from: oldSettings, to: settings) {
            refresh()
        }
        if oldSettings.claudeMonitoringEnabled != settings.claudeMonitoringEnabled {
            configureClaudeMonitoring()
            refresh()
        }
    }

    public func setPaused(_ paused: Bool) {
        var copy = settings
        copy.monitoringPaused = paused
        updateSettings(copy)
    }

    public func persist() {
        try? stateStore.save(agents)
    }

    public func resetUsageCache() {
        usageCache = UsageCache()
        try? usageCacheStore.save(usageCache)
        forceNextUsageScan = true
        refresh()
    }

    public func refreshUsageNow() {
        guard !isRefreshingUsage else { return }
        isRefreshingUsage = true
        forceNextUsageScan = true
        refresh()
    }

    public func refreshCodexQuotaNow() {
        refreshCodexQuota(force: true)
    }

    public var visibleAgents: [AgentSnapshot] {
        if settings.monitoringPaused {
            let kinds = agents
                .filter { $0.kind == .codex || $0.kind == .claude }
                .map(\.kind)
            return (kinds.isEmpty ? [AgentKind.codex] : kinds).map {
                AgentSnapshot(kind: $0, signal: .idle, currentCommand: "监控已暂停", updatedAt: Date())
            }
        }
        let activityWindow: TimeInterval = 120
        let active = agents.filter { snapshot in
            guard snapshot.kind == .codex || snapshot.kind == .claude else { return false }
            if snapshot.signal != .idle {
                return true
            }
            return Date().timeIntervalSince(snapshot.updatedAt) < activityWindow
        }
        if active.isEmpty {
            return [AgentSnapshot(kind: .codex, signal: .idle, currentCommand: "全部空闲")]
        }
        return active
    }

    public var codexSessionRoot: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/sessions")
    }

    public var claudeSettingsURL: URL { HookManager.claudeSettingsURL }
    public var claudeHookLogURL: URL { HookManager.claudeHookLogURL }
    public var stateFileURL: URL { paths.state }
    public var settingsFileURL: URL { paths.settings }
    public var usageCacheFileURL: URL { paths.usageCache }

    public func healthChecks() -> [AgentPulseHealthCheck] {
        let codex = agents.first(where: { $0.kind == .codex })
        let usage = codex?.usage
        var checks = [
            healthCheck(FileManager.default.fileExists(atPath: codexSessionRoot.path), "Codex session 目录", codexSessionRoot.path),
            healthCheck(usage?.latestSessionPath != nil, "最近 Codex session", usage?.latestSessionPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "未发现"),
            healthCheck((usage?.thirtyDayTokens ?? 0) > 0, "Token 扫描", usage?.thirtyDayTokens.map { "\($0) tokens" } ?? "无数据"),
            healthCheck(!(usage?.modelTokenUsage.isEmpty ?? true), "模型识别", topModelSummary(usage?.modelTokenUsage ?? [])),
            healthCheck((usage?.thirtyDayCost ?? 0) > 0, "费用估算", usage?.thirtyDayCost.map { "$\(Self.moneyString($0))" } ?? "待确认"),
            healthCheck(codex != nil, "状态解析", codex.map { "\($0.signal.title) · \($0.currentCommand ?? "无消息")" } ?? "无状态"),
            healthCheck(settings.doneSoundEnabled || settings.attentionSoundEnabled, "提示音", "音量 \(settings.soundVolume.title)"),
            healthCheck(settings.showFloatingWindow, "悬浮胶囊", settings.showFloatingWindow ? "已开启" : "已关闭"),
            healthCheck(settings.codexMonitoringEnabled, "Codex 监控", settings.codexMonitoringEnabled ? "已开启" : "已关闭")
        ]
        if settings.claudeMonitoringEnabled {
            let claude = agents.first(where: { $0.kind == .claude })
            let hook = HookManager.diagnoseClaudeHook()
            checks.append(healthCheck(hook.hookInstalled, "Claude Hook", hook.hookInstalled ? "已安装" : "未安装"))
            checks.append(healthCheck(hook.logWritable, "Claude Hook 日志", hook.logWritable ? "可写" : "不可写"))
            checks.append(healthCheck(claude != nil, "Claude 状态", claude.map { "\($0.signal.title) · \($0.currentCommand ?? "无消息")" } ?? "无状态"))
        }
        return checks
    }

    public func recentCodexSessionSummaries(limit: Int = 5) -> [String] {
        recentJSONLs(in: codexSessionRoot, limit: limit).compactMap { file in
            let lines = tailLines(url: file, maxLines: 10_000)
            guard !lines.isEmpty else { return nil }
            let result = CodexLogParser.parseRecentLines(lines)
            let modified = latestModificationDate(file)
            let time = modified.map { quotaDateFormatter.string(from: $0) } ?? "未知时间"
            return "\(file.lastPathComponent) · \(result.signal.title) · \(result.eventMessage) · \(time)"
        }
    }

    public func loadRecentCodexSessionSummaries(limit: Int = 5, completion: @escaping @MainActor ([String]) -> Void) {
        let root = codexSessionRoot
        codexRefreshQueue.async {
            let summaries = CodexRefreshWorker.sessionSummaries(root: root, limit: limit)
            DispatchQueue.main.async {
                completion(summaries)
            }
        }
    }

    public func installClaudeHook() throws {
        try HookManager.installClaudeHook()
        var copy = settings
        copy.claudeMonitoringEnabled = true
        updateSettings(copy)
        refreshClaudeStatus()
        persist()
    }

    public func uninstallClaudeHook() throws {
        try HookManager.uninstallClaudeHook()
        var copy = settings
        copy.claudeMonitoringEnabled = false
        updateSettings(copy)
        removeAgent(.claude)
        persist()
    }

    public func diagnosticSummary() -> String {
        let codex = agents.first(where: { $0.kind == .codex })
        let claude = agents.first(where: { $0.kind == .claude })
        let claudeHook = HookManager.diagnoseClaudeHook()
        let usage = codex?.usage
        return """
        \(AppStrings.Diagnostics.title)
        \(AppStrings.Diagnostics.monitoringPaused): \(settings.monitoringPaused)
        \(AppStrings.Diagnostics.floatingWindow): \(settings.showFloatingWindow)
        \(AppStrings.Diagnostics.codexEnabled): \(settings.codexMonitoringEnabled)
        \(AppStrings.Diagnostics.codexStatus): \(codex?.signal.title ?? AppStrings.Diagnostics.unknown) · \(codex?.currentCommand ?? AppStrings.Diagnostics.none)
        \(AppStrings.Diagnostics.codexStatusReason): \(codex?.statusReason ?? AppStrings.Diagnostics.unknown)
        \(AppStrings.Diagnostics.codexStatusAge): \(codexStatusAgeSummary(codex))
        Claude 监控: \(settings.claudeMonitoringEnabled)
        Claude 状态: \(claude?.signal.title ?? AppStrings.Diagnostics.unknown) · \(claude?.currentCommand ?? AppStrings.Diagnostics.none)
        Claude 状态来源: \(claude?.statusReason ?? AppStrings.Diagnostics.unknown)
        Claude 状态时效: \(agentStatusAgeSummary(claude))
        Claude Hook: \(claudeHook.hookInstalled ? "已安装" : "未安装")
        Claude Hook 脚本: \(claudeHook.hookScriptExecutable ? "可执行" : "不可执行") · \(HookManager.hookScriptURL.path)
        Claude Hook 日志: \(claudeHook.logWritable ? "可写" : "不可写") · \(HookManager.claudeHookLogURL.path)
        Claude 最近事件: \(claudeHook.latestEventAt.map { quotaDateFormatter.string(from: $0) } ?? AppStrings.Diagnostics.unknown)
        Claude 工具调用: \(toolStatsSummary(claude?.toolStats ?? ToolStats()))
        \(AppStrings.Diagnostics.currentSignal): \(codex?.signal.title ?? AppStrings.Diagnostics.unknown)
        \(AppStrings.Diagnostics.previousSignal): \(signalTitle(usage?.previousSignal))
        \(AppStrings.Diagnostics.lastActiveSignal): \(signalTitle(usage?.lastActiveSignal))
        \(AppStrings.Diagnostics.lastRefresh): previous=\(signalTitle(usage?.lastRefreshPreviousSignal)), current=\(signalTitle(usage?.lastRefreshCurrentSignal)), increment=\(durationSummary(usage?.lastRefreshIncrementSeconds ?? 0))
        \(AppStrings.Diagnostics.sessionMergeWindow): 5m
        \(AppStrings.Diagnostics.lastSessionActivity): \(usage?.lastSessionActivityAt.map { quotaDateFormatter.string(from: $0) } ?? AppStrings.Diagnostics.none)
        \(AppStrings.Diagnostics.willCreateNewSession): \(willCreateNewSessionSummary(usage))
        \(AppStrings.Diagnostics.sessionCreateReason): \(usage?.sessionCreateReason ?? AppStrings.Diagnostics.unknown)
        \(AppStrings.Diagnostics.currentSessionStartedAt): \(usage?.currentSessionStartedAt.map { quotaDateFormatter.string(from: $0) } ?? AppStrings.Diagnostics.none)
        \(AppStrings.Diagnostics.todayActiveTime): \(durationSummary(usage?.todayActiveSeconds ?? 0))
        \(AppStrings.Diagnostics.todaySessions): \(usage.map { String($0.todaySessionCount) } ?? "0")
        \(AppStrings.Diagnostics.lastActiveIncrement): \(durationSummary(usage?.lastActiveIncrementSeconds ?? 0))
        \(AppStrings.Diagnostics.todayTokens): \(usage?.todayTokens.map(String.init) ?? AppStrings.Diagnostics.unknown)
        \(AppStrings.Diagnostics.thirtyDayTokens): \(usage?.thirtyDayTokens.map(String.init) ?? AppStrings.Diagnostics.unknown)
        \(AppStrings.Diagnostics.recentDailyTokens): \(dailyTokenSummary(usage?.dailyTokenUsage ?? []))
        \(AppStrings.Diagnostics.usageScannedAt): \(usage?.usageScannedAt.map { quotaDateFormatter.string(from: $0) } ?? AppStrings.Diagnostics.unknown)
        \(AppStrings.Diagnostics.tokenBreakdown): \(tokenBreakdownSummary(usage))
        \(AppStrings.Diagnostics.tokenSource): \(usage?.tokenDataSource ?? "~/.codex/sessions JSONL")
        \(AppStrings.Diagnostics.costSource): \(usage?.costDataSource ?? costDataSourceDescription)
        \(AppStrings.Diagnostics.quotaSource): \(usage?.quotaDataSource ?? "等待 WHAM 刷新；失败时使用本地 Token 临时参考")
        \(AppStrings.Diagnostics.topModels): \(topModelSummary(usage?.modelTokenUsage ?? []))
        \(AppStrings.Diagnostics.toolStats): \(toolStatsSummary(codex?.toolStats ?? ToolStats()))
        \(AppStrings.Diagnostics.quota5hRemaining): \(usage?.quota5hRemainingPercent.map { "\($0)%" } ?? AppStrings.Diagnostics.unknown)
        \(AppStrings.Diagnostics.quota5hReset): \(usage?.quota5hResetAt.map { quotaDateFormatter.string(from: $0) } ?? AppStrings.Diagnostics.unknown)
        \(AppStrings.Diagnostics.weekQuotaRemaining): \(usage?.quotaWeekRemainingPercent.map { "\($0)%" } ?? AppStrings.Diagnostics.unknown)
        \(AppStrings.Diagnostics.weekQuotaReset): \(usage?.quotaWeekResetAt.map { quotaDateFormatter.string(from: $0) } ?? AppStrings.Diagnostics.unknown)
        \(AppStrings.Diagnostics.quotaLastError): \(usage?.quotaLastError ?? AppStrings.Diagnostics.none)
        \(AppStrings.Diagnostics.scannedUsageFiles): \(usage?.scannedFileCount.map(String.init) ?? "0")
        \(AppStrings.Diagnostics.latestSession): \(usage?.latestSessionPath ?? AppStrings.Diagnostics.unknown)
        \(AppStrings.Diagnostics.latestSessionModified): \(usage?.latestSessionModifiedAt.map { quotaDateFormatter.string(from: $0) } ?? AppStrings.Diagnostics.unknown)
        \(AppStrings.Diagnostics.usageCacheSchema): \(usageCache.schemaVersion)
        \(AppStrings.Diagnostics.stateFile): \(paths.state.path)
        \(AppStrings.Diagnostics.settingsFile): \(paths.settings.path)
        \(AppStrings.Diagnostics.usageCache): \(paths.usageCache.path)
        \(AppStrings.Diagnostics.codexSessions): \(codexSessionRoot.path)
        """
    }

    private func refreshCodex() {
        let sessionRoot = codexSessionRoot
        guard !codexRefreshInFlight else { return }
        codexRefreshInFlight = true
        let existing = agents.first(where: { $0.kind == .codex }) ?? AgentSnapshot(kind: .codex)
        let settings = settings
        let usageCache = usageCache
        let shouldScanUsage = shouldScanUsageNow()
        let costDataSource = costDataSourceDescription
        codexRefreshQueue.async { [weak self] in
            let result = CodexRefreshWorker.refresh(
                sessionRoot: sessionRoot,
                existing: existing,
                settings: settings,
                usageCache: usageCache,
                shouldScanUsage: shouldScanUsage,
                costDataSource: costDataSource
            )
            DispatchQueue.main.async {
                self?.applyCodexRefreshResult(result)
            }
        }
    }

    private func applyCodexRefreshResult(_ refresh: CodexRefreshWorker.Result) {
        codexRefreshInFlight = false
        isRefreshingUsage = false
        guard var snapshot = refresh.snapshot else {
            upsert(AgentSnapshot(kind: .codex, signal: .idle, currentCommand: "未发现 Codex 会话日志", updatedAt: Date()))
            return
        }
        let existingCodex = agents.first(where: { $0.kind == .codex })
        preserveWhamQuota(from: existingCodex?.usage ?? UsageSnapshot(), into: &snapshot.usage)
        applyWorkingTime(
            existing: existingCodex,
            to: &snapshot,
            at: Date(),
            allowIncrement: hasObservedCodexStateThisRun
        )
        hasObservedCodexStateThisRun = true
        if let updatedCache = refresh.usageCache {
            usageCache = updatedCache
            try? usageCacheStore.save(usageCache)
            lastUsageScanAt = Date()
            forceNextUsageScan = false
        }
        upsert(snapshot)
        persist()
        refreshCodexQuota(force: false)
    }

    private func bestCodexCandidate(_ candidates: [(file: URL, result: CodexParseResult, age: TimeInterval)]) -> (file: URL, result: CodexParseResult, age: TimeInterval)? {
        candidates.max { left, right in
            let leftFresh = freshnessScore(signal: left.result.signal, age: left.age)
            let rightFresh = freshnessScore(signal: right.result.signal, age: right.age)
            if leftFresh == rightFresh {
                return (latestModificationDate(left.file) ?? .distantPast) < (latestModificationDate(right.file) ?? .distantPast)
            }
            return leftFresh < rightFresh
        }
    }

    private func statusReason(file: URL, signal: AgentSignal, age: TimeInterval) -> String {
        let seconds = max(0, Int(age))
        let ageText: String
        if seconds < 60 {
            ageText = "\(seconds) 秒前"
        } else {
            ageText = "\(seconds / 60) 分钟前"
        }
        return "来自 \(file.lastPathComponent) · \(signal.title) 优先级 · \(ageText)"
    }

    private func shouldScanUsageNow() -> Bool {
        if forceNextUsageScan { return true }
        guard let lastUsageScanAt else { return true }
        return Date().timeIntervalSince(lastUsageScanAt) >= usageScanInterval
    }

    private func freshnessScore(signal: AgentSignal, age: TimeInterval) -> Int {
        let activeWindow: TimeInterval = signal == .done ? TimeInterval(settings.doneHoldSeconds) : 180
        guard age <= activeWindow else { return 0 }
        return signal.priority
    }

    private var costDataSourceDescription: String {
        "日志真实 cost 字段；缺失时使用隐藏模型费率表"
    }

    private func healthCheck(_ passed: Bool, _ title: String, _ detail: String) -> AgentPulseHealthCheck {
        AgentPulseHealthCheck(title: title, detail: detail, status: passed ? .ok : .warning)
    }

    private func shouldRefreshAfterSettingsChange(from old: AgentPulseSettings, to new: AgentPulseSettings) -> Bool {
        old.monitoringPaused != new.monitoringPaused
        || old.codexMonitoringEnabled != new.codexMonitoringEnabled
        || old.doneHoldSeconds != new.doneHoldSeconds
        || old.estimateCodexInternalCost != new.estimateCodexInternalCost
        || old.codexInternalCostPerMillionTokens != new.codexInternalCostPerMillionTokens
        || old.codexQuota5hTokenBudget != new.codexQuota5hTokenBudget
        || old.codexQuotaWeekTokenBudget != new.codexQuotaWeekTokenBudget
    }

    private static func moneyString(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: value as NSDecimalNumber) ?? "0.00"
    }

    private func displayState(signal: AgentSignal, message: String, latestAge: TimeInterval) -> (signal: AgentSignal, message: String) {
        switch signal {
        case .attention:
            return (.attention, message)
        case .done:
            let hold = TimeInterval(settings.doneHoldSeconds)
            return latestAge <= hold ? (.done, message) : (.idle, "Codex 空闲")
        case .thinking, .working:
            return latestAge < 90 ? (signal, message) : (.idle, "Codex 空闲")
        case .idle:
            return (.idle, "Codex 空闲")
        }
    }

    private func preserveWhamQuota(from existing: UsageSnapshot, into usage: inout UsageSnapshot) {
        guard existing.quotaDataSource == "Codex WHAM 实时接口" else { return }
        usage.quota5hRemainingPercent = existing.quota5hRemainingPercent
        usage.quotaWeekRemainingPercent = existing.quotaWeekRemainingPercent
        usage.quota5hResetAt = existing.quota5hResetAt
        usage.quotaWeekResetAt = existing.quotaWeekResetAt
        usage.quota5hWindowSeconds = existing.quota5hWindowSeconds
        usage.quotaWeekWindowSeconds = existing.quotaWeekWindowSeconds
        usage.quotaDataSource = existing.quotaDataSource
        usage.quotaUpdatedAt = existing.quotaUpdatedAt
        usage.quotaLastError = existing.quotaLastError
        usage.quotaLastErrorAt = existing.quotaLastErrorAt
    }

    private func configureClaudeMonitoring() {
        claudeHookWatcher?.stop()
        claudeHookWatcher = nil
        guard settings.claudeMonitoringEnabled else { return }
        let watcher = ClaudeHookWatcher(
            logURL: HookManager.claudeHookLogURL,
            onEvent: { [weak self] event in
                self?.applyClaudeHookEvent(event)
            },
            onDiagnostics: { [weak self] _ in
                self?.refreshClaudeStatus()
            }
        )
        claudeHookWatcher = watcher
        watcher.start()
        refreshClaudeStatus()
    }

    private func refreshClaudeStatus() {
        guard settings.claudeMonitoringEnabled else {
            removeAgent(.claude)
            return
        }
        var snapshot = agents.first(where: { $0.kind == .claude }) ?? AgentSnapshot(kind: .claude)
        snapshot.hookInstalled = HookManager.isClaudeHookInstalled()
        if !snapshot.hookInstalled {
            snapshot.signal = .idle
            snapshot.currentCommand = "Claude Hook 未安装"
            snapshot.statusReason = "需要在 Agent 页安装 Claude Code Hook"
            snapshot.updatedAt = Date()
        } else if Date().timeIntervalSince(snapshot.updatedAt) > 180, snapshot.signal != .idle {
            snapshot.signal = .idle
            snapshot.currentCommand = "Claude 空闲"
            snapshot.statusReason = "等待 Claude Code Hook 事件"
            snapshot.updatedAt = Date()
        } else if snapshot.currentCommand == nil {
            snapshot.signal = .idle
            snapshot.currentCommand = "等待 Claude Code Hook 事件"
            snapshot.statusReason = "来自 \(HookManager.claudeHookLogURL.lastPathComponent)"
            snapshot.updatedAt = Date()
        }
        upsert(snapshot)
    }

    private func applyClaudeHookEvent(_ event: ClaudeHookEvent) {
        guard settings.claudeMonitoringEnabled else { return }
        var snapshot = agents.first(where: { $0.kind == .claude }) ?? AgentSnapshot(kind: .claude)
        snapshot.signal = event.signal
        snapshot.currentCommand = event.message
        snapshot.statusReason = event.toolName.map { "Claude Hook · \(event.type) · \($0)" } ?? "Claude Hook · \(event.type)"
        snapshot.updatedAt = event.date
        snapshot.hookInstalled = HookManager.isClaudeHookInstalled()
        snapshot.recentEvents = ([AgentEvent(kind: .claude, signal: event.signal, message: event.message)] + snapshot.recentEvents).prefix(50).map { $0 }
        if event.signal == .working {
            incrementClaudeToolStats(toolName: event.toolName, snapshot: &snapshot)
        }
        upsert(snapshot)
        persist()
    }

    private func incrementClaudeToolStats(toolName: String?, snapshot: inout AgentSnapshot) {
        let name = toolName?.lowercased() ?? ""
        if name.contains("read") || name.contains("open") || name.contains("view") {
            snapshot.toolStats.readOperations += 1
        } else if name.contains("edit") || name.contains("write") || name.contains("patch") {
            snapshot.toolStats.fileChanges += 1
        } else if name.contains("search") || name.contains("grep") || name.contains("glob") {
            snapshot.toolStats.searchOperations += 1
        } else if name.contains("web") || name.contains("browser") {
            snapshot.toolStats.webRequests += 1
        } else if name.contains("bash") || name.contains("shell") || name.contains("command") {
            snapshot.toolStats.terminalCommands += 1
        } else {
            snapshot.toolStats.other += 1
        }
    }

    private func applyWorkingTime(existing: AgentSnapshot?, to snapshot: inout AgentSnapshot, at now: Date, allowIncrement: Bool) {
        let todayKey = Self.dayKey(now)
        var usage = snapshot.usage
        let existingUsage = existing?.usage ?? UsageSnapshot()
        if existingUsage.activeTimeDate == todayKey {
            usage.activeTimeDate = todayKey
            usage.todayActiveSeconds = existingUsage.todayActiveSeconds
            usage.todaySessionCount = existingUsage.todaySessionCount
            usage.currentSessionStartedAt = existingUsage.currentSessionStartedAt
            usage.lastSessionActivityAt = existingUsage.lastSessionActivityAt
            usage.sessionCreateReason = existingUsage.sessionCreateReason
            usage.todayHourlyActiveSeconds = normalizedHourlyActiveSeconds(existingUsage.todayHourlyActiveSeconds)
            usage.lastActiveIncrementSeconds = 0
            usage.previousSignal = existingUsage.previousSignal
            usage.lastActiveSignal = existingUsage.lastActiveSignal
            usage.lastRefreshPreviousSignal = existingUsage.lastRefreshPreviousSignal
            usage.lastRefreshCurrentSignal = existingUsage.lastRefreshCurrentSignal
            usage.lastRefreshIncrementSeconds = 0
        } else {
            usage.activeTimeDate = todayKey
            usage.todayActiveSeconds = 0
            usage.todaySessionCount = 0
            usage.currentSessionStartedAt = nil
            usage.lastSessionActivityAt = nil
            usage.sessionCreateReason = nil
            usage.todayHourlyActiveSeconds = Array(repeating: 0, count: 24)
            usage.lastActiveIncrementSeconds = 0
            usage.previousSignal = nil
            usage.lastActiveSignal = nil
            usage.lastRefreshPreviousSignal = nil
            usage.lastRefreshCurrentSignal = nil
            usage.lastRefreshIncrementSeconds = 0
        }

        if allowIncrement, isActiveTimeSignal(existing?.signal) {
            addActiveInterval(from: existing?.updatedAt ?? now, to: now, into: &usage)
            if usage.lastActiveIncrementSeconds > 0 {
                usage.lastActiveSignal = existing?.signal
            }
        }

        if isActiveTimeSignal(snapshot.signal) {
            let hadPreviousSession = usage.lastSessionActivityAt != nil
            let canMerge = canMergeSession(lastActivityAt: usage.lastSessionActivityAt, now: now)
            if !hadPreviousSession {
                usage.todaySessionCount += 1
                usage.currentSessionStartedAt = now
                usage.sessionCreateReason = "No Previous Session"
            } else if !canMerge {
                usage.todaySessionCount += 1
                usage.currentSessionStartedAt = now
                usage.sessionCreateReason = "Session Timeout (>5m)"
            } else if usage.currentSessionStartedAt == nil {
                usage.currentSessionStartedAt = usage.lastSessionActivityAt ?? now
                usage.sessionCreateReason = allowIncrement ? "Merge Existing Session" : "First Observation Merged"
            } else {
                usage.sessionCreateReason = allowIncrement ? "Merge Existing Session" : "First Observation Merged"
            }
            usage.lastSessionActivityAt = now
        } else {
            if !canMergeSession(lastActivityAt: usage.lastSessionActivityAt, now: now) {
                usage.currentSessionStartedAt = nil
            }
        }

        usage.previousSignal = existing?.signal
        usage.lastRefreshPreviousSignal = existing?.signal
        usage.lastRefreshCurrentSignal = snapshot.signal
        usage.lastRefreshIncrementSeconds = usage.lastActiveIncrementSeconds
        snapshot.usage = usage
    }

    private func isActiveTimeSignal(_ signal: AgentSignal?) -> Bool {
        signal == .thinking || signal == .working
    }

    private func canMergeSession(lastActivityAt: Date?, now: Date) -> Bool {
        guard let lastActivityAt else { return false }
        return now.timeIntervalSince(lastActivityAt) <= sessionMergeWindow
    }

    private func addActiveInterval(from start: Date, to end: Date, into usage: inout UsageSnapshot) {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: end)
        var cursor = max(start, startOfToday)
        guard end > cursor else { return }
        let cappedEnd = min(end, cursor.addingTimeInterval(activeTimeMaxIncrement))
        usage.todayHourlyActiveSeconds = normalizedHourlyActiveSeconds(usage.todayHourlyActiveSeconds)
        var added: TimeInterval = 0

        while cursor < cappedEnd {
            let hour = calendar.component(.hour, from: cursor)
            let nextHour = calendar.nextDate(after: cursor, matching: DateComponents(minute: 0, second: 0), matchingPolicy: .nextTime) ?? end
            let segmentEnd = min(cappedEnd, nextHour)
            let seconds = max(0, segmentEnd.timeIntervalSince(cursor))
            usage.todayActiveSeconds += seconds
            added += seconds
            if hour >= 0 && hour < usage.todayHourlyActiveSeconds.count {
                usage.todayHourlyActiveSeconds[hour] += seconds
            }
            cursor = segmentEnd
        }
        usage.lastActiveIncrementSeconds = added
    }

    private func normalizedHourlyActiveSeconds(_ values: [TimeInterval]) -> [TimeInterval] {
        if values.count == 24 { return values }
        if values.count > 24 { return Array(values.prefix(24)) }
        return values + Array(repeating: 0, count: 24 - values.count)
    }

    private static func dayKey(_ date: Date, calendar: Calendar = Calendar.current) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let year = components.year ?? 0
        let month = components.month ?? 0
        let day = components.day ?? 0
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    private func topModelSummary(_ models: [UsageSnapshot.ModelTokenUsage]) -> String {
        guard !models.isEmpty else { return AppStrings.Diagnostics.unknown }
        let total = max(models.reduce(0) { $0 + $1.tokens }, 1)
        return models.prefix(3).map { item in
            let percent = Int((Double(item.tokens) / Double(total) * 100).rounded())
            return "\(item.model) \(percent)%"
        }.joined(separator: ", ")
    }

    private func dailyTokenSummary(_ daily: [UsageSnapshot.DailyTokenUsage]) -> String {
        guard !daily.isEmpty else { return AppStrings.Diagnostics.unknown }
        return daily.suffix(5)
            .map { "\($0.date)=\($0.tokens)" }
            .joined(separator: ", ")
    }

    private func toolStatsSummary(_ stats: ToolStats) -> String {
        "terminal \(stats.terminalCommands), read \(stats.readOperations), files \(stats.fileChanges), write_stdin \(stats.writeStdin), search \(stats.searchOperations), web \(stats.webRequests), other \(stats.other), total \(stats.total)"
    }

    private func codexStatusAgeSummary(_ codex: AgentSnapshot?) -> String {
        agentStatusAgeSummary(codex)
    }

    private func agentStatusAgeSummary(_ agent: AgentSnapshot?) -> String {
        guard let agent else { return AppStrings.Diagnostics.unknown }
        let seconds = max(0, Int(Date().timeIntervalSince(agent.updatedAt)))
        return "\(seconds)s"
    }

    private func durationSummary(_ seconds: TimeInterval) -> String {
        String(format: "%.1fs", max(0, seconds))
    }

    private func signalTitle(_ signal: AgentSignal?) -> String {
        signal?.title ?? AppStrings.Diagnostics.unknown
    }

    private func willCreateNewSessionSummary(_ usage: UsageSnapshot?) -> String {
        guard let usage else { return AppStrings.Diagnostics.unknown }
        return canMergeSession(lastActivityAt: usage.lastSessionActivityAt, now: Date()) ? "No" : "Yes"
    }

    private func tokenBreakdownSummary(_ usage: UsageSnapshot?) -> String {
        guard let usage else { return AppStrings.Diagnostics.unknown }
        let input = usage.inputTokens ?? 0
        let cached = usage.cachedInputTokens ?? 0
        let output = usage.outputTokens ?? 0
        guard input + cached + output > 0 else { return AppStrings.Diagnostics.unknown }
        return "输入 \(input), 缓存输入 \(cached), 输出 \(output)"
    }

    private func refreshCodexQuota(force: Bool) {
        if !force, let lastQuotaFetchAt, Date().timeIntervalSince(lastQuotaFetchAt) < 60 {
            return
        }
        if isRefreshingCodexQuota {
            return
        }
        lastQuotaFetchAt = Date()
        isRefreshingCodexQuota = true
        Task {
            do {
                let quota = try await CodexQuotaFetcher.fetch()
                await MainActor.run {
                    isRefreshingCodexQuota = false
                    guard let index = agents.firstIndex(where: { $0.kind == .codex }) else { return }
                    applyCodexQuota(quota, to: &agents[index].usage)
                    persist()
                }
            } catch {
                await MainActor.run {
                    isRefreshingCodexQuota = false
                    guard let index = agents.firstIndex(where: { $0.kind == .codex }) else { return }
                    agents[index].usage.quotaLastError = readableQuotaError(error)
                    agents[index].usage.quotaLastErrorAt = Date()
                    persist()
                }
            }
        }
    }

    private func applyCodexQuota(_ quota: CodexQuotaSnapshot, to usage: inout UsageSnapshot) {
        let fiveHourResetChanged = usage.quota5hResetAt != quota.quota5hResetAt
        let weekResetChanged = usage.quotaWeekResetAt != quota.quotaWeekResetAt

        if let value = quota.quota5hRemainingPercent {
            usage.quota5hRemainingPercent = value
        } else if fiveHourResetChanged {
            usage.quota5hRemainingPercent = nil
        }

        if let value = quota.quotaWeekRemainingPercent {
            usage.quotaWeekRemainingPercent = value
        } else if weekResetChanged {
            usage.quotaWeekRemainingPercent = nil
        }

        usage.quota5hResetAt = quota.quota5hResetAt
        usage.quotaWeekResetAt = quota.quotaWeekResetAt
        usage.quota5hWindowSeconds = quota.quota5hWindowSeconds
        usage.quotaWeekWindowSeconds = quota.quotaWeekWindowSeconds
        usage.quotaDataSource = "Codex WHAM 实时接口"
        usage.quotaUpdatedAt = quota.updatedAt
        usage.quotaLastError = nil
        usage.quotaLastErrorAt = nil
    }

    private func readableQuotaError(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .userAuthenticationRequired:
                return "无法读取 Codex 登录凭据"
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost:
                return "网络不可用，暂时无法刷新 WHAM"
            case .badServerResponse:
                return "WHAM 返回异常"
            default:
                return urlError.localizedDescription
            }
        }
        return error.localizedDescription
    }

    private func applyPausedState() {
        if agents.isEmpty {
            agents = [AgentSnapshot(kind: .codex, signal: .idle, currentCommand: "监控已暂停", updatedAt: Date())]
            return
        }
        agents = agents.map { snapshot in
            var paused = snapshot
            applyWorkingTime(existing: snapshot, to: &paused, at: Date(), allowIncrement: hasObservedCodexStateThisRun)
            paused.signal = .idle
            paused.currentCommand = "监控已暂停"
            paused.updatedAt = Date()
            return paused
        }
    }

    private func upsert(_ snapshot: AgentSnapshot) {
        if let index = agents.firstIndex(where: { $0.kind == snapshot.kind }) {
            agents[index] = snapshot
        } else {
            agents.append(snapshot)
        }
    }

    private func mergePersistedState() {
        let persisted = stateStore.load(default: [AgentSnapshot]())
        for snapshot in persisted {
            guard snapshot.kind == .codex || snapshot.kind == .claude else { continue }
            if snapshot.updatedAt > (agents.first(where: { $0.kind == snapshot.kind })?.updatedAt ?? .distantPast) {
                upsert(snapshot)
            }
        }
    }

    private func removeAgent(_ kind: AgentKind) {
        agents.removeAll { $0.kind == kind }
    }

    private func latestJSONL(in root: URL) -> URL? {
        recentJSONLs(in: root, limit: 1).first
    }

    private func recentJSONLs(in root: URL, limit: Int) -> [URL] {
        candidateSessionFiles(root: root, days: 7)
            .filter { $0.pathExtension == "jsonl" && $0.lastPathComponent.hasPrefix("rollout-") }
            .sorted {
                let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return left > right
            }
            .prefix(limit)
            .map { $0 }
    }

    private func candidateSessionFiles(root: URL, days: Int) -> [URL] {
        let calendar = Calendar(identifier: .gregorian)
        let dates = (0..<days).compactMap { calendar.date(byAdding: .day, value: -$0, to: Date()) }
        return dates.flatMap { date -> [URL] in
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            guard let year = parts.year, let month = parts.month, let day = parts.day else { return [] }
            let directory = root
                .appendingPathComponent(String(format: "%04d", year))
                .appendingPathComponent(String(format: "%02d", month))
                .appendingPathComponent(String(format: "%02d", day))
            return (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        }
    }

    private func tailLines(url: URL, maxLines: Int) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return Array(text.split(separator: "\n").suffix(maxLines)).map(String.init)
    }

    private func latestModificationAge(_ url: URL) -> TimeInterval {
        let date = latestModificationDate(url) ?? .distantPast
        return Date().timeIntervalSince(date)
    }

    private func latestModificationDate(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private func todayKey() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    private func rollingTokens(hours: Double, cache: UsageCache) -> Int {
        let cutoff = Date().addingTimeInterval(-hours * 3600)
        return cache.files.values
            .filter { $0.modifiedAt >= cutoff }
            .reduce(0) { $0 + $1.tokens }
    }

    private func remainingPercent(budget: Int, used: Int) -> Int {
        guard budget > 0 else { return 0 }
        let remaining = max(0, budget - used)
        return max(0, min(100, Int((Double(remaining) / Double(budget) * 100).rounded())))
    }

    private var quotaDateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter
    }
}

private enum CodexRefreshWorker {
    struct Result: Sendable {
        var snapshot: AgentSnapshot?
        var usageCache: UsageCache?
    }

    static func refresh(
        sessionRoot: URL,
        existing: AgentSnapshot,
        settings: AgentPulseSettings,
        usageCache: UsageCache,
        shouldScanUsage: Bool,
        costDataSource: String
    ) -> Result {
        let recentFiles = recentJSONLs(in: sessionRoot, limit: 8)
        guard !recentFiles.isEmpty else {
            return Result(snapshot: nil, usageCache: nil)
        }

        let candidates = recentFiles.compactMap { file -> (file: URL, result: CodexParseResult, age: TimeInterval)? in
            let lines = tailLines(url: file, maxLines: 10_000)
            guard !lines.isEmpty else { return nil }
            let result = CodexLogParser.parseRecentLines(lines)
            let age = result.lastMeaningfulEventAt.map { Date().timeIntervalSince($0) } ?? latestModificationAge(file)
            return (file, result, age)
        }
        guard let selected = bestCodexCandidate(candidates, doneHoldSeconds: settings.doneHoldSeconds) else {
            return Result(snapshot: nil, usageCache: nil)
        }

        let parse = selected.result
        let display = displayState(signal: parse.signal, message: parse.eventMessage, latestAge: selected.age, doneHoldSeconds: settings.doneHoldSeconds)
        let event = AgentEvent(kind: .codex, signal: parse.signal, message: parse.eventMessage)
        var snapshot = existing
        snapshot.signal = display.signal
        snapshot.currentCommand = display.message
        snapshot.statusReason = statusReason(file: selected.file, signal: parse.signal, age: selected.age)
        snapshot.updatedAt = Date()
        snapshot.toolStats = parse.toolStats
        snapshot.recentEvents = ([event] + snapshot.recentEvents).prefix(50).map { $0 }

        var usage = snapshot.usage
        usage.tokenDataSource = "~/.codex/sessions JSONL"
        usage.costDataSource = costDataSource
        usage.toolStats = parse.toolStats
        usage.scannedFileCount = usageCache.files.count
        usage.latestSessionPath = selected.file.path
        usage.latestSessionModifiedAt = latestModificationDate(selected.file)

        var updatedCache: UsageCache?
        if shouldScanUsage {
            let scan = CodexUsageScanner.scanUsage(
                root: sessionRoot,
                options: CodexUsageScanner.Options(
                    estimateInternalModelCost: settings.estimateCodexInternalCost,
                    internalCostPerMillionTokens: settings.codexInternalCostPerMillionTokens
                ),
                cache: usageCache
            )
            updatedCache = scan.cache
            let daily = scan.daily
            usage.scannedFileCount = scan.cache.files.count
            usage.usageScannedAt = Date()
            usage.journalEntries = scan.journalEntries
            if !daily.isEmpty {
                usage.dailyTokenUsage = daily
                usage.modelTokenUsage = scan.models
                usage.inputTokens = scan.models.reduce(0) { $0 + $1.inputTokens }
                usage.cachedInputTokens = scan.models.reduce(0) { $0 + $1.cachedInputTokens }
                usage.outputTokens = scan.models.reduce(0) { $0 + $1.outputTokens }
                usage.thirtyDayTokens = daily.reduce(0) { $0 + $1.tokens }
                let costs = daily.compactMap(\.cost)
                usage.thirtyDayCost = costs.isEmpty ? nil : costs.reduce(Decimal(0), +)
                let today = daily.last { $0.date == todayKey() }
                usage.todayTokens = today?.tokens ?? usage.todayTokens
                usage.todayCost = today?.cost ?? usage.todayCost
                usage.quota5hRemainingPercent = remainingPercent(
                    budget: 50_000_000,
                    used: rollingTokens(hours: 5, cache: scan.cache)
                )
                usage.quotaWeekRemainingPercent = remainingPercent(
                    budget: 500_000_000,
                    used: daily.suffix(7).reduce(0) { $0 + $1.tokens }
                )
                usage.quotaDataSource = "本地 token 临时参考"
            }
        }

        snapshot.usage = usage
        return Result(snapshot: snapshot, usageCache: updatedCache)
    }

    static func sessionSummaries(root: URL, limit: Int) -> [String] {
        recentJSONLs(in: root, limit: limit).compactMap { file in
            let lines = tailLines(url: file, maxLines: 10_000)
            guard !lines.isEmpty else { return nil }
            let result = CodexLogParser.parseRecentLines(lines)
            let modified = latestModificationDate(file)
            let time = modified.map { quotaDateFormatter.string(from: $0) } ?? "未知时间"
            return "\(file.lastPathComponent) · \(result.signal.title) · \(result.eventMessage) · \(time)"
        }
    }

    private static func bestCodexCandidate(_ candidates: [(file: URL, result: CodexParseResult, age: TimeInterval)], doneHoldSeconds: Int) -> (file: URL, result: CodexParseResult, age: TimeInterval)? {
        candidates.max { left, right in
            let leftFresh = freshnessScore(signal: left.result.signal, age: left.age, doneHoldSeconds: doneHoldSeconds)
            let rightFresh = freshnessScore(signal: right.result.signal, age: right.age, doneHoldSeconds: doneHoldSeconds)
            if leftFresh == rightFresh {
                return (latestModificationDate(left.file) ?? .distantPast) < (latestModificationDate(right.file) ?? .distantPast)
            }
            return leftFresh < rightFresh
        }
    }

    private static func freshnessScore(signal: AgentSignal, age: TimeInterval, doneHoldSeconds: Int) -> Int {
        let activeWindow: TimeInterval = signal == .done ? TimeInterval(doneHoldSeconds) : 180
        guard age <= activeWindow else { return 0 }
        return signal.priority
    }

    private static func displayState(signal: AgentSignal, message: String, latestAge: TimeInterval, doneHoldSeconds: Int) -> (signal: AgentSignal, message: String) {
        switch signal {
        case .attention:
            return (.attention, message)
        case .done:
            let hold = TimeInterval(doneHoldSeconds)
            return latestAge <= hold ? (.done, message) : (.idle, "Codex 空闲")
        case .thinking, .working:
            return latestAge < 90 ? (signal, message) : (.idle, "Codex 空闲")
        case .idle:
            return (.idle, "Codex 空闲")
        }
    }

    private static func statusReason(file: URL, signal: AgentSignal, age: TimeInterval) -> String {
        let seconds = max(0, Int(age))
        let ageText = seconds < 60 ? "\(seconds) 秒前" : "\(seconds / 60) 分钟前"
        return "来自 \(file.lastPathComponent) · \(signal.title) 优先级 · \(ageText)"
    }

    private static func recentJSONLs(in root: URL, limit: Int) -> [URL] {
        candidateSessionFiles(root: root, days: 7)
            .filter { $0.pathExtension == "jsonl" && $0.lastPathComponent.hasPrefix("rollout-") }
            .sorted {
                let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return left > right
            }
            .prefix(limit)
            .map { $0 }
    }

    private static func candidateSessionFiles(root: URL, days: Int) -> [URL] {
        let calendar = Calendar(identifier: .gregorian)
        let dates = (0..<days).compactMap { calendar.date(byAdding: .day, value: -$0, to: Date()) }
        return dates.flatMap { date -> [URL] in
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            guard let year = parts.year, let month = parts.month, let day = parts.day else { return [] }
            let directory = root
                .appendingPathComponent(String(format: "%04d", year))
                .appendingPathComponent(String(format: "%02d", month))
                .appendingPathComponent(String(format: "%02d", day))
            return (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        }
    }

    private static func tailLines(url: URL, maxLines: Int) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return Array(text.split(separator: "\n").suffix(maxLines)).map(String.init)
    }

    private static func latestModificationAge(_ url: URL) -> TimeInterval {
        let date = latestModificationDate(url) ?? .distantPast
        return Date().timeIntervalSince(date)
    }

    private static func latestModificationDate(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private static func todayKey() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    private static func rollingTokens(hours: Double, cache: UsageCache) -> Int {
        let cutoff = Date().addingTimeInterval(-hours * 3600)
        return cache.files.values
            .filter { $0.modifiedAt >= cutoff }
            .reduce(0) { $0 + $1.tokens }
    }

    private static func remainingPercent(budget: Int, used: Int) -> Int {
        guard budget > 0 else { return 0 }
        let remaining = max(0, budget - used)
        return max(0, min(100, Int((Double(remaining) / Double(budget) * 100).rounded())))
    }

    private static var quotaDateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter
    }
}
