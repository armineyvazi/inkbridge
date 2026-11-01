import AppKit
import InkBridgeCore
import SwiftUI

/// The toolbar's background control: a swatch showing the current workspace,
/// opening a panel with Desktop Overlay / Studio Canvas, presets, a custom
/// colour and paper patterns. Every choice applies instantly and is one undo step.
struct BackgroundButton: View {
    @ObservedObject var model: AppModel
    weak var actions: ToolbarActions?
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            ZStack {
                if model.background.mode == .studio {
                    RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: model.background.color.nsColor))
                } else {
                    RoundedRectangle(cornerRadius: 5).fill(.clear)
                    Image(systemName: "rectangle.dashed").font(.system(size: 13))
                }
                RoundedRectangle(cornerRadius: 5).strokeBorder(.primary.opacity(0.5), lineWidth: 1)
            }
            .frame(width: 22, height: 18)
            .frame(width: 28, height: 26)
        }
        .buttonStyle(.plain)
        .help(model.background.mode == .studio ? "Studio Canvas — background (⌃⌥B toggles overlay)" : "Desktop Overlay — background (⌃⌥B for Studio Canvas)")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            BackgroundPanel(model: model, actions: actions)
        }
    }
}

struct BackgroundPanel: View {
    @ObservedObject var model: AppModel
    weak var actions: ToolbarActions?

    private var bg: CanvasBackground { model.background }

    private let presets: [(String, RGBA)] = [
        ("White", CanvasBackground.white), ("Black", CanvasBackground.black),
        ("Light gray", CanvasBackground.lightGray), ("Dark gray", CanvasBackground.darkGray),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: Binding(get: { bg.mode }, set: { mode in
                var b = bg
                b.mode = mode
                if mode == .studio && bg.mode == .overlay { b.color = model.lastStudioColor }
                apply(b)
            })) {
                Text("Desktop Overlay").tag(CanvasBackground.Mode.overlay)
                Text("Studio Canvas").tag(CanvasBackground.Mode.studio)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text("Studio Canvas").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                ForEach(presets, id: \.0) { name, color in
                    Button { apply(.studio(color, pattern: bg.pattern)) } label: {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(nsColor: color.nsColor))
                            .frame(width: 30, height: 30)
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(
                                bg.mode == .studio && bg.color == color ? Color.accentColor : .primary.opacity(0.3),
                                lineWidth: bg.mode == .studio && bg.color == color ? 3 : 1))
                    }
                    .buttonStyle(.plain)
                    .help(name)
                }
                ColorPicker("", selection: Binding(
                    get: { Color(nsColor: bg.color.nsColor) },
                    set: { c in
                        guard let s = NSColor(c).usingColorSpace(.sRGB) else { return }
                        apply(.studio(RGBA(Double(s.redComponent), Double(s.greenComponent), Double(s.blueComponent)), pattern: bg.pattern))
                    }), supportsOpacity: false)
                    .labelsHidden()
                    .help("Custom colour")
            }

            Text("Paper").font(.caption).foregroundStyle(.secondary)
            Picker("", selection: Binding(get: { bg.pattern }, set: { p in var b = bg; b.pattern = p; apply(b) })) {
                Text("None").tag(CanvasBackground.Pattern.none)
                Text("Grid").tag(CanvasBackground.Pattern.grid)
                Text("Dots").tag(CanvasBackground.Pattern.dots)
                Text("Graph").tag(CanvasBackground.Pattern.graph)
                Text("Engineering").tag(CanvasBackground.Pattern.engineering)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(bg.mode == .studio
                 ? "Studio Canvas covers this display. Ink, zoom and your session are kept; ⌃⌥B returns to the desktop."
                 : "Ink floats over whatever is on screen. ⌃⌥B switches to Studio Canvas.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 330)
    }

    private func apply(_ b: CanvasBackground) {
        actions?.setBackground(b)
    }
}
