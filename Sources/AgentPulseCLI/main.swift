import Foundation
import AgentPulseCore

let arguments = CommandLine.arguments.dropFirst()
let paths = AppStoragePaths()
let stateStore = JSONFileStore<[AgentSnapshot]>(url: paths.state)
let quotaDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .short
    formatter.timeStyle = .medium
    return formatter
}()
let moneyFormatter: NumberFormatter = {
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencyCode = "USD"
    formatter.maximumFractionDigits = 2
    return formatter
}()

switch arguments.first {
case "status":
    let agents = stateStore.load(default: [])
    if agents.isEmpty {
        print("还没有 AgentPulse 状态。")
    } else {
        for agent in agents {
            print("\(agent.kind.displayName): \(agent.signal.title) · \(agent.currentCommand ?? "空闲")")
        }
    }
case "set":
    let args = Array(arguments.dropFirst())
	    guard args.count >= 2,
	          let kind = AgentKind(rawValue: args[0]),
	          kind != .claude,
	          let signal = AgentSignal(rawValue: args[1]) else {
	        print("用法：agentpulse-cli set <codex|local> <idle|thinking|working|done|attention> [message]")
	        Foundation.exit(2)
	    }
    let message = args.dropFirst(2).joined(separator: " ")
    var agents = stateStore.load(default: [])
    var snapshot = agents.first(where: { $0.kind == kind }) ?? AgentSnapshot(kind: kind)
    snapshot.signal = signal
    snapshot.currentCommand = message.isEmpty ? signal.title : message
    snapshot.updatedAt = Date()
    snapshot.recentEvents = ([AgentEvent(kind: kind, signal: signal, message: snapshot.currentCommand ?? signal.title)] + snapshot.recentEvents).prefix(50).map { $0 }
    if let index = agents.firstIndex(where: { $0.kind == kind }) {
        agents[index] = snapshot
    } else {
        agents.append(snapshot)
    }
    do {
        try stateStore.save(agents)
        print("\(kind.displayName) -> \(signal.title)")
    } catch {
        fputs("写入 AgentPulse 状态失败：\(error.localizedDescription)\n", stderr)
        Foundation.exit(1)
    }
case "reset-window":
    UserDefaults.standard.removeObject(forKey: "floatingPanel.x")
    UserDefaults.standard.removeObject(forKey: "floatingPanel.y")
    print("悬浮窗位置已重置。")
case "reset-usage-cache":
    try? JSONFileStore<UsageCache>(url: paths.usageCache).save(UsageCache())
    print("用量缓存已重置。")
case "diagnostics":
    let settings = JSONFileStore<AgentPulseSettings>(url: paths.settings).load(default: AgentPulseSettings())
    let usageCache = JSONFileStore<UsageCache>(url: paths.usageCache).load(default: UsageCache())
    let agents = stateStore.load(default: [])
    let codex = agents.first(where: { $0.kind == .codex })
    let root = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/sessions")
    let usageScanDate = Date()
    let scan = CodexUsageScanner.scanDailyTokens(
        root: root,
        options: CodexUsageScanner.Options(
            estimateInternalModelCost: settings.estimateCodexInternalCost,
            internalCostPerMillionTokens: settings.codexInternalCostPerMillionTokens
        ),
        cache: usageCache
    )
    let latestSession = latestCodexJSONL(in: root)
    let liveStatus = liveCodexStatus(in: root, settings: settings)
    var usage = codex?.usage ?? UsageSnapshot()
    if !scan.daily.isEmpty {
        usage.dailyTokenUsage = scan.daily
        usage.modelTokenUsage = scan.models
        usage.thirtyDayTokens = scan.daily.reduce(0) { $0 + $1.tokens }
        let costs = scan.daily.compactMap(\.cost)
        usage.thirtyDayCost = costs.isEmpty ? nil : costs.reduce(Decimal(0), +)
        usage.todayTokens = scan.daily.last { $0.date == todayKey() }?.tokens
        usage.todayCost = scan.daily.last { $0.date == todayKey() }?.cost
        usage.inputTokens = scan.models.reduce(0) { $0 + $1.inputTokens }
        usage.cachedInputTokens = scan.models.reduce(0) { $0 + $1.cachedInputTokens }
        usage.outputTokens = scan.models.reduce(0) { $0 + $1.outputTokens }
        usage.usageScannedAt = usageScanDate
        usage.scannedFileCount = scan.cache.files.count
        usage.latestSessionPath = latestSession?.path
        usage.latestSessionModifiedAt = latestSession.flatMap(latestModificationDate)
    }
    let costSource = "日志真实 cost 字段；缺失时使用隐藏模型费率表"
    let models = usage.modelTokenUsage
    let modelTotal = max(models.reduce(0) { $0 + $1.tokens }, 1)
    let input = usage.inputTokens ?? 0
    let cached = usage.cachedInputTokens ?? 0
    let output = usage.outputTokens ?? 0
    let topModels = models.isEmpty
        ? AppStrings.Diagnostics.unknown
        : models.prefix(3).map { item in
            let percent = Int((Double(item.tokens) / Double(modelTotal) * 100).rounded())
            return "\(item.model) \(percent)%"
        }.joined(separator: ", ")
    let dailySummary = usage.dailyTokenUsage.isEmpty
        ? AppStrings.Diagnostics.unknown
        : usage.dailyTokenUsage.suffix(5).map { "\($0.date)=\($0.tokens)" }.joined(separator: ", ")
    let liveToolStats: ToolStats = {
        guard let liveStatus else {
            return codex?.toolStats ?? ToolStats()
        }
        return liveStatus.result.toolStats
    }()
    print("""
    \(AppStrings.Diagnostics.title)
    \(AppStrings.Diagnostics.monitoringPaused): \(settings.monitoringPaused)
    \(AppStrings.Diagnostics.floatingWindow): \(settings.showFloatingWindow)
    \(AppStrings.Diagnostics.codexEnabled): \(settings.codexMonitoringEnabled)
    \(AppStrings.Diagnostics.codexStatus): \(liveStatus?.result.signal.title ?? codex?.signal.title ?? AppStrings.Diagnostics.unknown) · \(liveStatus?.result.eventMessage ?? codex?.currentCommand ?? AppStrings.Diagnostics.none)
    \(AppStrings.Diagnostics.codexStatusReason): \(liveStatus.map { statusReason(file: $0.file, signal: $0.result.signal, age: $0.age) } ?? codex?.statusReason ?? AppStrings.Diagnostics.unknown)
    \(AppStrings.Diagnostics.codexStatusAge): \(liveStatus.map { "\(max(0, Int($0.age)))s" } ?? codex.map { "\(max(0, Int(Date().timeIntervalSince($0.updatedAt))))s" } ?? AppStrings.Diagnostics.unknown)
    \(AppStrings.Diagnostics.currentSignal): \(codex?.signal.title ?? AppStrings.Diagnostics.unknown)
    \(AppStrings.Diagnostics.previousSignal): \(usage.previousSignal?.title ?? AppStrings.Diagnostics.unknown)
    \(AppStrings.Diagnostics.lastActiveSignal): \(usage.lastActiveSignal?.title ?? AppStrings.Diagnostics.unknown)
    \(AppStrings.Diagnostics.lastRefresh): previous=\(usage.lastRefreshPreviousSignal?.title ?? AppStrings.Diagnostics.unknown), current=\(usage.lastRefreshCurrentSignal?.title ?? AppStrings.Diagnostics.unknown), increment=\(String(format: "%.1fs", usage.lastRefreshIncrementSeconds))
    \(AppStrings.Diagnostics.sessionMergeWindow): 5m
    \(AppStrings.Diagnostics.lastSessionActivity): \(usage.lastSessionActivityAt.map { quotaDateFormatter.string(from: $0) } ?? AppStrings.Diagnostics.none)
    \(AppStrings.Diagnostics.willCreateNewSession): \(usage.lastSessionActivityAt.map { Date().timeIntervalSince($0) <= 300 ? "No" : "Yes" } ?? "Yes")
    \(AppStrings.Diagnostics.sessionCreateReason): \(usage.sessionCreateReason ?? AppStrings.Diagnostics.unknown)
    \(AppStrings.Diagnostics.currentSessionStartedAt): \(usage.currentSessionStartedAt.map { quotaDateFormatter.string(from: $0) } ?? AppStrings.Diagnostics.none)
    \(AppStrings.Diagnostics.todayActiveTime): \(String(format: "%.1fs", usage.todayActiveSeconds))
    \(AppStrings.Diagnostics.todaySessions): \(usage.todaySessionCount)
    \(AppStrings.Diagnostics.lastActiveIncrement): \(String(format: "%.1fs", usage.lastActiveIncrementSeconds))
    \(AppStrings.Diagnostics.todayTokens): \(usage.todayTokens.map(String.init) ?? AppStrings.Diagnostics.unknown)
    \(AppStrings.Diagnostics.thirtyDayTokens): \(usage.thirtyDayTokens.map(String.init) ?? AppStrings.Diagnostics.unknown)
    \(AppStrings.Diagnostics.recentDailyTokens): \(dailySummary)
    \(AppStrings.Diagnostics.usageScannedAt): \(usage.usageScannedAt.map { quotaDateFormatter.string(from: $0) } ?? AppStrings.Diagnostics.unknown)
    \(AppStrings.Diagnostics.tokenBreakdown): \(input + cached + output > 0 ? "输入 \(input), 缓存输入 \(cached), 输出 \(output)" : AppStrings.Diagnostics.unknown)
    \(AppStrings.Diagnostics.tokenSource): \(usage.tokenDataSource ?? "~/.codex/sessions JSONL")
    \(AppStrings.Diagnostics.costSource): \(usage.costDataSource ?? costSource)
    \(AppStrings.Diagnostics.quotaSource): \(usage.quotaDataSource ?? "等待 WHAM 刷新；失败时使用本地 Token 临时参考")
    \(AppStrings.Diagnostics.topModels): \(topModels)
    \(AppStrings.Diagnostics.toolStats): 终端 \(liveToolStats.terminalCommands), 文件 \(liveToolStats.fileChanges), write_stdin \(liveToolStats.writeStdin), 其他 \(liveToolStats.other), 总计 \(liveToolStats.total)
    \(AppStrings.Diagnostics.quota5hRemaining): \(usage.quota5hRemainingPercent.map { "\($0)%" } ?? AppStrings.Diagnostics.unknown)
    \(AppStrings.Diagnostics.quota5hReset): \(usage.quota5hResetAt.map { quotaDateFormatter.string(from: $0) } ?? AppStrings.Diagnostics.unknown)
    \(AppStrings.Diagnostics.weekQuotaRemaining): \(usage.quotaWeekRemainingPercent.map { "\($0)%" } ?? AppStrings.Diagnostics.unknown)
    \(AppStrings.Diagnostics.weekQuotaReset): \(usage.quotaWeekResetAt.map { quotaDateFormatter.string(from: $0) } ?? AppStrings.Diagnostics.unknown)
    \(AppStrings.Diagnostics.quotaLastError): \(usage.quotaLastError ?? AppStrings.Diagnostics.none)
    \(AppStrings.Diagnostics.cachedUsageFiles): \(scan.cache.files.count)
    \(AppStrings.Diagnostics.latestSession): \(usage.latestSessionPath ?? AppStrings.Diagnostics.unknown)
    \(AppStrings.Diagnostics.latestSessionModified): \(usage.latestSessionModifiedAt.map { quotaDateFormatter.string(from: $0) } ?? AppStrings.Diagnostics.unknown)
    \(AppStrings.Diagnostics.usageCacheSchema): \(scan.cache.schemaVersion)
    \(AppStrings.Diagnostics.stateFile): \(paths.state.path)
    \(AppStrings.Diagnostics.settingsFile): \(paths.settings.path)
    \(AppStrings.Diagnostics.usageCache): \(paths.usageCache.path)
    \(AppStrings.Diagnostics.codexSessions): \(root.path)
    """)
case "doctor":
    let settings = JSONFileStore<AgentPulseSettings>(url: paths.settings).load(default: AgentPulseSettings())
    let root = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/sessions")
    let latestSession = latestCodexJSONL(in: root)
    let scan = CodexUsageScanner.scanDailyTokens(
        root: root,
        options: CodexUsageScanner.Options(
            estimateInternalModelCost: settings.estimateCodexInternalCost,
            internalCostPerMillionTokens: settings.codexInternalCostPerMillionTokens
        ),
        cache: nil
    )
    let totalTokens = scan.daily.reduce(0) { $0 + $1.tokens }
    let totalCost = scan.daily.compactMap(\.cost).reduce(Decimal(0), +)
    let latestParse: CodexParseResult? = {
        guard let latestSession,
              let text = try? String(contentsOf: latestSession, encoding: .utf8) else { return nil }
        return CodexLogParser.parseRecentLines(Array(text.split(separator: "\n").suffix(10_000)).map(String.init))
    }()
    print("AgentPulse doctor")
    print(check(FileManager.default.fileExists(atPath: root.path), "Codex session 目录", root.path))
    print(check(latestSession != nil, "最近 Codex session", latestSession?.lastPathComponent ?? "未发现"))
    print(check(totalTokens > 0, "Token 扫描", "\(totalTokens) Token / \(scan.daily.count) 天"))
    print(check(!scan.models.isEmpty, "模型识别", scan.models.prefix(3).map(\.model).joined(separator: ", ")))
    print(check(totalCost > 0, "费用估算", money(totalCost)))
    print(check(latestParse != nil, "状态解析", latestParse.map { "\($0.signal.title) · \($0.eventMessage)" } ?? "未解析到事件"))
    print(check(settings.doneSoundEnabled || settings.attentionSoundEnabled, "提示音", "音量 \(settings.soundVolume.title)"))
    print(check(settings.showFloatingWindow, "悬浮胶囊", settings.showFloatingWindow ? "已开启" : "已关闭"))
    print(check(settings.codexMonitoringEnabled, "Codex 监控", settings.codexMonitoringEnabled ? "已开启" : "已关闭"))
case "diagnose-codex":
    let root = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/sessions")
    let calendar = Calendar(identifier: .gregorian)
    let files = (0..<7).flatMap { offset -> [URL] in
        guard let date = calendar.date(byAdding: .day, value: -offset, to: Date()) else { return [] }
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return [] }
        let directory = root
            .appendingPathComponent(String(format: "%04d", year))
            .appendingPathComponent(String(format: "%02d", month))
            .appendingPathComponent(String(format: "%02d", day))
        return ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "jsonl" && $0.lastPathComponent.hasPrefix("rollout-") }
    }
    var payloadTypes = Set<String>()
    for file in files.suffix(8) {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
        for line in text.split(separator: "\n") {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = object["payload"] as? [String: Any],
                  let type = payload["type"] as? String else { continue }
            payloadTypes.insert(type)
        }
    }
    print("Codex payload.type values:")
    for type in payloadTypes.sorted() {
        print("- \(type)")
    }
    if let latest = latestCodexJSONL(in: root),
       let text = try? String(contentsOf: latest, encoding: .utf8) {
        let lines = Array(text.split(separator: "\n").suffix(10_000)).map(String.init)
        let result = CodexLogParser.parseRecentLines(lines)
        print("Recent tool stats:")
        print("- terminal commands: \(result.toolStats.terminalCommands)")
        print("- file changes: \(result.toolStats.fileChanges)")
        print("- write_stdin: \(result.toolStats.writeStdin)")
        print("- other: \(result.toolStats.other)")
        print("- total: \(result.toolStats.total)")
    }
case "diagnose-quota":
    do {
        let quota = try await CodexQuotaFetcher.fetch()
        print("Codex quota:")
        print("- 5 小时剩余：\(quota.quota5hRemainingPercent.map(String.init) ?? AppStrings.Diagnostics.unknown)%")
        print("- 5 小时重置：\(quota.quota5hResetAt.map { quotaDateFormatter.string(from: $0) } ?? AppStrings.Diagnostics.unknown)")
        print("- 5 小时窗口秒数：\(quota.quota5hWindowSeconds.map(String.init) ?? AppStrings.Diagnostics.unknown)")
        print("- 本周剩余：\(quota.quotaWeekRemainingPercent.map(String.init) ?? AppStrings.Diagnostics.unknown)%")
        print("- 本周重置：\(quota.quotaWeekResetAt.map { quotaDateFormatter.string(from: $0) } ?? AppStrings.Diagnostics.unknown)")
        print("- 本周窗口秒数：\(quota.quotaWeekWindowSeconds.map(String.init) ?? AppStrings.Diagnostics.unknown)")
    } catch {
        print("Codex quota fetch failed: \(error.localizedDescription)")
        Foundation.exit(1)
    }
case "diagnose-quota-raw":
    do {
        print(try await CodexQuotaFetcher.fetchDebugDescription())
    } catch {
        print("Codex quota debug failed: \(error.localizedDescription)")
        Foundation.exit(1)
    }
case "scan-usage":
    let settings = JSONFileStore<AgentPulseSettings>(url: paths.settings).load(default: AgentPulseSettings())
    let root = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/sessions")
    let scan = CodexUsageScanner.scanDailyTokens(
        root: root,
        options: CodexUsageScanner.Options(
            estimateInternalModelCost: settings.estimateCodexInternalCost,
            internalCostPerMillionTokens: settings.codexInternalCostPerMillionTokens
        ),
        cache: nil
    )
    let total = scan.daily.reduce(0) { $0 + $1.tokens }
    let totalCost = scan.daily.compactMap(\.cost).reduce(Decimal(0), +)
    let modelTotal = max(scan.models.reduce(0) { $0 + $1.tokens }, 1)
    let input = scan.models.reduce(0) { $0 + $1.inputTokens }
    let cached = scan.models.reduce(0) { $0 + $1.cachedInputTokens }
    let output = scan.models.reduce(0) { $0 + $1.outputTokens }
    print("Codex usage scan:")
    print("- scanned at: \(quotaDateFormatter.string(from: Date()))")
    print("- 30d tokens: \(total)")
    print("- 30d cost: \(money(totalCost))")
    print("- input/cached/output: \(input) / \(cached) / \(output)")
    print("- daily rows: \(scan.daily.count)")
    print("- recent days:")
    for item in scan.daily.suffix(5) {
        print("  - \(item.date): \(item.tokens) tokens · \(money(item.cost))")
    }
    print("- models:")
    if scan.models.isEmpty {
        print("  - \(AppStrings.Diagnostics.unknown)")
    } else {
        for item in scan.models.prefix(8) {
            let percent = Int((Double(item.tokens) / Double(modelTotal) * 100).rounded())
            print("  - \(item.model): \(item.tokens) tokens · \(percent)% · \(money(item.cost))")
        }
    }
	default:
	    print("""
	    AgentPulse CLI

	    Commands:
	      diagnose-codex        Print observed Codex payload.type values
	      diagnose-quota        Fetch Codex WHAM quota from local auth
	      diagnose-quota-raw    Print redacted WHAM window parse details
	      diagnostics           输出本地状态、来源、用量和额度摘要
	      doctor                Run a quick health check for sessions, usage, status, and UI settings
	      scan-usage            Scan Codex sessions and print daily/model usage
	      status                Print current AgentPulse state
	      set                   Write a local agent state
	      reset-window          Reset saved floating window position
	      reset-usage-cache     Clear cached usage scan results
	    """)
}

private func todayKey() -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: Date())
}

private func money(_ value: Decimal?) -> String {
    guard let value else { return "待确认" }
    return moneyFormatter.string(from: value as NSDecimalNumber) ?? "$0.00"
}

private func check(_ passed: Bool, _ title: String, _ detail: String) -> String {
    "\(passed ? "OK" : "WARN")  \(title): \(detail.isEmpty ? "无数据" : detail)"
}

private func liveCodexStatus(in root: URL, settings: AgentPulseSettings) -> (file: URL, result: CodexParseResult, age: TimeInterval)? {
    recentCodexJSONLs(in: root, limit: 8)
        .compactMap { file -> (file: URL, result: CodexParseResult, age: TimeInterval)? in
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
            let lines = Array(text.split(separator: "\n").suffix(10_000)).map(String.init)
            guard !lines.isEmpty else { return nil }
            let result = CodexLogParser.parseRecentLines(lines)
            let age = result.lastMeaningfulEventAt.map { Date().timeIntervalSince($0) } ?? latestModificationAge(file)
            return (file, result, age)
        }
        .max { left, right in
            let leftScore = freshnessScore(signal: left.result.signal, age: left.age, settings: settings)
            let rightScore = freshnessScore(signal: right.result.signal, age: right.age, settings: settings)
            if leftScore == rightScore {
                return (latestModificationDate(left.file) ?? .distantPast) < (latestModificationDate(right.file) ?? .distantPast)
            }
            return leftScore < rightScore
        }
}

private func freshnessScore(signal: AgentSignal, age: TimeInterval, settings: AgentPulseSettings) -> Int {
    let activeWindow: TimeInterval = signal == .done ? TimeInterval(settings.doneHoldSeconds) : 180
    guard age <= activeWindow else { return 0 }
    return signal.priority
}

private func statusReason(file: URL, signal: AgentSignal, age: TimeInterval) -> String {
    let seconds = max(0, Int(age))
    let ageText = seconds < 60 ? "\(seconds) 秒前" : "\(seconds / 60) 分钟前"
    return "来自 \(file.lastPathComponent) · \(signal.title) 优先级 · \(ageText)"
}

private func latestCodexJSONL(in root: URL) -> URL? {
    recentCodexJSONLs(in: root, limit: 1).first
}

private func recentCodexJSONLs(in root: URL, limit: Int) -> [URL] {
    candidateCodexSessionFiles(root: root, days: 7)
        .filter { $0.pathExtension == "jsonl" && $0.lastPathComponent.hasPrefix("rollout-") }
        .sorted {
            (latestModificationDate($0) ?? .distantPast) > (latestModificationDate($1) ?? .distantPast)
        }
        .prefix(limit)
        .map { $0 }
}

private func candidateCodexSessionFiles(root: URL, days: Int) -> [URL] {
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

private func latestModificationDate(_ url: URL) -> Date? {
    try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
}

private func latestModificationAge(_ url: URL) -> TimeInterval {
    Date().timeIntervalSince(latestModificationDate(url) ?? .distantPast)
}
