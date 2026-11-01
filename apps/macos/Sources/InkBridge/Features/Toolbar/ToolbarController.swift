import AppKit
import Combine
import SwiftUI

/// Owns the toolbar panel: size, docking position, visibility.
///
/// Docked positions are recomputed from the selected display's visible frame
/// (so they survive resolution and display changes). Dragging the toolbar
/// switches it to `.floating` and remembers where it was dropped. Size,
/// position and visibility persist through `AppModel`/UserDefaults.
final class ToolbarController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private let panel: ToolbarPanel
    private let host: NSHostingView<ToolbarView>
    private var screen: NSScreen?
    private var bag = Set<AnyCancellable>()
    /// Set while we move the panel ourselves, so windowDidMove can tell a
    /// programmatic placement from a user drag.
    private var placing = false
    private static let margin: CGFloat = 12
    private static let floatingOriginKey = "toolbarFloatingOrigin"

    init(model: AppModel, actions: ToolbarActions) {
        self.model = model
        host = NSHostingView(rootView: ToolbarView(model: model, actions: actions))
        panel = ToolbarPanel(content: host)
        super.init()
        panel.delegate = self
    }

    func start(on screen: NSScreen?) {
        self.screen = screen
        Self.repairSpuriousFloating(model)
        // Any layout-affecting change re-sizes and re-docks on the next run loop
        // turn, after SwiftUI has applied it.
        Publishers.MergeMany(
            model.$toolbarSize.map { _ in () }.eraseToAnyPublisher(),
            model.$toolbarDock.map { _ in () }.eraseToAnyPublisher(),
            model.$tool.map { _ in () }.eraseToAnyPublisher(),
            model.$connection.map { _ in () }.eraseToAnyPublisher(),
            model.$background.map { _ in () }.eraseToAnyPublisher(),
            model.$pairedDevices.map { _ in () }.eraseToAnyPublisher()
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] in self?.layout() }
        .store(in: &bag)
        model.$toolbarVisible.receive(on: RunLoop.main).sink { [weak self] visible in
            guard let self else { return }
            if visible { self.layout(); self.panel.orderFrontRegardless() } else { self.panel.orderOut(nil) }
        }.store(in: &bag)
    }

    func setVisible(_ visible: Bool) {
        model.toolbarVisible = visible
    }

    /// The ink moved to another display; a docked toolbar goes with it. A
    /// floating one keeps its place relative to the new display's corner.
    func screenChanged(_ screen: NSScreen?) {
        let old = self.screen
        self.screen = screen
        if model.toolbarDock == .floating, let old, let screen, old != screen, let saved = savedFloatingOrigin {
            let moved = NSPoint(x: saved.x - old.frame.minX + screen.frame.minX, y: saved.y - old.frame.minY + screen.frame.minY)
            UserDefaults.standard.set(NSStringFromPoint(moved), forKey: Self.floatingOriginKey)
        }
        layout()
    }

    /// Sizes the panel to its content and places it for the current dock.
    private func layout() {
        host.layoutSubtreeIfNeeded()  // @Published fires before the value changes: measure the updated content
        let size = host.fittingSize
        guard size.width > 0, size.height > 0, let frame = (screen ?? NSScreen.screens.first)?.visibleFrame else { return }
        let m = Self.margin
        let origin: NSPoint
        switch model.toolbarDock {
        case .bottom: origin = NSPoint(x: frame.midX - size.width / 2, y: frame.minY + m)
        case .top: origin = NSPoint(x: frame.midX - size.width / 2, y: frame.maxY - size.height - m)
        case .left: origin = NSPoint(x: frame.minX + m, y: frame.midY - size.height / 2)
        case .right: origin = NSPoint(x: frame.maxX - size.width - m, y: frame.midY - size.height / 2)
        case .floating: origin = clamp(savedFloatingOrigin ?? panel.frame.origin, size: size, in: frame)
        }
        placing = true
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        placing = false
    }

    // MARK: Dragging → floating

    /// Only a real drag (mouse button held) makes the toolbar floating. Moves
    /// macOS or SwiftUI make on their own (content resizing, display changes,
    /// delayed notifications) used to be mistaken for a drag, which pinned the
    /// left edge so the bar grew off-centre to the right.
    func windowDidMove(_ notification: Notification) {
        guard !placing, NSEvent.pressedMouseButtons & 1 != 0 else { return }
        UserDefaults.standard.set(NSStringFromPoint(panel.frame.origin), forKey: Self.floatingOriginKey)
        if model.toolbarDock != .floating { model.toolbarDock = .floating }
    }

    /// The content changed width by itself (status text, a new control): re-centre a docked bar.
    func windowDidResize(_ notification: Notification) {
        guard !placing, model.toolbarDock != .floating else { return }
        DispatchQueue.main.async { [weak self] in self?.layout() }
    }

    /// One-time repair for installs hit by the bug above: a "floating" dock the
    /// user never chose goes back to bottom-centre.
    private static func repairSpuriousFloating(_ model: AppModel) {
        let key = "toolbarFloatingRepairedV1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        if model.toolbarDock == .floating {
            model.toolbarDock = .bottom
            UserDefaults.standard.removeObject(forKey: floatingOriginKey)
        }
    }

    private var savedFloatingOrigin: NSPoint? {
        UserDefaults.standard.string(forKey: Self.floatingOriginKey).map(NSPointFromString)
    }

    private func clamp(_ p: NSPoint, size: NSSize, in frame: NSRect) -> NSPoint {
        NSPoint(x: min(max(p.x, frame.minX), frame.maxX - size.width),
                y: min(max(p.y, frame.minY), frame.maxY - size.height))
    }
}
