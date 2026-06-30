import AppKit
import SwiftUI
import AgentPulseCore
import AgentPulseUI

@MainActor
final class FloatingPanelController: NSObject {
    private let store: AgentPulseStore
    private let panel: NSPanel
    private var dragStart: NSPoint?

    init(store: AgentPulseStore) {
        self.store = store
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 392, height: 220),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        super.init()
        configurePanel()
    }

    func show() {
        restorePosition()
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    private func configurePanel() {
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        let hostingView = DraggableHostingView(rootView: FloatingCapsuleStackView(store: store), onDragEnded: { [weak self] in
            self?.snapAndPersist()
        })
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hostingView
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
        panel.setContentSize(NSSize(width: 388, height: 336))

        let menu = NSMenu()
        let settingsItem = NSMenuItem(title: "偏好设置…", action: #selector(openSettings), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)
        let resetItem = NSMenuItem(title: "重置位置", action: #selector(resetPositionFromMenu), keyEquivalent: "")
        resetItem.target = self
        menu.addItem(resetItem)
        let pauseItem = NSMenuItem(title: store.settings.monitoringPaused ? "恢复监控" : "暂停监控", action: #selector(toggleMonitoring), keyEquivalent: "")
        pauseItem.target = self
        menu.addItem(pauseItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出 AgentPulse", action: #selector(quit), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)
        panel.contentView?.menu = menu
    }

    func resetPosition() {
        guard let screen = NSScreen.main else { return }
        let origin = defaultOrigin(on: screen)
        panel.setFrameOrigin(origin)
        persist(origin: origin)
    }

    private func restorePosition() {
        let defaults = UserDefaults.standard
        let x = defaults.double(forKey: "floatingPanel.x")
        let y = defaults.double(forKey: "floatingPanel.y")
        if x != 0 || y != 0 {
            let saved = NSPoint(x: x, y: y)
            if isVisible(origin: saved) {
                panel.setFrameOrigin(saved)
            } else {
                resetPosition()
            }
            return
        }
        resetPosition()
    }

    private func snapAndPersist() {
        guard let screen = panel.screen ?? NSScreen.main else { return }
        var origin = panel.frame.origin
        let screenFrame = screen.visibleFrame
        let margin: CGFloat = 12
        if abs(origin.x - screenFrame.minX) < 48 {
            origin.x = screenFrame.minX + margin
        } else if abs(panel.frame.maxX - screenFrame.maxX) < 48 {
            origin.x = screenFrame.maxX - panel.frame.width - margin
        }
        if abs(origin.y - screenFrame.minY) < 48 {
            origin.y = screenFrame.minY + margin
        } else if abs(panel.frame.maxY - screenFrame.maxY) < 48 {
            origin.y = screenFrame.maxY - panel.frame.height - margin
        }
        panel.setFrameOrigin(origin)
        persist(origin: origin)
    }

    private func defaultOrigin(on screen: NSScreen) -> NSPoint {
        let frame = screen.visibleFrame
        return NSPoint(x: frame.maxX - panel.frame.width - 84, y: frame.maxY - panel.frame.height - 72)
    }

    private func isVisible(origin: NSPoint) -> Bool {
        let candidate = NSRect(origin: origin, size: panel.frame.size)
        return NSScreen.screens.contains { screen in
            screen.visibleFrame.intersects(candidate.insetBy(dx: panel.frame.width * 0.6, dy: panel.frame.height * 0.6))
        }
    }

    private func persist(origin: NSPoint) {
        UserDefaults.standard.set(origin.x, forKey: "floatingPanel.x")
        UserDefaults.standard.set(origin.y, forKey: "floatingPanel.y")
    }

    @objc private func openSettings() {
        NotificationCenter.default.post(name: .agentPulseOpenSettings, object: nil)
    }

    @objc private func resetPositionFromMenu() {
        resetPosition()
        show()
    }

    @objc private func toggleMonitoring() {
        store.setPaused(!store.settings.monitoringPaused)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

final class DraggableHostingView<Content: View>: NSHostingView<Content> {
    private var startLocation: NSPoint?
    private let onDragEnded: () -> Void

    init(rootView: Content, onDragEnded: @escaping () -> Void) {
        self.onDragEnded = onDragEnded
        super.init(rootView: rootView)
    }

    required init(rootView: Content) {
        self.onDragEnded = {}
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required dynamic init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
        startLocation = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let startLocation else { return }
        let current = event.locationInWindow
        let dx = current.x - startLocation.x
        let dy = current.y - startLocation.y
        var origin = window.frame.origin
        origin.x += dx
        origin.y += dy
        window.setFrameOrigin(origin)
    }

    override func mouseUp(with event: NSEvent) {
        startLocation = nil
        onDragEnded()
    }
}
