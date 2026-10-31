import AppKit
import Carbon.HIToolbox
import InkBridgeCore
import SwiftUI

// MARK: - Toolbar and hotkey actions

extension InkCoordinator: ToolbarActions {
    func undo() {
        store.undo()
        overlayView.needsDisplay = true
        refreshEditState()
    }

    func redo() {
        store.redo()
        overlayView.needsDisplay = true
        refreshEditState()
    }

    func clear() {
        store.clear()
        overlayView.needsDisplay = true
        refreshEditState()
    }

    func toggleOverlay() {
        model.overlayVisible.toggle()
        overlayView.isHidden = !model.overlayVisible
    }

    func saveSession() {
        let strokes = store.strokes
        let metadata = makeMetadata()
        let dir = Self.sessionsDirectory.appendingPathComponent(sessionID)
        let displayID = model.displayID ?? overlayDisplayID
        Task { @MainActor in
            var background: CGImage?
            if model.includeScreenshot, let displayID {
                background = try? await ScreenCapture.capture(displayID: displayID)
                if background == nil { model.statusMessage = "Screenshot unavailable; saved ink only" }
            }
            do {
                try SessionArchive.save(strokes, metadata: metadata, to: dir, background: background)
                model.statusMessage = "Saved \(strokes.count) strokes"
                NSWorkspace.shared.activateFileViewerSelecting([dir.appendingPathComponent("export.pdf")])
            } catch {
                model.statusMessage = "Save failed: \(error.localizedDescription)"
            }
        }
    }

    func openSettings() {
        if settingsWindow == nil {
            let view = SettingsView(model: model, regenerateCode: { [weak self] in self?.regeneratePairingCode() },
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

    func regeneratePairingCode() {
        model.pairingCode = PairingAuth.generateCode()
        server.setPairingCode(model.pairingCode)
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
        guard let (_, strokes) = try? SessionArchive.load(from: dir), !strokes.isEmpty else { return false }
        store.load(strokes)
        autosavedRevision = store.revision
        overlayView?.needsDisplay = true
        return true
    }
}
