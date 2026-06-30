import SwiftUI
import AppKit
import Combine
import ServiceManagement
import AgentPulseCore
import AgentPulseUI

@main
struct AgentPulseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = AgentPulseStore()
    private var statusItem: NSStatusItem?
    private var floatingPanelController: FloatingPanelController?
    private var settingsWindowController: NSWindowController?
    private var cancellables: Set<AnyCancellable> = []
    private var lastSignals: [AgentKind: AgentSignal] = [:]
    private var lastLaunchAtLogin: Bool?
    private var lastPresentationKey: PresentationKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NotificationCenter.default.addObserver(self, selector: #selector(openSettings), name: .agentPulseOpenSettings, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(showFloatingWindow), name: .agentPulseResetFloatingWindow, object: nil)
        store.start()
        lastSignals = Dictionary(uniqueKeysWithValues: store.agents.map { ($0.kind, $0.signal) })
        lastLaunchAtLogin = store.settings.launchAtLogin
        applyPresentationSettings()
        applyLoginItemSetting()
        store.$settings
            .receive(on: RunLoop.main)
            .sink { [weak self] settings in
                self?.updateSettingsWindowMaterial(settings)
                self?.applySettingsWindowAppearance(settings)
                self?.applyPresentationSettingsIfNeeded(settings)
                if self?.lastLaunchAtLogin != settings.launchAtLogin {
                    self?.lastLaunchAtLogin = settings.launchAtLogin
                    self?.applyLoginItemSetting()
                }
            }
            .store(in: &cancellables)
        store.$agents
            .receive(on: RunLoop.main)
            .sink { [weak self] agents in
                self?.playSoundsForSignalTransitions(agents)
            }
            .store(in: &cancellables)
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.stop()
        store.persist()
    }

    private func setupStatusItem() {
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
        guard store.settings.showStatusBarIcon else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: "AgentPulse")
        let menu = NSMenu()
        let header = NSMenuItem(title: menuStatusTitle, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for line in menuUsageLines {
            let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "偏好设置…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let resetWindow = NSMenuItem(title: "显示/重置悬浮窗", action: #selector(showFloatingWindow), keyEquivalent: "")
        resetWindow.target = self
        menu.addItem(resetWindow)
        let pause = NSMenuItem(title: store.settings.monitoringPaused ? "恢复监控" : "暂停监控", action: #selector(toggleMonitoring), keyEquivalent: "")
        pause.target = self
        menu.addItem(pause)
        let refreshQuota = NSMenuItem(title: store.isRefreshingCodexQuota ? "额度刷新中…" : "刷新额度", action: #selector(refreshQuotaNow), keyEquivalent: "")
        refreshQuota.target = self
        refreshQuota.isEnabled = !store.isRefreshingCodexQuota
        menu.addItem(refreshQuota)
        let refreshUsage = NSMenuItem(title: store.isRefreshingUsage ? "用量刷新中…" : "刷新用量", action: #selector(refreshUsageNow), keyEquivalent: "")
        refreshUsage.target = self
        refreshUsage.isEnabled = !store.isRefreshingUsage
        menu.addItem(refreshUsage)
        let copyDiagnostics = NSMenuItem(title: "复制诊断摘要", action: #selector(copyDiagnostics), keyEquivalent: "")
        copyDiagnostics.target = self
        menu.addItem(copyDiagnostics)
        let exportDiagnostics = NSMenuItem(title: "导出诊断摘要", action: #selector(exportDiagnostics), keyEquivalent: "")
        exportDiagnostics.target = self
        menu.addItem(exportDiagnostics)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 AgentPulse", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
    }

    private var menuStatusTitle: String {
        if store.settings.monitoringPaused { return "AgentPulse · 监控已暂停" }
        return "AgentPulse · " + store.visibleAgents.map { "\($0.kind.displayName) \($0.signal.title)" }.joined(separator: " / ")
    }

    private var menuUsageLines: [String] {
        guard let codex = store.agents.first(where: { $0.kind == .codex }) else { return [] }
        let today = AgentPulseFormatters.tokens(codex.usage.todayTokens)
        let fiveHour = codex.usage.quota5hRemainingPercent.map { "\($0)%" } ?? "unknown"
        let week = codex.usage.quotaWeekRemainingPercent.map { "\($0)%" } ?? "unknown"
        return [
            "今日 \(today)",
            "额度 5小时 \(fiveHour) · 本周 \(week)"
        ]
    }

    private func applyPresentationSettings() {
        lastPresentationKey = PresentationKey(settings: store.settings)
        setupStatusItem()
        if store.settings.showFloatingWindow {
            if floatingPanelController == nil {
                floatingPanelController = FloatingPanelController(store: store)
            }
            floatingPanelController?.show()
        } else {
            floatingPanelController?.hide()
        }
    }

    private func applyPresentationSettingsIfNeeded(_ settings: AgentPulseSettings) {
        let key = PresentationKey(settings: settings)
        guard key != lastPresentationKey else { return }
        applyPresentationSettings()
    }

    private func applyLoginItemSetting() {
        guard #available(macOS 13.0, *) else {
            UserDefaults.standard.set("当前系统不支持自动同步登录项", forKey: "loginItem.lastStatus")
            return
        }
        do {
            if store.settings.launchAtLogin {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
            UserDefaults.standard.set("同步成功：\(loginItemStatusDescription())", forKey: "loginItem.lastStatus")
        } catch {
            UserDefaults.standard.set("同步失败：\(error.localizedDescription)", forKey: "loginItem.lastStatus")
        }
    }

    private func playSoundsForSignalTransitions(_ agents: [AgentSnapshot]) {
        defer {
            lastSignals = Dictionary(uniqueKeysWithValues: agents.map { ($0.kind, $0.signal) })
        }
        guard !lastSignals.isEmpty, !store.settings.monitoringPaused else { return }
        for agent in agents {
            let previous = lastSignals[agent.kind]
            guard previous != agent.signal else { continue }
            switch agent.signal {
            case .done where store.settings.doneSoundEnabled:
                AgentPulseSoundPlayer.play(.done, volume: store.settings.soundVolume)
            case .attention where store.settings.attentionSoundEnabled:
                AgentPulseSoundPlayer.play(.attention, volume: store.settings.soundVolume)
            default:
                break
            }
        }
    }

    @available(macOS 13.0, *)
    private func loginItemStatusDescription() -> String {
        switch SMAppService.mainApp.status {
        case .enabled: "已启用"
        case .requiresApproval: "需要批准"
        case .notRegistered: "未注册"
        case .notFound: "当前构建不可用"
        @unknown default: "未知"
        }
    }

    @objc private func openSettings() {
        if settingsWindowController == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 860, height: 590),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "AgentPulse 偏好设置"
            window.center()
            window.contentView = VisualEffectHostingView(rootView: SettingsWindowView(store: store), settings: store.settings)
            settingsWindowController = NSWindowController(window: window)
            applySettingsWindowAppearance(store.settings)
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindowController?.showWindow(nil)
    }

    @objc private func toggleMonitoring() {
        store.setPaused(!store.settings.monitoringPaused)
        setupStatusItem()
    }

    @objc private func showFloatingWindow() {
        var copy = store.settings
        copy.showFloatingWindow = true
        store.updateSettings(copy)
        if floatingPanelController == nil {
            floatingPanelController = FloatingPanelController(store: store)
        }
        floatingPanelController?.resetPosition()
        floatingPanelController?.show()
    }

    @objc private func refreshQuotaNow() {
        store.refreshCodexQuotaNow()
        setupStatusItem()
    }

    @objc private func refreshUsageNow() {
        store.refreshUsageNow()
        setupStatusItem()
    }

    @objc private func copyDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(store.diagnosticSummary(), forType: .string)
    }

    @objc private func exportDiagnostics() {
        let paths = AppStoragePaths()
        do {
            try FileManager.default.createDirectory(at: paths.logs, withIntermediateDirectories: true)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let url = paths.logs.appendingPathComponent("diagnostics-\(formatter.string(from: Date())).txt")
            try store.diagnosticSummary().write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("导出诊断失败：\(error.localizedDescription)", forType: .string)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func updateSettingsWindowMaterial(_ settings: AgentPulseSettings) {
        guard let view = settingsWindowController?.window?.contentView as? AnyVisualEffectHostingView else { return }
        view.apply(settings: settings)
    }

    private func applySettingsWindowAppearance(_ settings: AgentPulseSettings) {
        guard let window = settingsWindowController?.window else { return }
        switch settings.theme {
        case .system:
            window.appearance = nil
        case .light:
            window.appearance = NSAppearance(named: .aqua)
        case .dark:
            window.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

@MainActor
private protocol AnyVisualEffectHostingView: AnyObject {
    func apply(settings: AgentPulseSettings)
}

private final class VisualEffectHostingView<Content: View>: NSView, AnyVisualEffectHostingView {
    private let effectView = NSVisualEffectView()
    private let hostingView: NSHostingView<Content>

    init(rootView: Content, settings: AgentPulseSettings) {
        self.hostingView = NSHostingView(rootView: rootView)
        super.init(frame: .zero)
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.translatesAutoresizingMaskIntoConstraints = false
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(effectView)
        addSubview(hostingView)
        NSLayoutConstraint.activate([
            effectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: trailingAnchor),
            effectView.topAnchor.constraint(equalTo: topAnchor),
            effectView.bottomAnchor.constraint(equalTo: bottomAnchor),
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        apply(settings: settings)
    }

    func apply(settings: AgentPulseSettings) {
        effectView.material = Self.material(for: settings)
    }

    private static func material(for settings: AgentPulseSettings) -> NSVisualEffectView.Material {
        guard settings.glassEnabled else { return .windowBackground }
        switch settings.glassIntensity {
        case .standard:
            return .hudWindow
        case .enhanced:
            return .fullScreenUI
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}

extension Notification.Name {
    static let agentPulseOpenSettings = Notification.Name("AgentPulseOpenSettings")
    static let agentPulseResetFloatingWindow = Notification.Name("AgentPulseResetFloatingWindow")
}

private struct PresentationKey: Equatable {
    var showStatusBarIcon: Bool
    var showFloatingWindow: Bool
    var monitoringPaused: Bool

    init(settings: AgentPulseSettings) {
        self.showStatusBarIcon = settings.showStatusBarIcon
        self.showFloatingWindow = settings.showFloatingWindow
        self.monitoringPaused = settings.monitoringPaused
    }
}

enum AgentPulseSoundKind {
    case done
    case attention
}

@MainActor
enum AgentPulseSoundPlayer {
    private static var activeSounds: [NSSound] = []

    static func play(_ kind: AgentPulseSoundKind, volume: AgentPulseSettings.SoundVolume) {
        let names: [String]
        switch kind {
        case .done:
            names = ["Glass", "Hero", "Ping"]
        case .attention:
            names = ["Basso", "Funk", "Sosumi"]
        }
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
