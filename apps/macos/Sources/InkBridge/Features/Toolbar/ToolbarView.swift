import InkBridgeCore
import SwiftUI

/// Actions the toolbar can trigger; implemented by `InkCoordinator`.
protocol ToolbarActions: AnyObject {
    func undo()
    func redo()
    func clear()
    func toggleOverlay()
    func saveSession()
    func openSettings()
}

/// The floating tool palette.
struct ToolbarView: View {
    @ObservedObject var model: AppModel
    weak var actions: ToolbarActions?

    var body: some View {
        HStack(spacing: 10) {
            StatusBadge(model: model)
            Divider().frame(height: 22)
            toolButtons
            Divider().frame(height: 22)
            colorSwatches
            widthSlider
            Divider().frame(height: 22)
            editButtons
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(VisualEffectBackground())
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .fixedSize()
    }

    private var toolButtons: some View {
        HStack(spacing: 2) {
            toolButton(.pen, "pencil.tip", "Pen (⌃⌥P)")
            toolButton(.highlighter, "highlighter", "Highlighter (⌃⌥H)")
            toolButton(.eraser, "eraser", "Eraser (⌃⌥E)")
            toolButton(.laser, "cursorarrow.rays", "Laser pointer (⌃⌥L)")
        }
    }

    private func toolButton(_ tool: Tool, _ symbol: String, _ help: String) -> some View {
        Button { model.tool = tool } label: {
            Image(systemName: symbol)
                .frame(width: 28, height: 26)
                .background(model.tool == tool ? Color.accentColor.opacity(0.25) : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    @ViewBuilder private var colorSwatches: some View {
        let palette = model.tool == .highlighter ? AppModel.highlighterPalette : AppModel.palette
        HStack(spacing: 5) {
            ForEach(palette, id: \.self) { c in
                Circle()
                    .fill(Color(nsColor: c.nsColor))
                    .frame(width: 16, height: 16)
                    .overlay(Circle().strokeBorder(.primary.opacity(model.activeColor == c ? 0.9 : 0.2), lineWidth: model.activeColor == c ? 2 : 1))
                    .onTapGesture { model.setColor(c) }
            }
        }
        .opacity(model.tool == .eraser || model.tool == .laser ? 0.35 : 1)
        .disabled(model.tool == .eraser || model.tool == .laser)
    }

    @ViewBuilder private var widthSlider: some View {
        switch model.tool {
        case .pen:
            Slider(value: $model.penWidth, in: 1...12).frame(width: 80).help("Pen width")
        case .highlighter:
            Slider(value: $model.highlighterWidth, in: 8...48).frame(width: 80).help("Highlighter width")
        case .eraser:
            Slider(value: $model.eraserRadius, in: 0.005...0.06).frame(width: 80).help("Eraser size")
        case .laser:
            Spacer().frame(width: 80)
        }
    }

    private var editButtons: some View {
        HStack(spacing: 2) {
            iconButton("arrow.uturn.backward", "Undo (⌃⌥Z)", enabled: model.canUndo) { actions?.undo() }
            iconButton("arrow.uturn.forward", "Redo (⌃⌥⇧Z)", enabled: model.canRedo) { actions?.redo() }
            iconButton("trash", "Clear screen (⌃⌥C) — undoable") { actions?.clear() }
            iconButton(model.overlayVisible ? "eye" : "eye.slash", "Hide/show ink (⌃⌥O)") { actions?.toggleOverlay() }
            iconButton("square.and.arrow.down", "Save session (⌃⌥S)") { actions?.saveSession() }
            iconButton("gearshape", "Settings") { actions?.openSettings() }
        }
    }

    private func iconButton(_ symbol: String, _ help: String, enabled: Bool = true, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 26, height: 26) }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.35)
            .help(help)
    }
}

/// Connection state and latency at a glance.
private struct StatusBadge: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.system(size: 11, weight: .semibold))
                Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .frame(minWidth: 118, alignment: .leading)
        .help(model.connection.lastError ?? "USB: \(model.connection.usbListening ? "listening" : "off") · Wi-Fi: \(model.connection.wifiListening ? "listening" : "off")")
    }

    private var color: Color {
        if model.connection.isConnected { return .green }
        return model.connection.usbListening || model.connection.wifiListening ? .orange : .red
    }

    private var title: String {
        guard model.connection.isConnected else { return "Waiting for BOOX" }
        return model.connection.transport == .usb ? "USB" : "Wi-Fi"
    }

    private var subtitle: String {
        guard model.connection.isConnected else { return model.wifiEnabled ? "code \(model.pairingCode)" : "USB only" }
        var parts: [String] = []
        if let rtt = model.rttMs { parts.append(String(format: "rtt %.0f ms", rtt)) }
        if let lat = model.inputLatencyMs { parts.append(String(format: "ink %.0f ms", lat)) }
        return parts.isEmpty ? (model.connection.deviceName ?? "") : parts.joined(separator: " · ")
    }
}

private struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// A non-activating floating panel: clicking it does not take focus away
/// from the app being annotated.
final class ToolbarPanel: NSPanel {
    init(content: NSView) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 600, height: 48),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isMovableByWindowBackground = true
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        contentView = content
        setFrameAutosaveName("InkBridgeToolbar")
    }

    override var canBecomeKey: Bool { true }
}
