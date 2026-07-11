import Foundation

public enum AgentKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case codex
    case claude
    case local

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        case .local: "本地脚本"
        }
    }
}

public enum AgentSignal: String, Codable, CaseIterable, Identifiable, Comparable, Sendable {
    case idle
    case done
    case thinking
    case working
    case attention

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .idle: "空闲"
        case .thinking: "思考中"
        case .working: "执行中"
        case .done: "已完成"
        case .attention: "需处理"
        }
    }

    public var priority: Int {
        switch self {
        case .idle: 0
        case .done: 1
        case .thinking: 2
        case .working: 3
        case .attention: 4
        }
    }

    public static func < (lhs: AgentSignal, rhs: AgentSignal) -> Bool {
        lhs.priority < rhs.priority
    }
}

public struct ToolStats: Codable, Equatable, Sendable {
    public var terminalCommands: Int
    public var readOperations: Int
    public var fileChanges: Int
    public var writeStdin: Int
    public var searchOperations: Int
    public var webRequests: Int
    public var other: Int

    public init(
        terminalCommands: Int = 0,
        readOperations: Int = 0,
        fileChanges: Int = 0,
        writeStdin: Int = 0,
        searchOperations: Int = 0,
        webRequests: Int = 0,
        other: Int = 0
    ) {
        self.terminalCommands = terminalCommands
        self.readOperations = readOperations
        self.fileChanges = fileChanges
        self.writeStdin = writeStdin
        self.searchOperations = searchOperations
        self.webRequests = webRequests
        self.other = other
    }

    public var total: Int {
        terminalCommands + readOperations + fileChanges + writeStdin + searchOperations + webRequests + other
    }

    public mutating func add(_ other: ToolStats) {
        terminalCommands += other.terminalCommands
        readOperations += other.readOperations
        fileChanges += other.fileChanges
        writeStdin += other.writeStdin
        searchOperations += other.searchOperations
        webRequests += other.webRequests
        self.other += other.other
    }

    enum CodingKeys: String, CodingKey {
        case terminalCommands
        case readOperations
        case fileChanges
        case writeStdin
        case searchOperations
        case webRequests
        case other
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        terminalCommands = try container.decodeIfPresent(Int.self, forKey: .terminalCommands) ?? 0
        readOperations = try container.decodeIfPresent(Int.self, forKey: .readOperations) ?? 0
        fileChanges = try container.decodeIfPresent(Int.self, forKey: .fileChanges) ?? 0
        writeStdin = try container.decodeIfPresent(Int.self, forKey: .writeStdin) ?? 0
        searchOperations = try container.decodeIfPresent(Int.self, forKey: .searchOperations) ?? 0
        webRequests = try container.decodeIfPresent(Int.self, forKey: .webRequests) ?? 0
        other = try container.decodeIfPresent(Int.self, forKey: .other) ?? 0
    }
}

public struct AgentPulseHealthCheck: Identifiable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case ok
        case warning

        public var title: String {
            switch self {
            case .ok: "正常"
            case .warning: "需检查"
            }
        }
    }

    public var id: String { title }
    public var title: String
    public var detail: String
    public var status: Status

    public init(title: String, detail: String, status: Status) {
        self.title = title
        self.detail = detail
        self.status = status
    }
}

public struct UsageSnapshot: Codable, Equatable, Sendable {
    public struct DailyTokenUsage: Codable, Equatable, Identifiable, Sendable {
        public var id: String { date }
        public var date: String
        public var tokens: Int
        public var cost: Decimal?

        public init(date: String, tokens: Int, cost: Decimal? = nil) {
            self.date = date
            self.tokens = tokens
            self.cost = cost
        }
    }

    public struct ModelTokenUsage: Codable, Equatable, Identifiable, Sendable {
        public var id: String { model }
        public var model: String
        public var tokens: Int
        public var inputTokens: Int
        public var cachedInputTokens: Int
        public var outputTokens: Int
        public var cost: Decimal?

        public init(
            model: String,
            tokens: Int,
            inputTokens: Int = 0,
            cachedInputTokens: Int = 0,
            outputTokens: Int = 0,
            cost: Decimal? = nil
        ) {
            self.model = model
            self.tokens = tokens
            self.inputTokens = inputTokens
            self.cachedInputTokens = cachedInputTokens
            self.outputTokens = outputTokens
            self.cost = cost
        }
    }

    public struct JournalEntry: Codable, Equatable, Identifiable, Sendable {
        public var id: String
        public var startedAt: Date
        public var endedAt: Date
        public var durationSeconds: TimeInterval
        public var tokens: Int
        public var cost: Decimal?
        public var sourcePath: String
        public var model: String?

        public init(id: String, startedAt: Date, endedAt: Date, tokens: Int, cost: Decimal? = nil, sourcePath: String, model: String? = nil) {
            self.id = id
            self.startedAt = startedAt
            self.endedAt = endedAt
            self.durationSeconds = max(0, endedAt.timeIntervalSince(startedAt))
            self.tokens = tokens
            self.cost = cost
            self.sourcePath = sourcePath
            self.model = model
        }
    }

    public var todayCost: Decimal?
    public var todayTokens: Int?
    public var thirtyDayCost: Decimal?
    public var thirtyDayTokens: Int?
    public var quota5hRemainingPercent: Int?
    public var quotaWeekRemainingPercent: Int?
    public var monthlyBudget: Decimal?
    public var dailyTokenUsage: [DailyTokenUsage]
    public var modelTokenUsage: [ModelTokenUsage]
    public var currentModel: String?
    public var inputTokens: Int?
    public var cachedInputTokens: Int?
    public var outputTokens: Int?
    public var tokenDataSource: String?
    public var costDataSource: String?
    public var quotaDataSource: String?
    public var quotaUpdatedAt: Date?
    public var quota5hResetAt: Date?
    public var quotaWeekResetAt: Date?
    public var quota5hWindowSeconds: Int?
    public var quotaWeekWindowSeconds: Int?
    public var quotaLastError: String?
    public var quotaLastErrorAt: Date?
    public var scannedFileCount: Int?
    public var usageScannedAt: Date?
    public var latestSessionPath: String?
    public var latestSessionModifiedAt: Date?
    public var activeTimeDate: String?
    public var todayActiveSeconds: TimeInterval
    public var todaySessionCount: Int
    public var currentSessionStartedAt: Date?
    public var lastSessionActivityAt: Date?
    public var sessionCreateReason: String?
    public var todayHourlyActiveSeconds: [TimeInterval]
    public var journalEntries: [JournalEntry]
    public var toolStats: ToolStats
    public var lastActiveIncrementSeconds: TimeInterval
    public var previousSignal: AgentSignal?
    public var lastActiveSignal: AgentSignal?
    public var lastRefreshPreviousSignal: AgentSignal?
    public var lastRefreshCurrentSignal: AgentSignal?
    public var lastRefreshIncrementSeconds: TimeInterval

    enum CodingKeys: String, CodingKey {
        case todayCost
        case todayTokens
        case thirtyDayCost
        case thirtyDayTokens
        case quota5hRemainingPercent
        case quotaWeekRemainingPercent
        case monthlyBudget
        case dailyTokenUsage
        case modelTokenUsage
        case currentModel
        case inputTokens
        case cachedInputTokens
        case outputTokens
        case tokenDataSource
        case costDataSource
        case quotaDataSource
        case quotaUpdatedAt
        case quota5hResetAt
        case quotaWeekResetAt
        case quota5hWindowSeconds
        case quotaWeekWindowSeconds
        case quotaLastError
        case quotaLastErrorAt
        case scannedFileCount
        case usageScannedAt
        case latestSessionPath
        case latestSessionModifiedAt
        case activeTimeDate
        case todayActiveSeconds
        case todaySessionCount
        case currentSessionStartedAt
        case lastSessionActivityAt
        case sessionCreateReason
        case todayHourlyActiveSeconds
        case journalEntries
        case toolStats
        case lastActiveIncrementSeconds
        case previousSignal
        case lastActiveSignal
        case lastRefreshPreviousSignal
        case lastRefreshCurrentSignal
        case lastRefreshIncrementSeconds
    }

    public init(
        todayCost: Decimal? = nil,
        todayTokens: Int? = nil,
        thirtyDayCost: Decimal? = nil,
        thirtyDayTokens: Int? = nil,
        quota5hRemainingPercent: Int? = nil,
        quotaWeekRemainingPercent: Int? = nil,
        monthlyBudget: Decimal? = nil,
        dailyTokenUsage: [DailyTokenUsage] = [],
        modelTokenUsage: [ModelTokenUsage] = [],
        currentModel: String? = nil,
        inputTokens: Int? = nil,
        cachedInputTokens: Int? = nil,
        outputTokens: Int? = nil,
        tokenDataSource: String? = nil,
        costDataSource: String? = nil,
        quotaDataSource: String? = nil,
        quotaUpdatedAt: Date? = nil,
        quota5hResetAt: Date? = nil,
        quotaWeekResetAt: Date? = nil,
        quota5hWindowSeconds: Int? = nil,
        quotaWeekWindowSeconds: Int? = nil,
        quotaLastError: String? = nil,
        quotaLastErrorAt: Date? = nil,
        scannedFileCount: Int? = nil,
        usageScannedAt: Date? = nil,
        latestSessionPath: String? = nil,
        latestSessionModifiedAt: Date? = nil,
        activeTimeDate: String? = nil,
        todayActiveSeconds: TimeInterval = 0,
        todaySessionCount: Int = 0,
        currentSessionStartedAt: Date? = nil,
        lastSessionActivityAt: Date? = nil,
        sessionCreateReason: String? = nil,
        todayHourlyActiveSeconds: [TimeInterval] = Array(repeating: 0, count: 24),
        journalEntries: [JournalEntry] = [],
        toolStats: ToolStats = ToolStats(),
        lastActiveIncrementSeconds: TimeInterval = 0,
        previousSignal: AgentSignal? = nil,
        lastActiveSignal: AgentSignal? = nil,
        lastRefreshPreviousSignal: AgentSignal? = nil,
        lastRefreshCurrentSignal: AgentSignal? = nil,
        lastRefreshIncrementSeconds: TimeInterval = 0
    ) {
        self.todayCost = todayCost
        self.todayTokens = todayTokens
        self.thirtyDayCost = thirtyDayCost
        self.thirtyDayTokens = thirtyDayTokens
        self.quota5hRemainingPercent = quota5hRemainingPercent
        self.quotaWeekRemainingPercent = quotaWeekRemainingPercent
        self.monthlyBudget = monthlyBudget
        self.dailyTokenUsage = dailyTokenUsage
        self.modelTokenUsage = modelTokenUsage
        self.currentModel = currentModel
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.tokenDataSource = tokenDataSource
        self.costDataSource = costDataSource
        self.quotaDataSource = quotaDataSource
        self.quotaUpdatedAt = quotaUpdatedAt
        self.quota5hResetAt = quota5hResetAt
        self.quotaWeekResetAt = quotaWeekResetAt
        self.quota5hWindowSeconds = quota5hWindowSeconds
        self.quotaWeekWindowSeconds = quotaWeekWindowSeconds
        self.quotaLastError = quotaLastError
        self.quotaLastErrorAt = quotaLastErrorAt
        self.scannedFileCount = scannedFileCount
        self.usageScannedAt = usageScannedAt
        self.latestSessionPath = latestSessionPath
        self.latestSessionModifiedAt = latestSessionModifiedAt
        self.activeTimeDate = activeTimeDate
        self.todayActiveSeconds = todayActiveSeconds
        self.todaySessionCount = todaySessionCount
        self.currentSessionStartedAt = currentSessionStartedAt
        self.lastSessionActivityAt = lastSessionActivityAt
        self.sessionCreateReason = sessionCreateReason
        self.todayHourlyActiveSeconds = Self.normalizedHourlyActiveSeconds(todayHourlyActiveSeconds)
        self.journalEntries = journalEntries
        self.toolStats = toolStats
        self.lastActiveIncrementSeconds = lastActiveIncrementSeconds
        self.previousSignal = previousSignal
        self.lastActiveSignal = lastActiveSignal
        self.lastRefreshPreviousSignal = lastRefreshPreviousSignal
        self.lastRefreshCurrentSignal = lastRefreshCurrentSignal
        self.lastRefreshIncrementSeconds = lastRefreshIncrementSeconds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        todayCost = try container.decodeIfPresent(Decimal.self, forKey: .todayCost)
        todayTokens = try container.decodeIfPresent(Int.self, forKey: .todayTokens)
        thirtyDayCost = try container.decodeIfPresent(Decimal.self, forKey: .thirtyDayCost)
        thirtyDayTokens = try container.decodeIfPresent(Int.self, forKey: .thirtyDayTokens)
        quota5hRemainingPercent = try container.decodeIfPresent(Int.self, forKey: .quota5hRemainingPercent)
        quotaWeekRemainingPercent = try container.decodeIfPresent(Int.self, forKey: .quotaWeekRemainingPercent)
        monthlyBudget = try container.decodeIfPresent(Decimal.self, forKey: .monthlyBudget)
        dailyTokenUsage = try container.decodeIfPresent([DailyTokenUsage].self, forKey: .dailyTokenUsage) ?? []
        modelTokenUsage = try container.decodeIfPresent([ModelTokenUsage].self, forKey: .modelTokenUsage) ?? []
        currentModel = try container.decodeIfPresent(String.self, forKey: .currentModel)
        inputTokens = try container.decodeIfPresent(Int.self, forKey: .inputTokens)
        cachedInputTokens = try container.decodeIfPresent(Int.self, forKey: .cachedInputTokens)
        outputTokens = try container.decodeIfPresent(Int.self, forKey: .outputTokens)
        tokenDataSource = try container.decodeIfPresent(String.self, forKey: .tokenDataSource)
        costDataSource = try container.decodeIfPresent(String.self, forKey: .costDataSource)
        quotaDataSource = try container.decodeIfPresent(String.self, forKey: .quotaDataSource)
        quotaUpdatedAt = try container.decodeIfPresent(Date.self, forKey: .quotaUpdatedAt)
        quota5hResetAt = try container.decodeIfPresent(Date.self, forKey: .quota5hResetAt)
        quotaWeekResetAt = try container.decodeIfPresent(Date.self, forKey: .quotaWeekResetAt)
        quota5hWindowSeconds = try container.decodeIfPresent(Int.self, forKey: .quota5hWindowSeconds)
        quotaWeekWindowSeconds = try container.decodeIfPresent(Int.self, forKey: .quotaWeekWindowSeconds)
        quotaLastError = try container.decodeIfPresent(String.self, forKey: .quotaLastError)
        quotaLastErrorAt = try container.decodeIfPresent(Date.self, forKey: .quotaLastErrorAt)
        scannedFileCount = try container.decodeIfPresent(Int.self, forKey: .scannedFileCount)
        usageScannedAt = try container.decodeIfPresent(Date.self, forKey: .usageScannedAt)
        latestSessionPath = try container.decodeIfPresent(String.self, forKey: .latestSessionPath)
        latestSessionModifiedAt = try container.decodeIfPresent(Date.self, forKey: .latestSessionModifiedAt)
        activeTimeDate = try container.decodeIfPresent(String.self, forKey: .activeTimeDate)
        todayActiveSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .todayActiveSeconds) ?? 0
        todaySessionCount = try container.decodeIfPresent(Int.self, forKey: .todaySessionCount) ?? 0
        currentSessionStartedAt = try container.decodeIfPresent(Date.self, forKey: .currentSessionStartedAt)
        lastSessionActivityAt = try container.decodeIfPresent(Date.self, forKey: .lastSessionActivityAt)
        sessionCreateReason = try container.decodeIfPresent(String.self, forKey: .sessionCreateReason)
        todayHourlyActiveSeconds = Self.normalizedHourlyActiveSeconds(
            try container.decodeIfPresent([TimeInterval].self, forKey: .todayHourlyActiveSeconds) ?? []
        )
        journalEntries = try container.decodeIfPresent([JournalEntry].self, forKey: .journalEntries) ?? []
        toolStats = try container.decodeIfPresent(ToolStats.self, forKey: .toolStats) ?? ToolStats()
        lastActiveIncrementSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .lastActiveIncrementSeconds) ?? 0
        previousSignal = try container.decodeIfPresent(AgentSignal.self, forKey: .previousSignal)
        lastActiveSignal = try container.decodeIfPresent(AgentSignal.self, forKey: .lastActiveSignal)
        lastRefreshPreviousSignal = try container.decodeIfPresent(AgentSignal.self, forKey: .lastRefreshPreviousSignal)
        lastRefreshCurrentSignal = try container.decodeIfPresent(AgentSignal.self, forKey: .lastRefreshCurrentSignal)
        lastRefreshIncrementSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .lastRefreshIncrementSeconds) ?? 0
    }

    private static func normalizedHourlyActiveSeconds(_ values: [TimeInterval]) -> [TimeInterval] {
        if values.count == 24 { return values }
        if values.count > 24 { return Array(values.prefix(24)) }
        return values + Array(repeating: 0, count: 24 - values.count)
    }
}

public struct AgentEvent: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var date: Date
    public var kind: AgentKind
    public var signal: AgentSignal
    public var message: String

    public init(id: UUID = UUID(), date: Date = Date(), kind: AgentKind, signal: AgentSignal, message: String) {
        self.id = id
        self.date = date
        self.kind = kind
        self.signal = signal
        self.message = message
    }
}

public struct AgentSnapshot: Codable, Identifiable, Equatable, Sendable {
    public var id: AgentKind { kind }
    public var kind: AgentKind
    public var signal: AgentSignal
    public var currentCommand: String?
    public var statusReason: String?
    public var updatedAt: Date
    public var hookInstalled: Bool
    public var usage: UsageSnapshot
    public var toolStats: ToolStats
    public var recentEvents: [AgentEvent]

    public init(
        kind: AgentKind,
        signal: AgentSignal = .idle,
        currentCommand: String? = nil,
        statusReason: String? = nil,
        updatedAt: Date = Date(),
        hookInstalled: Bool = false,
        usage: UsageSnapshot = UsageSnapshot(),
        toolStats: ToolStats = ToolStats(),
        recentEvents: [AgentEvent] = []
    ) {
        self.kind = kind
        self.signal = signal
        self.currentCommand = currentCommand
        self.statusReason = statusReason
        self.updatedAt = updatedAt
        self.hookInstalled = hookInstalled
        self.usage = usage
        self.toolStats = toolStats
        self.recentEvents = recentEvents
    }
}

public struct AgentPulseSettings: Codable, Equatable, Sendable {
    public enum Theme: String, Codable, CaseIterable, Identifiable, Sendable {
        case system
        case light
        case dark

        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .system: "跟随系统"
            case .light: "浅色"
            case .dark: "深色"
            }
        }
    }

    public enum GlassIntensity: String, Codable, CaseIterable, Identifiable, Sendable {
        case standard
        case enhanced

        public var id: String { rawValue }
        public var title: String { self == .standard ? "标准" : "增强" }
    }

    public enum SoundVolume: String, Codable, CaseIterable, Identifiable, Sendable {
        case low
        case medium
        case high

        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .low: "低"
            case .medium: "中"
            case .high: "高"
            }
        }

        public var level: Float {
            switch self {
            case .low: 0.25
            case .medium: 0.55
            case .high: 0.9
            }
        }
    }

    public var theme: Theme
    public var glassEnabled: Bool
    public var glassIntensity: GlassIntensity
    public var privacyMode: Bool
    public var doneSoundEnabled: Bool
    public var attentionSoundEnabled: Bool
    public var soundVolume: SoundVolume
    public var showStatusBarIcon: Bool
    public var showFloatingWindow: Bool
    public var codexMonitoringEnabled: Bool
    public var claudeMonitoringEnabled: Bool
    public var launchAtLogin: Bool
    public var monitoringPaused: Bool
    public var doneHoldSeconds: Int
    public var monthlyBudget: Decimal
    public var estimateCodexInternalCost: Bool
    public var codexInternalCostPerMillionTokens: Decimal
    public var codexQuota5hTokenBudget: Int
    public var codexQuotaWeekTokenBudget: Int

    enum CodingKeys: String, CodingKey {
        case theme
        case glassEnabled
        case glassIntensity
        case privacyMode
        case doneSoundEnabled
        case attentionSoundEnabled
        case soundVolume
        case showStatusBarIcon
        case showFloatingWindow
        case codexMonitoringEnabled
        case claudeMonitoringEnabled
        case launchAtLogin
        case monitoringPaused
        case doneHoldSeconds
        case monthlyBudget
        case estimateCodexInternalCost
        case codexInternalCostPerMillionTokens
        case codexQuota5hTokenBudget
        case codexQuotaWeekTokenBudget
    }

    public init(
        theme: Theme = .system,
        glassEnabled: Bool = true,
        glassIntensity: GlassIntensity = .standard,
        privacyMode: Bool = false,
        doneSoundEnabled: Bool = true,
        attentionSoundEnabled: Bool = true,
        soundVolume: SoundVolume = .medium,
        showStatusBarIcon: Bool = true,
        showFloatingWindow: Bool = true,
        codexMonitoringEnabled: Bool = true,
        claudeMonitoringEnabled: Bool = false,
        launchAtLogin: Bool = true,
        monitoringPaused: Bool = false,
        doneHoldSeconds: Int = 30,
        monthlyBudget: Decimal = 100,
        estimateCodexInternalCost: Bool = true,
        codexInternalCostPerMillionTokens: Decimal = 0.75,
        codexQuota5hTokenBudget: Int = 50_000_000,
        codexQuotaWeekTokenBudget: Int = 500_000_000
    ) {
        self.theme = theme
        self.glassEnabled = glassEnabled
        self.glassIntensity = glassIntensity
        self.privacyMode = privacyMode
        self.doneSoundEnabled = doneSoundEnabled
        self.attentionSoundEnabled = attentionSoundEnabled
        self.soundVolume = soundVolume
        self.showStatusBarIcon = showStatusBarIcon
        self.showFloatingWindow = showFloatingWindow
        self.codexMonitoringEnabled = codexMonitoringEnabled
        self.claudeMonitoringEnabled = claudeMonitoringEnabled
        self.launchAtLogin = launchAtLogin
        self.monitoringPaused = monitoringPaused
        self.doneHoldSeconds = doneHoldSeconds
        self.monthlyBudget = monthlyBudget
        self.estimateCodexInternalCost = estimateCodexInternalCost
        self.codexInternalCostPerMillionTokens = codexInternalCostPerMillionTokens
        self.codexQuota5hTokenBudget = codexQuota5hTokenBudget
        self.codexQuotaWeekTokenBudget = codexQuotaWeekTokenBudget
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        theme = try container.decodeIfPresent(Theme.self, forKey: .theme) ?? .system
        glassEnabled = try container.decodeIfPresent(Bool.self, forKey: .glassEnabled) ?? true
        glassIntensity = try container.decodeIfPresent(GlassIntensity.self, forKey: .glassIntensity) ?? .standard
        privacyMode = try container.decodeIfPresent(Bool.self, forKey: .privacyMode) ?? false
        doneSoundEnabled = try container.decodeIfPresent(Bool.self, forKey: .doneSoundEnabled) ?? true
        attentionSoundEnabled = try container.decodeIfPresent(Bool.self, forKey: .attentionSoundEnabled) ?? true
        soundVolume = try container.decodeIfPresent(SoundVolume.self, forKey: .soundVolume) ?? .medium
        showStatusBarIcon = try container.decodeIfPresent(Bool.self, forKey: .showStatusBarIcon) ?? true
        showFloatingWindow = try container.decodeIfPresent(Bool.self, forKey: .showFloatingWindow) ?? true
        codexMonitoringEnabled = try container.decodeIfPresent(Bool.self, forKey: .codexMonitoringEnabled) ?? true
        claudeMonitoringEnabled = try container.decodeIfPresent(Bool.self, forKey: .claudeMonitoringEnabled) ?? false
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? true
        monitoringPaused = try container.decodeIfPresent(Bool.self, forKey: .monitoringPaused) ?? false
        doneHoldSeconds = try container.decodeIfPresent(Int.self, forKey: .doneHoldSeconds) ?? 30
        monthlyBudget = try container.decodeIfPresent(Decimal.self, forKey: .monthlyBudget) ?? 100
        estimateCodexInternalCost = try container.decodeIfPresent(Bool.self, forKey: .estimateCodexInternalCost) ?? true
        codexInternalCostPerMillionTokens = try container.decodeIfPresent(Decimal.self, forKey: .codexInternalCostPerMillionTokens) ?? 0.75
        codexQuota5hTokenBudget = try container.decodeIfPresent(Int.self, forKey: .codexQuota5hTokenBudget) ?? 50_000_000
        codexQuotaWeekTokenBudget = try container.decodeIfPresent(Int.self, forKey: .codexQuotaWeekTokenBudget) ?? 500_000_000
    }
}
