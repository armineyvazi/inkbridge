import InkBridgeCore
import SwiftUI

/// Actions the toolbar and menus can trigger; implemented by `InkCoordinator`.
protocol ToolbarActions: AnyObject {
    func undo()
    func redo()
    func clear()
    func toggleOverlay()
    func saveSession()
    func openSettings()
    func fitAll()
    func homeView()
    func hideToolbar()
    /// Changes the canvas background layer (one undo step, synced to the tablet).
    func setBackground(_ background: CanvasBackground)
    /// nil = follow the screen the user clicks; otherwise pin to that display.
    func setDisplay(_ id: CGDirectDisplayID?)
    /// What the Mac mouse does: use apps (pointer) or draw.
    func setPointerMode(_ mode: PointerMode)
    var storageController: StorageController { get }
    func showStorage()
    func setEngineering(_ on: Bool)
    func toggleJournal()
}

/// Save state at a glance; click for Projects & Storage.
struct SaveGlyph: View {
    @ObservedObject var storage: StorageController
    var body: some View {
        let (symbol, color, help): (String, Color, String) = {
            switch storage.status {
            case .empty: return ("doc", .secondary, "New session — nothing to save yet")
            case .saved(let d): return ("checkmark.icloud", .green, "Saved \(d.formatted(date: .omitted, time: .shortened)) in \(storage.activeProject)")
            case .saving: return ("arrow.triangle.2.circlepath", .secondary, "Saving…")
            case .unsaved: return ("circle.fill", .orange, "Unsaved changes (autosave runs every few seconds)")
            case .failed(let m): return ("exclamationmark.triangle.fill", .red, "Save failed: \(m)")
            }
        }()
        Image(systemName: symbol).font(.system(size: storage.status == .unsaved ? 7 : 13)).foregroundStyle(color)
            .frame(width: 22, height: 26).help(help)
    }
}

/// The floating tool palette.
///
/// Three densities, all keeping the essentials (current tool, undo, and the
/// ••• menu that reaches everything else):
/// - expanded: status, tools, colours, width, edit, view, save
/// - compact: tools, colour menu, undo/redo, save
/// - minimal: tool menu, undo
/// Docked left or right it lays out vertically.
struct ToolbarView: View {
    @ObservedObject var model: AppModel
    weak var actions: ToolbarActions?

    private var vertical: Bool { model.toolbarDock.isVertical }
    private var stack: AnyLayout { vertical ? AnyLayout(VStackLayout(spacing: 6)) : AnyLayout(HStackLayout(spacing: 8)) }

    var body: some View {
        stack {
            switch model.toolbarSize {
            case .expanded: expanded
            case .compact: compact
            case .minimal: minimal
            }
            moreMenu
        }
        .padding(.horizontal, vertical ? 6 : 10)
        .padding(.vertical, vertical ? 10 : 6)
        .background(VisualEffectBackground())
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .fixedSize()
    }

    // MARK: Sizes

    @ViewBuilder private var expanded: some View {
        if !vertical { StatusBadge(model: model); separator }
        journalButton
        BackgroundButton(model: model, actions: actions)
        engineeringButton
        pointerToggle
        separator
        toolButtons
        separator
        colorSwatches
        if !vertical { widthSlider }
        separator
        iconButton("arrow.uturn.backward", "Undo (⌃⌥Z)", enabled: model.canUndo) { actions?.undo() }
        iconButton("arrow.uturn.forward", "Redo (⌃⌥⇧Z)", enabled: model.canRedo) { actions?.redo() }
        iconButton("trash", "Clear canvas (⌃⌥C) — undoable; saved sessions are kept") { actions?.clear() }
        separator
        iconButton("arrow.up.left.and.arrow.down.right", "Fit all ink (⌃⌥F)") { actions?.fitAll() }
        iconButton("house", "Home view, 1:1 with the screen (⌃⌥0)") { actions?.homeView() }
        iconButton(model.overlayVisible ? "eye" : "eye.slash", "Hide/show ink (⌃⌥O)") { actions?.toggleOverlay() }
        iconButton("square.and.arrow.down", "Save… (⌃⌥S)") { actions?.saveSession() }
        if let storage = actions?.storageController { SaveGlyph(storage: storage) }
    }

    @ViewBuilder private var compact: some View {
        statusDot
        journalButton
        BackgroundButton(model: model, actions: actions)
        engineeringButton
        pointerToggle
        toolButtons
        colorMenu
        iconButton("arrow.uturn.backward", "Undo (⌃⌥Z)", enabled: model.canUndo) { actions?.undo() }
        iconButton("arrow.uturn.forward", "Redo (⌃⌥⇧Z)", enabled: model.canRedo) { actions?.redo() }
        iconButton("square.and.arrow.down", "Save… (⌃⌥S)") { actions?.saveSession() }
    }

    @ViewBuilder private var minimal: some View {
        statusDot
        Menu {
            ForEach(Tool.allCases, id: \.self) { t in
                Button { model.tool = t } label: { Label(Self.toolTitle(t), systemImage: Self.toolSymbol(t)) }
            }
        } label: {
            Image(systemName: Self.toolSymbol(model.tool)).frame(width: 26, height: 26)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Tool")
        journalButton
        BackgroundButton(model: model, actions: actions)
        iconButton("arrow.uturn.backward", "Undo (⌃⌥Z)", enabled: model.canUndo) { actions?.undo() }
    }

    // MARK: Pieces

    /// Daily Journal: today's page, one click in and out (⌃⌥N).
    private var journalButton: some View {
        let on = model.journalActive
        return Button { actions?.toggleJournal() } label: {
            Image(systemName: on ? "book.fill" : "book")
                .frame(width: 28, height: 26)
                .background(on ? Color.accentColor.opacity(0.25) : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(on ? "Close the journal and return to your work (⌃⌥N)" : "Daily Journal: capture a thought, then come back (⌃⌥N)")
    }

    /// Engineering workspace: diagram components, connectors, templates (⌃⌥G).
    private var engineeringButton: some View {
        let on = model.engineeringActive
        return Button { actions?.setEngineering(!on) } label: {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .frame(width: 28, height: 26)
                .background(on ? Color.accentColor.opacity(0.25) : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(on ? "Leave Engineering (⌃⌥G)" : "Engineering: architecture components, smart connectors, templates (⌃⌥G)")
    }

    /// Mouse: use the apps underneath, or draw. Always visible so the state is never a surprise.
    private var pointerToggle: some View {
        let drawing = model.pointerMode == .draw
        return Button { actions?.setPointerMode(drawing ? .pointer : .draw) } label: {
            Image(systemName: drawing ? "pencil.and.scribble" : "cursorarrow")
                .frame(width: 28, height: 26)
                .background(drawing ? Color.accentColor.opacity(0.25) : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(drawing ? "Mouse draws — click to use apps again (⌃⌥D)"
                      : (model.background.mode == .studio ? "Mouse pans the canvas — click to draw with the mouse (⌃⌥D)"
                                                           : "Mouse uses the apps underneath — click to draw with the mouse (⌃⌥D)"))
    }

    private var separator: some View {
        Rectangle().fill(.primary.opacity(0.15))
            .frame(width: vertical ? 22 : 1, height: vertical ? 1 : 22)
    }

    private var statusDot: some View {
        Circle().fill(model.connection.isConnected ? Color.green : Color.orange)
            .frame(width: 7, height: 7)
            .help(model.connection.isConnected ? "Connected: \(model.connection.deviceName ?? "")" : "Waiting for the tablet")
    }

    private var toolButtons: some View {
        let layout = vertical ? AnyLayout(VStackLayout(spacing: 2)) : AnyLayout(HStackLayout(spacing: 2))
        return layout {
            ForEach(Tool.allCases, id: \.self) { t in
                Button { model.tool = t } label: {
                    Image(systemName: Self.toolSymbol(t))
                        .frame(width: 28, height: 26)
                        .background(model.tool == t ? Color.accentColor.opacity(0.25) : .clear)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help("\(Self.toolTitle(t)) (⌃⌥\(Self.toolKey(t)))")
            }
        }
    }

    private var palette: [RGBA] { model.tool == .highlighter ? AppModel.highlighterPalette : AppModel.palette }
    private var colorsDisabled: Bool { model.tool == .eraser || model.tool == .laser }

    @ViewBuilder private var colorSwatches: some View {
        let layout = vertical ? AnyLayout(VStackLayout(spacing: 5)) : AnyLayout(HStackLayout(spacing: 5))
        layout {
            ForEach(palette, id: \.self) { c in
                swatch(c, selected: model.activeColor == c).onTapGesture { model.setColor(c) }
            }
        }
        .opacity(colorsDisabled ? 0.35 : 1)
        .disabled(colorsDisabled)
    }

    private var colorMenu: some View {
        Menu {
            ForEach(palette, id: \.self) { c in
                Button { model.setColor(c) } label: { Text(Self.colorName(c)) }
            }
        } label: {
            swatch(model.activeColor, selected: true)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(colorsDisabled)
        .help("Colour")
    }

    private func swatch(_ c: RGBA, selected: Bool) -> some View {
        Circle()
            .fill(Color(nsColor: c.nsColor))
            .frame(width: 16, height: 16)
            .overlay(Circle().strokeBorder(.primary.opacity(selected ? 0.9 : 0.2), lineWidth: selected ? 2 : 1))
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

    /// Everything not on the bar at the current size, plus layout controls.
    private var moreMenu: some View {
        Menu {
            Picker("Size", selection: $model.toolbarSize) {
                ForEach(ToolbarSize.allCases) { Text($0.title).tag($0) }
            }
            Picker("Position", selection: $model.toolbarDock) {
                ForEach(ToolbarDock.allCases) { Text($0.title).tag($0) }
            }
            if DisplayManager.displays.count > 1 {
                Picker("Display", selection: Binding<CGDirectDisplayID?>(
                    get: { model.followMouse ? nil : model.displayID },
                    set: { actions?.setDisplay($0) })) {
                    Text("Follow the screen I click").tag(CGDirectDisplayID?.none)
                    ForEach(DisplayManager.displays) { d in Text(d.name).tag(Optional(d.id)) }
                }
            }
            Divider()
            if model.toolbarSize != .expanded {
                Button("Redo") { actions?.redo() }.disabled(!model.canRedo)
                Button("Clear canvas") { actions?.clear() }
                Button(model.overlayVisible ? "Hide ink" : "Show ink") { actions?.toggleOverlay() }
            }
            if model.toolbarSize == .minimal { Button("Save…") { actions?.saveSession() } }
            Button("Fit all ink") { actions?.fitAll() }
            Button("Home view") { actions?.homeView() }
            if model.tool == .highlighter {
                Picker("Highlighter opacity", selection: $model.highlighterOpacity) {
                    ForEach([0.2, 0.35, 0.5, 0.7], id: \.self) { Text("\(Int($0 * 100)) %").tag($0) }
                }
            }
            Divider()
            Button("Projects & Storage… (⌃⌥J)") { actions?.showStorage() }
            Button("Settings…") { actions?.openSettings() }
            Button("Hide toolbar (⌃⌥T)") { actions?.hideToolbar() }
        } label: {
            Image(systemName: "ellipsis.circle").frame(width: 26, height: 26)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More: size, position, view, settings, hide")
    }

    private func iconButton(_ symbol: String, _ help: String, enabled: Bool = true, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 26, height: 26) }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.35)
            .help(help)
    }

    static func toolSymbol(_ t: Tool) -> String {
        switch t {
        case .pen: return "pencil.tip"
        case .highlighter: return "highlighter"
        case .eraser: return "eraser"
        case .laser: return "cursorarrow.rays"
        }
    }

    static func toolTitle(_ t: Tool) -> String {
        t == .laser ? "Laser pointer" : t.rawValue.capitalized
    }

    static func toolKey(_ t: Tool) -> String {
        switch t {
        case .pen: return "P"
        case .highlighter: return "H"
        case .eraser: return "E"
        case .laser: return "L"
        }
    }

    static func colorName(_ c: RGBA) -> String {
        switch c {
        case .red: return "Red"
        case .blue: return "Blue"
        case .green: return "Green"
        case .black: return "Black"
        case .white: return "White"
        case .yellow: return "Yellow"
        default: return c.hex
        }
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
        let zoom = model.viewport.zoom
        let via = model.connection.transport == .usb ? "USB" : "Wi-Fi"
        return abs(zoom - 1) < 0.01 ? via : "\(via) · \(Int((zoom * 100).rounded())) %"
    }

    private var subtitle: String {
        guard model.connection.isConnected else {
            if model.pairedDevices.isEmpty { return "⌃⌥K to connect" }
            return model.wifiEnabled ? "Wi-Fi ready" : "USB only"
        }
        var parts: [String] = []
        if let rtt = model.rttMs { parts.append(String(format: "rtt %.0f ms", rtt)) }
        if let lat = model.inputLatencyMs { parts.append(String(format: "ink %.0f ms", lat)) }
        return parts.isEmpty ? (model.connection.deviceName ?? "") : parts.joined(separator: " · ")
    }
}

struct VisualEffectBackground: NSViewRepresentable {
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
    }

    override var canBecomeKey: Bool { true }
}
