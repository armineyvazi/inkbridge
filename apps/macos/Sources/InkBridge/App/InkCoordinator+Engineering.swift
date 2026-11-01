import AppKit
import InkBridgeCore

/// Engineering workspace: structured diagram editing on the Studio Canvas.
///
/// Mouse (select tool): click selects (⇧ adds), drag moves (connectors follow),
/// drag the corner handle resizes, drag on empty space selects by marquee,
/// double-click renames. Connect tool: drag from one component to another.
/// Every finished gesture is one undo step; live drags update the tablet ~15×/s.
extension InkCoordinator: EngineeringActions {
    var diagram: Diagram { store.diagram }

    func setEngineering(_ on: Bool) {
        engineering.active = on
        model.engineeringActive = on
        if on {
            // Engineering happens on a Studio Canvas; keep the user's colour if already in studio.
            if store.background.mode == .overlay {
                setBackground(.studio(model.lastStudioColor, pattern: .engineering))
            }
            engineeringPanel.show(on: targetScreen)
        } else {
            engineeringPanel.hide()
            engineering.selection = []
        }
        applyInteraction()
        overlayView?.needsDisplay = true
    }

    // MARK: Panel actions

    func addComponent(_ kind: String) {
        let c = ComponentCatalog.component(kind)
        let center = overlayView.mapper.unmap(CGPoint(x: overlayView.bounds.midX, y: overlayView.bounds.midY))
        // Offset each new component a little so repeated adds don't stack exactly.
        let k = CGFloat(store.diagram.nodes.count % 8) * 24
        var frame = CGRect(x: center.x - c.size.width / 2 + k, y: center.y - c.size.height / 2 + k, width: c.size.width, height: c.size.height)
        frame.origin = snapped(frame.origin)
        var d = store.diagram
        let node = DiagramNode(kind: kind, label: c.title, frame: frame)
        d.nodes.append(node)
        commitDiagram(d)
        engineering.selection = [node.id]
    }

    func insertTemplate(_ t: DiagramTemplate) {
        let center = overlayView.mapper.unmap(CGPoint(x: overlayView.bounds.midX, y: overlayView.bounds.midY))
        let add = t.build(center: CGPoint(x: center.x, y: center.y))
        var d = store.diagram
        d.nodes += add.nodes
        d.edges += add.edges
        commitDiagram(d)
        engineering.selection = Set(add.nodes.map(\.id))
    }

    func updateNode(_ id: String, label: String?, detail: String?) {
        var d = store.diagram
        guard let i = d.nodes.firstIndex(where: { $0.id == id }) else { return }
        if let label { d.nodes[i].label = String(label.prefix(120)) }
        if let detail {
            d.nodes[i].detail = String(detail.prefix(2_000))
            // Grow a table/note to fit its lines.
            let lines = CGFloat(d.nodes[i].detail.split(separator: "\n").count)
            d.nodes[i].frame.size.height = max(d.nodes[i].component.size.height, 40 + lines * 16)
        }
        commitDiagram(d)
    }

    func updateEdge(_ id: String, label: String?, kind: DiagramEdge.Kind?, style: DiagramEdge.Style?) {
        var d = store.diagram
        guard let i = d.edges.firstIndex(where: { $0.id == id }) else { return }
        if let label { d.edges[i].label = String(label.prefix(120)) }
        if let kind { d.edges[i].kind = kind }
        if let style { d.edges[i].style = style }
        commitDiagram(d)
    }

    func align(_ a: DiagramEditing.Alignment) {
        var d = store.diagram
        DiagramEditing.align(&d, ids: engineering.selection, a)
        commitDiagram(d)
    }

    func deleteSelection() {
        guard !engineering.selection.isEmpty else { return }
        var d = store.diagram
        d.remove(engineering.selection)
        engineering.selection = []
        commitDiagram(d)
    }

    func duplicateSelection() {
        var d = store.diagram
        let ids = DiagramEditing.duplicate(&d, ids: engineering.selection, by: CGPoint(x: 36, y: 36))
        guard !ids.isEmpty else { return }
        commitDiagram(d)
        engineering.selection = ids
    }

    // MARK: Commit / sync

    /// One undoable edit: store, redraw, inspector, tablet, autosave status.
    func commitDiagram(_ d: Diagram, undoFrom start: Diagram? = nil) {
        if let start { store.commitDiagram(d, undoFrom: start) } else { store.setDiagram(d) }
        diagramChanged()
    }

    func diagramChanged() {
        engineering.selection = engineering.selection.filter { id in store.diagram.node(id) != nil || store.diagram.edges.contains { $0.id == id } }
        engineering.diagramVersion += 1
        overlayView?.needsDisplay = true
        refreshEditState()
        syncDiagram(force: true)
    }

    func syncDiagram(force: Bool) {
        guard let peer = activePeer, force || store.diagramRevision != sentDiagramRevision else { return }
        let now = monotonicNowNs()
        // During drags, ~15 updates/s is plenty for an e-ink preview.
        if !force && now - lastDiagramSyncNs < 66_000_000 { return }
        lastDiagramSyncNs = now
        sentDiagramRevision = store.diagramRevision
        server.send(.diagramState(store.diagram, revision: store.diagramRevision), to: peer.id)
    }

    func snapped(_ p: CGPoint) -> CGPoint {
        guard engineering.snap else { return p }
        return CGPoint(x: DiagramEditing.snap(p.x, grid: 10), y: DiagramEditing.snap(p.y, grid: 10))
    }

    // MARK: Mouse

    enum DiagramDrag {
        case move(start: Diagram, from: CGPoint)
        case resize(id: String, start: Diagram)
        case connect(from: String, to: CGPoint)
        case marquee(from: CGPoint, to: CGPoint)
    }

    func handleDiagramMouse(_ e: OverlayView.MouseEvent) {
        let m = overlayView.mapper
        let tolerance = 8 / max(m.scale, 1e-6)
        switch e {
        case .down(let p):
            let c = m.unmap(p)
            let pt = CGPoint(x: c.x, y: c.y)
            let d = store.diagram
            if engineering.tool == .connect {
                if let n = DiagramEditing.hitNode(d, at: pt) { diagramDrag = .connect(from: n.id, to: pt) }
                return
            }
            // Resize handle of a selected node (bottom-right corner).
            if let n = d.nodes.first(where: { engineering.selection.contains($0.id) && hypot($0.frame.maxX - pt.x, $0.frame.maxY - pt.y) < tolerance * 1.5 }) {
                diagramDrag = .resize(id: n.id, start: d)
                return
            }
            if let n = DiagramEditing.hitNode(d, at: pt) {
                if overlayView.lastClickCount >= 2 { renameNode(n); return }
                if overlayView.lastShift { engineering.selection.formSymmetricDifference([n.id]) }
                else if !engineering.selection.contains(n.id) { engineering.selection = [n.id] }
                diagramDrag = .move(start: d, from: pt)
            } else if let edge = DiagramEditing.hitEdge(d, at: pt, tolerance: tolerance) {
                engineering.selection = overlayView.lastShift ? engineering.selection.union([edge.id]) : [edge.id]
            } else {
                if !overlayView.lastShift { engineering.selection = [] }
                diagramDrag = .marquee(from: pt, to: pt)
            }
            engineering.diagramVersion += 1
            overlayView.needsDisplay = true
        case .drag(let p):
            let c = m.unmap(p)
            let pt = CGPoint(x: c.x, y: c.y)
            switch diagramDrag {
            case let .move(start, from)?:
                var d = start
                let delta = CGPoint(x: pt.x - from.x, y: pt.y - from.y)
                for i in d.nodes.indices where engineering.selection.contains(d.nodes[i].id) {
                    d.nodes[i].frame.origin = snapped(CGPoint(x: start.nodes[i].frame.minX + delta.x, y: start.nodes[i].frame.minY + delta.y))
                }
                store.previewDiagram(d)
            case let .resize(id, start)?:
                var d = start
                if let i = d.nodes.firstIndex(where: { $0.id == id }) {
                    let o = d.nodes[i].frame.origin
                    let corner = snapped(pt)
                    d.nodes[i].frame.size = CGSize(width: max(40, corner.x - o.x), height: max(30, corner.y - o.y))
                }
                store.previewDiagram(d)
            case let .connect(from, _)?:
                diagramDrag = .connect(from: from, to: pt)
            case let .marquee(from, _)?:
                diagramDrag = .marquee(from: from, to: pt)
                let r = CGRect(x: min(from.x, pt.x), y: min(from.y, pt.y), width: abs(pt.x - from.x), height: abs(pt.y - from.y))
                engineering.selection = Set(store.diagram.nodes.filter { $0.frame.intersects(r) }.map(\.id))
            case nil:
                break
            }
            overlayView.needsDisplay = true
            syncDiagram(force: false)
        case .up:
            switch diagramDrag {
            case let .move(start, _)?, let .resize(_, start)?:
                commitDiagram(store.diagram, undoFrom: start)
            case let .connect(from, to)?:
                if let target = DiagramEditing.hitNode(store.diagram, at: to), target.id != from {
                    var d = store.diagram
                    let edge = DiagramEdge(from: from, to: target.id, kind: engineering.connectorKind, style: engineering.connectorStyle)
                    d.edges.append(edge)
                    commitDiagram(d)
                    engineering.selection = [edge.id]
                }
            default:
                break
            }
            diagramDrag = nil
            engineering.diagramVersion += 1
            overlayView.needsDisplay = true
        }
    }

    private func renameNode(_ n: DiagramNode) {
        let alert = NSAlert()
        alert.messageText = "Rename \(n.component.title)"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = n.label
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn { updateNode(n.id, label: field.stringValue, detail: nil) }
    }

    /// Transient drawing for the overlay: diagram, selection, connector preview, marquee.
    func drawDiagram(_ ctx: CGContext, _ mapper: CoordinateMapper) {
        let theme = DiagramRenderer.Theme.forBackground(store.background)
        DiagramRenderer.draw(store.diagram, in: ctx, mapper: mapper, theme: theme,
                             selection: engineering.active ? engineering.selection : [], icon: Self.icon)
        switch diagramDrag {
        case let .connect(from, to)?:
            guard let a = store.diagram.node(from) else { return }
            ctx.setStrokeColor(theme.accent)
            ctx.setLineWidth(2)
            ctx.setLineDash(phase: 0, lengths: [5, 4])
            ctx.move(to: mapper.map(x: Double(a.frame.midX), y: Double(a.frame.midY)))
            ctx.addLine(to: mapper.map(x: Double(to.x), y: Double(to.y)))
            ctx.strokePath()
        case let .marquee(from, to)?:
            let a = mapper.map(x: Double(from.x), y: Double(from.y)), b = mapper.map(x: Double(to.x), y: Double(to.y))
            let r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
            ctx.setFillColor(theme.accent.copy(alpha: 0.1)!)
            ctx.fill(r)
            ctx.setStrokeColor(theme.accent)
            ctx.setLineWidth(1)
            ctx.stroke(r)
        default:
            break
        }
    }

    // MARK: Keys (Studio window has focus)

    func handleDiagramKey(_ e: NSEvent) -> Bool {
        let cmd = e.modifierFlags.contains(.command)
        let step: CGFloat = e.modifierFlags.contains(.shift) ? 10 : 1
        switch (e.keyCode, cmd) {
        case (51, _), (117, _): deleteSelection()
        case (2, true): duplicateSelection()
        case (0, true): engineering.selection = Set(store.diagram.nodes.map(\.id)); overlayView.needsDisplay = true
        case (9, false): engineering.tool = .select
        case (8, false): engineering.tool = .connect
        case (53, false) where !engineering.selection.isEmpty: engineering.selection = []; overlayView.needsDisplay = true
        case (123, false): nudge(-step, 0)
        case (124, false): nudge(step, 0)
        case (125, false): nudge(0, step)
        case (126, false): nudge(0, -step)
        default: return false
        }
        return true
    }

    private func nudge(_ dx: CGFloat, _ dy: CGFloat) {
        guard !engineering.selection.isEmpty else { return }
        var d = store.diagram
        for i in d.nodes.indices where engineering.selection.contains(d.nodes[i].id) {
            d.nodes[i].frame.origin.x += dx
            d.nodes[i].frame.origin.y += dy
        }
        commitDiagram(d)
    }

    // MARK: Icons

    private static var iconCache: [String: CGImage] = [:]

    static func icon(_ name: String) -> CGImage? {
        if let c = iconCache[name] { return c }
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 40, weight: .regular)) else { return nil }
        var r = CGRect(origin: .zero, size: img.size)
        let cg = img.cgImage(forProposedRect: &r, context: nil, hints: nil)
        iconCache[name] = cg
        return cg
    }
}
