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
        // Any layout-affecting change re-sizes and re-docks on the next run loop
        // turn, after SwiftUI has applied it.
        Publishers.MergeMany(
            model.$toolbarSize.map { _ in () }.eraseToAnyPublisher(),
            model.$toolbarDock.map { _ in () }.eraseToAnyPublisher(),
            model.$tool.map { _ in () }.eraseToAnyPublisher(),
            model.$connection.map { _ in () }.eraseToAnyPublisher()
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

    func screenChanged(_ screen: NSScreen?) {
        self.screen = screen
        layout()
    }

    /// Sizes the panel to its content and places it for the current dock.
    private func layout() {
        let size = host.fittingSize
        guard let frame = (screen ?? NSScreen.main)?.visibleFrame else { return }
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

    func windowDidMove(_ notification: Notification) {
        guard !placing else { return }
        UserDefaults.standard.set(NSStringFromPoint(panel.frame.origin), forKey: Self.floatingOriginKey)
        if model.toolbarDock != .floating { model.toolbarDock = .floating }
    }

    private var savedFloatingOrigin: NSPoint? {
        UserDefaults.standard.string(forKey: Self.floatingOriginKey).map(NSPointFromString)
    }

    private func clamp(_ p: NSPoint, size: NSSize, in frame: NSRect) -> NSPoint {
        NSPoint(x: min(max(p.x, frame.minX), frame.maxX - size.width),
                y: min(max(p.y, frame.minY), frame.maxY - size.height))
    }
}
