import AppKit
import Combine
import InkBridgeCore

/// The menu-bar icon: connection status and app-level commands.
final class MenuBarController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private unowned let coordinator: InkCoordinator
    private var bag = Set<AnyCancellable>()

    init(coordinator: InkCoordinator) {
        self.coordinator = coordinator
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        coordinator.model.$connection.receive(on: RunLoop.main).sink { [weak self] c in
            self?.item.button?.image = NSImage(systemSymbolName: c.isConnected ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle",
                                               accessibilityDescription: "InkBridge")
        }.store(in: &bag)
    }

    // Rebuilt on open so titles reflect current state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        let m = coordinator.model
        menu.removeAllItems()
        let status = m.connection.isConnected
            ? "Connected: \(m.connection.deviceName ?? "BOOX") via \(m.connection.transport == .usb ? "USB" : "Wi-Fi")"
            : "Waiting for BOOX…"
        menu.addItem(withTitle: status, action: nil, keyEquivalent: "").isEnabled = false
        if m.wifiEnabled {
            menu.addItem(withTitle: "Wi-Fi pairing code: \(m.pairingCode)", action: nil, keyEquivalent: "").isEnabled = false
        }
        if let message = m.statusMessage {
            menu.addItem(withTitle: message, action: nil, keyEquivalent: "").isEnabled = false
        }
        menu.addItem(.separator())
        add(menu, coordinator.isToolbarVisible ? "Hide Toolbar" : "Show Toolbar", #selector(toggleToolbar))
        add(menu, m.overlayVisible ? "Hide Ink" : "Show Ink", #selector(toggleOverlay))
        add(menu, "Save Session", #selector(save))
        add(menu, "Open Sessions Folder", #selector(openSessions))
        menu.addItem(.separator())
        add(menu, "Settings…", #selector(settings), key: ",")
        add(menu, "Export Diagnostic Report", #selector(diagnostics))
        menu.addItem(.separator())
        add(menu, "Quit InkBridge", #selector(quit), key: "q")
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, key: String = "") {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
        mi.target = self
        menu.addItem(mi)
    }

    @objc private func toggleToolbar() { coordinator.toggleToolbar() }
    @objc private func toggleOverlay() { coordinator.toggleOverlay() }
    @objc private func save() { coordinator.saveSession() }
    @objc private func settings() { coordinator.openSettings() }
    @objc private func diagnostics() { coordinator.exportDiagnostics() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func openSessions() {
        try? FileManager.default.createDirectory(at: InkCoordinator.sessionsDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(InkCoordinator.sessionsDirectory)
    }
}
