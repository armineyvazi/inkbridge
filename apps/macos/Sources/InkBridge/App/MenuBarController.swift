import AppKit
import Combine
import InkBridgeCore

/// The InkBridge icon in the menu bar: always present, so the app stays
/// reachable when the toolbar is hidden.
///
/// - Left-click while the toolbar is hidden → the toolbar comes back.
/// - Left-click while it is visible, or any right-click → the menu.
final class MenuBarController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private unowned let coordinator: InkCoordinator
    private let menu = NSMenu()
    private var bag = Set<AnyCancellable>()

    init(coordinator: InkCoordinator) {
        self.coordinator = coordinator
        super.init()
        menu.delegate = self
        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.toolTip = "InkBridge — click to show the toolbar; right-click for the menu"
        coordinator.model.$connection.receive(on: RunLoop.main).sink { [weak self] c in
            self?.item.button?.image = NSImage(systemSymbolName: c.isConnected ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle",
                                               accessibilityDescription: "InkBridge")
        }.store(in: &bag)
    }

    @objc private func clicked() {
        let event = NSApp.currentEvent
        let wantsMenu = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        if !wantsMenu && !coordinator.isToolbarVisible {
            coordinator.showToolbar()
            return
        }
        // Attach the menu only for this click so a plain left-click keeps calling `clicked`.
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    // Rebuilt on open so titles reflect current state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        let m = coordinator.model
        menu.removeAllItems()
        var status = m.connection.isConnected
            ? "Connected: \(m.connection.deviceName ?? "BOOX") via \(m.connection.transport == .usb ? "USB" : "Wi-Fi")"
            : (m.pairedDevices.isEmpty ? "No tablet paired yet" : "Waiting for your BOOX…")
        if m.connection.isConnected, let rtt = m.rttMs { status += String(format: " · %.0f ms", rtt) }
        menu.addItem(withTitle: status, action: nil, keyEquivalent: "").isEnabled = false
        if !m.connection.isConnected && m.wifiEnabled && !m.connection.wifiListening {
            menu.addItem(withTitle: "Wi-Fi listener is not running", action: nil, keyEquivalent: "").isEnabled = false
        }
        if let message = m.statusMessage {
            menu.addItem(withTitle: message, action: nil, keyEquivalent: "").isEnabled = false
        }
        menu.addItem(.separator())
        add(menu, "Connect Device…", #selector(connectDevice), key: "k")
        menu.addItem(.separator())
        add(menu, coordinator.isToolbarVisible ? "Hide Toolbar" : "Show Toolbar", #selector(toggleToolbar))
        menu.addItem(toolbarSubmenu("Toolbar Size", ToolbarSize.allCases.map { ($0.title, $0.rawValue, $0 == m.toolbarSize) }, #selector(setSize)))
        menu.addItem(toolbarSubmenu("Toolbar Position", ToolbarDock.allCases.map { ($0.title, $0.rawValue, $0 == m.toolbarDock) }, #selector(setDock)))
        if DisplayManager.displays.count > 1 {
            let options = [("Follow the Screen I Click", "follow", m.followMouse)]
                + DisplayManager.displays.map { ($0.name, String($0.id), !m.followMouse && m.displayID == $0.id) }
            menu.addItem(toolbarSubmenu("Draw On", options, #selector(setDisplay)))
        }
        add(menu, m.background.mode == .studio ? "Back to Desktop Overlay" : "Studio Canvas", #selector(toggleStudio), key: "b")
        add(menu, m.pointerMode == .draw ? "Mouse: Use Apps (now Drawing)" : "Mouse: Draw (now Using Apps)", #selector(togglePointer), key: "d")
        menu.addItem(.separator())
        add(menu, m.overlayVisible ? "Hide Ink" : "Show Ink", #selector(toggleOverlay))
        add(menu, "Fit All Ink", #selector(fitAll))
        add(menu, "Home View", #selector(homeView))
        menu.addItem(.separator())
        add(menu, "Save…", #selector(save), key: "s")
        add(menu, "Projects & Storage…", #selector(openStorage), key: "j")
        menu.addItem(withTitle: "\(coordinator.storage.activeProject) › \(coordinator.storage.sessionTitle)", action: nil, keyEquivalent: "").isEnabled = false
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

    private func toolbarSubmenu(_ title: String, _ options: [(String, String, Bool)], _ action: Selector) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (label, raw, selected) in options {
            let mi = NSMenuItem(title: label, action: action, keyEquivalent: "")
            mi.target = self
            mi.representedObject = raw
            mi.state = selected ? .on : .off
            sub.addItem(mi)
        }
        parent.submenu = sub
        return parent
    }

    @objc private func setSize(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let s = ToolbarSize(rawValue: raw) { coordinator.model.toolbarSize = s }
        coordinator.showToolbar()
    }

    @objc private func setDock(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let d = ToolbarDock(rawValue: raw) { coordinator.model.toolbarDock = d }
        coordinator.showToolbar()
    }

    @objc private func connectDevice() { coordinator.openConnectDevice() }
    @objc private func setDisplay(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        coordinator.setDisplay(raw == "follow" ? nil : UInt32(raw).map { CGDirectDisplayID($0) })
    }

    @objc private func toggleStudio() { coordinator.toggleStudio() }
    @objc private func togglePointer() {
        coordinator.setPointerMode(coordinator.model.pointerMode == .draw ? .pointer : .draw)
    }
    @objc private func toggleToolbar() { coordinator.toggleToolbar() }
    @objc private func toggleOverlay() { coordinator.toggleOverlay() }
    @objc private func fitAll() { coordinator.fitAll() }
    @objc private func homeView() { coordinator.homeView() }
    @objc private func save() { coordinator.saveSession() }
    @objc private func settings() { coordinator.openSettings() }
    @objc private func diagnostics() { coordinator.exportDiagnostics() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func openStorage() { coordinator.storageWindow.show() }
}
