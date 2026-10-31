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
        change(store)
        overlayView.needsDisplay = true
        refreshEditState()
        syncDocument()
    }

    func showToolbar() { toolbar.setVisible(true) }
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
                                    exportDiagnostics: { [weak self] in self?.exportDiagnostics() })
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
    }

    // MARK: Persistence

    static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("InkBridge")
    }

    static var sessionsDirectory: URL { supportDirectory.appendingPathComponent("Sessions") }

    var overlayDisplayID: CGDirectDisplayID? {
        DisplayManager.screen(for: model.displayID).flatMap(DisplayManager.displayID(of:))
    }

    func makeMetadata() -> SessionMetadata {
        let screen = DisplayManager.screen(for: model.displayID)
        return SessionMetadata(
            id: sessionID, title: sessionID, startedAt: sessionStarted, savedAt: Date(),
            deviceName: model.connection.deviceName, displayName: screen?.localizedName,
            mapper: overlayView.mapper, strokeCount: store.strokes.count
        )
    }

    /// Writes vector strokes only (no renders) so it is cheap to run often.
    /// Combined with the clean-exit flag this gives crash recovery.
    func autosave() {
        guard store.revision != autosavedRevision else { return }
        autosavedRevision = store.revision
        let dir = Self.sessionsDirectory.appendingPathComponent(sessionID)
        do {
            try SessionArchive.writeStrokes(store.strokes, metadata: makeMetadata(), to: dir)
            UserDefaults.standard.set(sessionID, forKey: "lastSessionID")
        } catch {
            model.statusMessage = "Autosave failed: \(error.localizedDescription)"
        }
    }

    /// Restores the previous session's strokes into the store.
    func restore(sessionID: String) -> Bool {
        let dir = Self.sessionsDirectory.appendingPathComponent(sessionID)
        guard let (meta, strokes) = try? SessionArchive.load(from: dir), !strokes.isEmpty else { return false }
        store.load(strokes)
        ingestor.viewport = meta.viewport
        relayoutOverlay()
        autosavedRevision = store.revision
        overlayView?.needsDisplay = true
        return true
    }
}
