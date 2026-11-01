import AppKit
import InkBridgeCore
import SwiftUI
import UniformTypeIdentifiers

/// The Save… flow: native save panel → optional screenshot → layered export.
///
/// Order matters: the screenshot is taken *before* the panel opens, so it
/// shows what the user was looking at when they chose Save, not the dialog.
/// InkBridge's own windows are excluded from it (ScreenCapture), so the ink
/// is never baked into the background layer.
final class ExportController {
    private unowned let coordinator: InkCoordinator
    private var model: AppModel { coordinator.model }
    private static let lastFolderKey = "exportLastFolder"

    init(coordinator: InkCoordinator) {
        self.coordinator = coordinator
    }

    func saveInteractively() {
        Task { @MainActor in
            let (background, reason) = await captureBackground()
            showPanel(background: background, backgroundReason: reason)
        }
    }

    // MARK: Background

    @MainActor
    private func captureBackground() async -> (CGImage?, String?) {
        if coordinator.store.background.mode == .studio { return (nil, "Studio Canvas hides the desktop") }
        guard model.includeScreenshot else { return (nil, "screen background turned off in the save options") }
        guard CGPreflightScreenCaptureAccess() else {
            // Shows the system prompt the first time; the user has to relaunch after granting.
            CGRequestScreenCaptureAccess()
            return (nil, "Screen Recording permission not granted")
        }
        guard let id = coordinator.overlayDisplayID else { return (nil, "no display selected") }
        do {
            return (try await ScreenCapture.capture(displayID: id), nil)
        } catch {
            return (nil, "screen capture failed: \(error.localizedDescription)")
        }
    }

    // MARK: Panel

    @MainActor
    private func showPanel(background: CGImage?, backgroundReason: String?) {
        let panel = NSSavePanel()
        panel.title = "Save InkBridge Session"
        panel.prompt = "Save"
        panel.message = "InkBridge saves a folder with the full page, the ink as a separate transparent layer and SVG, and the editable strokes."
        panel.nameFieldLabel = "Folder name:"
        panel.nameFieldStringValue = Self.defaultName()
        panel.canCreateDirectories = true
        panel.showsTagField = false
        panel.isExtensionHidden = true
        // A chosen export folder wins; otherwise the last folder used, else the project's exports/.
        let storage = coordinator.storage
        panel.directoryURL = storage.config.exportsPath != nil ? storage.exportsDirectory
            : (UserDefaults.standard.url(forKey: Self.lastFolderKey) ?? storage.exportsDirectory)
        try? FileManager.default.createDirectory(at: panel.directoryURL!, withIntermediateDirectories: true)
        panel.accessoryView = NSHostingView(rootView: ExportOptionsView(model: model, backgroundAvailable: background != nil,
                                                                          backgroundReason: backgroundReason))
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            UserDefaults.standard.set(url.deletingLastPathComponent(), forKey: Self.lastFolderKey)
            self.write(to: url, background: self.model.includeScreenshot ? background : nil,
                       backgroundReason: self.model.includeScreenshot ? backgroundReason : "screen background turned off in the save options")
        }
    }

    static func defaultName(date: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "InkBridge \(f.string(from: date))"
    }

    // MARK: Writing

    @MainActor
    private func write(to url: URL, background: CGImage?, backgroundReason: String?) {
        var metadata = coordinator.makeMetadata()
        metadata.title = url.lastPathComponent
        let scale = NSScreen.screens.first { DisplayManager.displayID(of: $0) == coordinator.overlayDisplayID }?.backingScaleFactor ?? 2
        let options = ExportOptions(fullPageFormat: model.fullPageFormat, pixelScale: scale)
        do {
            let result = try SessionArchive.export(coordinator.store.strokes, metadata: metadata, background: background,
                                                   backgroundUnavailableReason: backgroundReason, options: options, to: url)
            model.statusMessage = "Saved “\(url.lastPathComponent)”"
            reportSuccess(url: url, result: result)
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "InkBridge couldn’t save “\(url.lastPathComponent)”"
            alert.informativeText = "\(error.localizedDescription)\n\nNothing was changed at that location. Your drawing is still open and autosaved."
            alert.runModal()
        }
    }

    @MainActor
    private func reportSuccess(url: URL, result: ExportResult) {
        let alert = NSAlert()
        alert.messageText = "Saved “\(url.lastPathComponent)”"
        var text = "Full page (image + PDF), transparent ink layer (PNG + SVG), background layer and editable strokes were saved."
        if coordinator.store.background.mode == .studio {
            text = "Full page on the Studio Canvas (image + PDF), the background layer on its own, the transparent ink layer (PNG + SVG) and editable strokes were saved."
        } else if !result.skipped.isEmpty {
            let reasons = Set(result.skipped.values).sorted().joined(separator: "; ")
            text = "The ink layer (PNG + SVG), editable strokes and a preview were saved.\n\nNot included: the screen background and full-page image (\(reasons))."
        }
        alert.informativeText = text
        alert.addButton(withTitle: "Show in Finder")
        alert.addButton(withTitle: "OK")
        if result.skipped.values.contains(where: { $0.contains("permission") }) {
            alert.addButton(withTitle: "Open Privacy Settings")
        }
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.activateFileViewerSelecting([url])
        case .alertThirdButtonReturn:
            if let settings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(settings)
            }
        default:
            break
        }
    }
}

/// Options shown at the bottom of the save panel.
private struct ExportOptionsView: View {
    @ObservedObject var model: AppModel
    let backgroundAvailable: Bool
    let backgroundReason: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.background.mode == .studio {
                Text("Studio Canvas: the full page uses the canvas background; the desktop is not captured.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Toggle("Include the screen behind the ink (full-page image)", isOn: $model.includeScreenshot)
            }
            if model.includeScreenshot && !backgroundAvailable {
                Text("Screen background unavailable: \(backgroundReason ?? "unknown"). The ink layer and strokes will still be saved.")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            Picker("Full-page format:", selection: $model.fullPageFormat) {
                Text("PNG (lossless)").tag(ExportOptions.ImageFormat.png)
                Text("JPEG (smaller)").tag(ExportOptions.ImageFormat.jpeg)
            }
            .pickerStyle(.radioGroup)
            .horizontalRadioGroupLayout()
            .disabled(!model.includeScreenshot && model.background.mode != .studio)
            Text("Always saved: annotations.png (transparent, never includes the background), annotations.svg, strokes.json, background layer, full-page.pdf, metadata.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 460, alignment: .leading)
    }
}
