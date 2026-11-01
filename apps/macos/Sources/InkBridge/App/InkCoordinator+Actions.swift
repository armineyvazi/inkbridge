import AppKit
import Carbon.HIToolbox
import InkBridgeCore
import SwiftUI

// MARK: - Toolbar and hotkey actions

extension InkCoordinator: ToolbarActions {
    func undo() { edit { $0.undo() } }
    func redo() { edit { $0.redo() } }
    /// Clears the visible canvas. Undoable, and never touches saved sessions on disk.
    func clear() { edit { $0.clear() } }

    /// Applies a document edit, redraws, and mirrors the result to the tablet.
    private func edit(_ change: (StrokeStore) -> Void) {
        let diagramBefore = store.diagramRevision
        change(store)
        overlayView.needsDisplay = true
        backgroundDidChange()  // undo/redo may have changed the background layer
        if store.diagramRevision != diagramBefore { diagramChanged() }
        refreshEditState()
        syncDocument()
    }

    /// ⌃⌥B: Desktop Overlay ⇄ Studio Canvas (last studio colour, same paper).
    func toggleStudio() {
        var bg = store.background
        bg.mode = bg.mode == .studio ? .overlay : .studio
        if bg.mode == .studio { bg.color = model.lastStudioColor }
        setBackground(bg)
    }

    /// ⌃⌥⇧B: Studio Canvas black ⇄ white.
    func swapStudioBlackWhite() {
        let toBlack = !(store.background.mode == .studio && store.background.color == CanvasBackground.black)
        setBackground(.studio(toBlack ? CanvasBackground.black : CanvasBackground.white, pattern: store.background.pattern))
    }

    func showToolbar() { toolbar.setVisible(true) }
    var storageController: StorageController { storage }
    func showStorage() { storageWindow.show() }
    func hideToolbar() { toolbar.setVisible(false) }
    func toggleToolbar() { toolbar.setVisible(!model.toolbarVisible) }
    var isToolbarVisible: Bool { model.toolbarVisible }

    func homeView() { setViewport(.home) }

    func toggleOverlay() {
        model.overlayVisible.toggle()
        overlayView.isHidden = !model.overlayVisible
    }

    /// Opens the native save dialog and exports the session (ExportController).
    func saveSession() {
        exporter.saveInteractively()
    }

    func openSettings() {
        if settingsWindow == nil {
            let view = SettingsView(model: model, connectDevice: { [weak self] in self?.openConnectDevice() },
                                    forget: { [weak self] in self?.forget($0) },
                                    exportDiagnostics: { [weak self] in self?.exportDiagnostics() },
                                    storage: storage, openStorage: { [weak self] in self?.storageWindow.show() })
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "InkBridge Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// Opens Connect Device with a fresh short-lived code.
    func openConnectDevice() {
        connectDevice.show()
    }

    func forget(_ device: PairedDevice) {
        server.forget(deviceID: device.deviceID)
        model.pairedDevices = pairedDevices.all.filter { $0.deviceID != device.deviceID }
    }

    func exportDiagnostics() {
        let dir = Self.supportDirectory.appendingPathComponent("Diagnostics")
        let url = dir.appendingPathComponent("diagnostics-\(Self.newSessionID().dropFirst(8)).txt")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try diagnosticReport().write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            model.statusMessage = "Diagnostics export failed: \(error.localizedDescription)"
        }
    }

    func registerHotKeys() {
        let keys = hotKeys
        keys.register(kVK_ANSI_P) { [weak self] in self?.model.tool = .pen }
        keys.register(kVK_ANSI_H) { [weak self] in self?.model.tool = .highlighter }
        keys.register(kVK_ANSI_E) { [weak self] in self?.model.tool = .eraser }
        keys.register(kVK_ANSI_L) { [weak self] in self?.model.tool = .laser }
        keys.register(kVK_ANSI_Z) { [weak self] in self?.undo() }
        keys.register(kVK_ANSI_Z, modifiers: HotKeyCenter.controlOptionShift) { [weak self] in self?.redo() }
        keys.register(kVK_ANSI_C) { [weak self] in self?.clear() }
        keys.register(kVK_ANSI_O) { [weak self] in self?.toggleOverlay() }
        keys.register(kVK_ANSI_S) { [weak self] in self?.saveSession() }
        keys.register(kVK_ANSI_T) { [weak self] in self?.toggleToolbar() }
        keys.register(kVK_ANSI_F) { [weak self] in self?.fitAll() }
        keys.register(kVK_ANSI_0) { [weak self] in self?.homeView() }
        keys.register(kVK_ANSI_K) { [weak self] in self?.openConnectDevice() }
        keys.register(kVK_ANSI_B) { [weak self] in self?.toggleStudio() }
        keys.register(kVK_ANSI_J) { [weak self] in self?.storageWindow.show() }
        keys.register(kVK_ANSI_G) { [weak self] in
            guard let self else { return }
            self.setEngineering(!self.engineering.active)
        }
        keys.register(kVK_ANSI_D) { [weak self] in
            guard let self else { return }
            self.setPointerMode(self.model.pointerMode == .draw ? .pointer : .draw)
        }
        keys.register(kVK_ANSI_B, modifiers: HotKeyCenter.controlOptionShift) { [weak self] in self?.swapStudioBlackWhite() }
    }

    // MARK: Persistence

    static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("InkBridge")
    }


    var overlayDisplayID: CGDirectDisplayID? {
        targetScreen.flatMap(DisplayManager.displayID(of:))
    }

    func makeMetadata() -> SessionMetadata {
        let screen = targetScreen
        return SessionMetadata(
            id: sessionID, title: storage.sessionTitle, startedAt: sessionStarted, savedAt: Date(),
            deviceName: model.connection.deviceName, displayName: screen?.localizedName,
            mapper: overlayView.mapper, strokeCount: store.strokes.count, background: store.background
        )
    }

    /// Writes vector strokes only (no renders) so it is cheap to run often.
    /// Combined with the clean-exit flag this gives crash recovery.
    func autosave() {
        storage.save()
    }

    /// Crash recovery: reopens the last session that was being saved.
    func restoreLastSession() -> Bool {
        guard let project = UserDefaults.standard.string(forKey: "lastSessionProject"),
              let id = UserDefaults.standard.string(forKey: "lastSessionID") else { return false }
        return (try? storage.openSession(project: project, id: id)) != nil
    }
}
