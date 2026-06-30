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
    private var lastQuotaFetchAt: Date?
    private var lastUsageScanAt: Date?
    private var forceNextUsageScan = false
    private var codexRefreshInFlight = false
    private let codexRefreshQueue = DispatchQueue(label: "app.agentpulse.codex-session-refresh", qos: .utility)
    private let usageScanInterval: TimeInterval = 45
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
        ]).filter { $0.kind != .claude }
    }

    public func start() {
        refresh()
        stateWatcher = StateFileWatcher(stateFileURL: paths.state) { [weak self] in
            self?.mergePersistedState()
        }
        stateWatcher?.start()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        stateWatcher?.stop()
        stateWatcher = nil
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
        removeAgent(.claude)
        persist()
    }

    public func updateSettings(_ settings: AgentPulseSettings) {
        let oldSettings = self.settings
        self.settings = settings
        try? settingsStore.save(settings)
        if shouldRefreshAfterSettingsChange(from: oldSettings, to: settings) {
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
            let kinds = agents.filter { $0.kind != .claude }.isEmpty ? [AgentKind.codex] : agents.filter { $0.kind != .claude }.map(\.kind)
            return kinds.map {
                AgentSnapshot(kind: $0, signal: .idle, currentCommand: "监控已暂停", updatedAt: Date())
            }
        }
        let activityWindow: TimeInterval = 120
        let active = agents.filter { snapshot in
            if snapshot.kind == .claude { return false }
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

    public var stateFileURL: URL { paths.state }
    public var settingsFileURL: URL { paths.settings }
    public var usageCacheFileURL: URL { paths.usageCache }

    public func healthChecks() -> [AgentPulseHealthCheck] {
        let codex = agents.first(where: { $0.kind == .codex })
        let usage = codex?.usage
        return [
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

    public func diagnosticSummary() -> String {
        let codex = agents.first(where: { $0.kind == .codex })
        let usage = codex?.usage
        return """
        AgentPulse diagnostics
        Monitoring paused: \(settings.monitoringPaused)
        Floating window: \(settings.showFloatingWindow)
        Codex enabled: \(settings.codexMonitoringEnabled)
        Codex status: \(codex?.signal.title ?? "unknown") · \(codex?.currentCommand ?? "none")
        Codex status reason: \(codex?.statusReason ?? "unknown")
        Codex status age: \(codexStatusAgeSummary(codex))
        Today tokens: \(usage?.todayTokens.map(String.init) ?? "unknown")
        30d tokens: \(usage?.thirtyDayTokens.map(String.init) ?? "unknown")
        Recent daily tokens: \(dailyTokenSummary(usage?.dailyTokenUsage ?? []))
        Usage scanned at: \(usage?.usageScannedAt.map { quotaDateFormatter.string(from: $0) } ?? "unknown")
        Input/cached/output: \(tokenBreakdownSummary(usage))
        Token source: \(usage?.tokenDataSource ?? "~/.codex/sessions JSONL")
        Cost source: \(usage?.costDataSource ?? costDataSourceDescription)
        Quota source: \(usage?.quotaDataSource ?? "等待 WHAM 刷新；失败时使用本地 token 临时参考")
        Top models: \(topModelSummary(usage?.modelTokenUsage ?? []))
        Tool stats: \(toolStatsSummary(codex?.toolStats ?? ToolStats()))
        5h quota remaining: \(usage?.quota5hRemainingPercent.map { "\($0)%" } ?? "unknown")
        5h quota reset: \(usage?.quota5hResetAt.map { quotaDateFormatter.string(from: $0) } ?? "unknown")
        Week quota remaining: \(usage?.quotaWeekRemainingPercent.map { "\($0)%" } ?? "unknown")
        Week quota reset: \(usage?.quotaWeekResetAt.map { quotaDateFormatter.string(from: $0) } ?? "unknown")
        Quota last error: \(usage?.quotaLastError ?? "none")
        Scanned usage files: \(usage?.scannedFileCount.map(String.init) ?? "0")
        Latest session: \(usage?.latestSessionPath ?? "unknown")
        Latest session modified: \(usage?.latestSessionModifiedAt.map { quotaDateFormatter.string(from: $0) } ?? "unknown")
        Usage cache schema: \(usageCache.schemaVersion)
        State file: \(paths.state.path)
        Settings file: \(paths.settings.path)
        Usage cache: \(paths.usageCache.path)
        Codex sessions: \(codexSessionRoot.path)
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
        preserveWhamQuota(from: agents.first(where: { $0.kind == .codex })?.usage ?? UsageSnapshot(), into: &snapshot.usage)
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

    private func topModelSummary(_ models: [UsageSnapshot.ModelTokenUsage]) -> String {
        guard !models.isEmpty else { return "unknown" }
        let total = max(models.reduce(0) { $0 + $1.tokens }, 1)
        return models.prefix(3).map { item in
            let percent = Int((Double(item.tokens) / Double(total) * 100).rounded())
            return "\(item.model) \(percent)%"
        }.joined(separator: ", ")
    }

    private func dailyTokenSummary(_ daily: [UsageSnapshot.DailyTokenUsage]) -> String {
        guard !daily.isEmpty else { return "unknown" }
        return daily.suffix(5)
            .map { "\($0.date)=\($0.tokens)" }
            .joined(separator: ", ")
    }

    private func toolStatsSummary(_ stats: ToolStats) -> String {
        "terminal \(stats.terminalCommands), files \(stats.fileChanges), write_stdin \(stats.writeStdin), other \(stats.other), total \(stats.total)"
    }

    private func codexStatusAgeSummary(_ codex: AgentSnapshot?) -> String {
        guard let codex else { return "unknown" }
        let seconds = max(0, Int(Date().timeIntervalSince(codex.updatedAt)))
        return "\(seconds)s"
    }

    private func tokenBreakdownSummary(_ usage: UsageSnapshot?) -> String {
        guard let usage else { return "unknown" }
        let input = usage.inputTokens ?? 0
        let cached = usage.cachedInputTokens ?? 0
        let output = usage.outputTokens ?? 0
        guard input + cached + output > 0 else { return "unknown" }
        return "input \(input), cached \(cached), output \(output)"
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
                    if let value = quota.quota5hRemainingPercent {
                        agents[index].usage.quota5hRemainingPercent = value
                    }
                    if let value = quota.quotaWeekRemainingPercent {
                        agents[index].usage.quotaWeekRemainingPercent = value
                    }
                    agents[index].usage.quota5hResetAt = quota.quota5hResetAt
                    agents[index].usage.quotaWeekResetAt = quota.quotaWeekResetAt
                    agents[index].usage.quota5hWindowSeconds = quota.quota5hWindowSeconds
                    agents[index].usage.quotaWeekWindowSeconds = quota.quotaWeekWindowSeconds
                    agents[index].usage.quotaDataSource = "Codex WHAM 实时接口"
                    agents[index].usage.quotaUpdatedAt = quota.updatedAt
                    agents[index].usage.quotaLastError = nil
                    agents[index].usage.quotaLastErrorAt = nil
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
        usage.scannedFileCount = usageCache.files.count
        usage.latestSessionPath = selected.file.path
        usage.latestSessionModifiedAt = latestModificationDate(selected.file)

        var updatedCache: UsageCache?
        if shouldScanUsage {
            let scan = CodexUsageScanner.scanDailyTokens(
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
