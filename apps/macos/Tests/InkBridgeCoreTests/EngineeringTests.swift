import CoreGraphics
import XCTest
@testable import InkBridgeCore

final class EngineeringTests: XCTestCase {
    private func node(_ id: String, _ x: CGFloat, _ y: CGFloat, kind: String = "microservice") -> DiagramNode {
        DiagramNode(id: id, kind: kind, label: id, frame: CGRect(x: x, y: y, width: 100, height: 60))
    }

    func testConnectorsAttachToFacingSidesAndFollowMovedNodes() {
        var d = Diagram(nodes: [node("a", 0, 0), node("b", 300, 0)], edges: [DiagramEdge(id: "e", from: "a", to: "b", style: .orthogonal)])
        XCTAssertEqual(d.path(of: d.edges[0]), [CGPoint(x: 100, y: 30), CGPoint(x: 300, y: 30)], "straight across when aligned")
        d.nodes[1].frame.origin = CGPoint(x: 300, y: 200)  // move b down-right: still more horizontal
        let p = d.path(of: d.edges[0])
        XCTAssertEqual(p.first, CGPoint(x: 100, y: 30))
        XCTAssertEqual(p.last, CGPoint(x: 300, y: 230), "re-attached to b's left side after the move")
        XCTAssertEqual(p.count, 4, "orthogonal route has two bends")
        for (u, v) in zip(p, p.dropFirst()) { XCTAssertTrue(u.x == v.x || u.y == v.y, "every segment is horizontal or vertical") }
        d.nodes[1].frame.origin = CGPoint(x: 0, y: 400)  // now stacked: top/bottom sides
        XCTAssertEqual(d.path(of: d.edges[0]).first, CGPoint(x: 50, y: 60))
        XCTAssertEqual(d.path(of: d.edges[0]).last, CGPoint(x: 50, y: 400))
    }

    func testConnectorsSharingASideGetSeparatePorts() {
        let d = Diagram(nodes: [node("gw", 0, 100), node("a", 300, 0), node("b", 300, 100), node("c", 300, 200)],
                        edges: [DiagramEdge(id: "1", from: "gw", to: "a"), DiagramEdge(id: "2", from: "gw", to: "b"), DiagramEdge(id: "3", from: "gw", to: "c")])
        let starts = d.edges.map { d.path(of: $0).first! }
        XCTAssertEqual(Set(starts.map(\.x)), [100], "all leave from the gateway's right side")
        XCTAssertEqual(starts.map(\.y), [115, 130, 145], "spread top to bottom in the order of their targets, no overlap")
    }

    func testCurvedAndStraightRoutes() {
        let a = CGRect(x: 0, y: 0, width: 100, height: 60), b = CGRect(x: 300, y: 150, width: 100, height: 60)
        XCTAssertEqual(ConnectorRouter.route(from: a, to: b, style: .straight).count, 2)
        let curve = ConnectorRouter.route(from: a, to: b, style: .curved)
        XCTAssertEqual(curve.count, 17)
        XCTAssertEqual(curve.first, CGPoint(x: 100, y: 30))
        XCTAssertEqual(curve.last!.x, 300, accuracy: 0.001)
    }

    func testDeletingANodeRemovesItsConnectors() {
        var d = Diagram(nodes: [node("a", 0, 0), node("b", 300, 0), node("c", 600, 0)],
                        edges: [DiagramEdge(id: "e1", from: "a", to: "b"), DiagramEdge(id: "e2", from: "b", to: "c")])
        d.remove(["b"])
        XCTAssertEqual(d.nodes.map(\.id), ["a", "c"])
        XCTAssertTrue(d.edges.isEmpty, "no dangling connectors")
    }

    func testTemplatesAreEditableAndConsistent() {
        for t in DiagramTemplate.allCases {
            let d = t.build(center: CGPoint(x: 500, y: 500))
            XCTAssertGreaterThan(d.nodes.count, 4, t.title)
            let ids = Set(d.nodes.map(\.id))
            XCTAssertEqual(ids.count, d.nodes.count, "unique ids")
            for e in d.edges { XCTAssertTrue(ids.contains(e.from) && ids.contains(e.to), "\(t.title): edge \(e.id) points at real nodes") }
            XCTAssertTrue(DiagramEditing.overlaps(d).isEmpty, "\(t.title): no overlapping components")
        }
    }

    func testAlignDistributeAndDuplicate() {
        var d = Diagram(nodes: [node("a", 0, 10), node("b", 200, 50), node("c", 500, 90)])
        DiagramEditing.align(&d, ids: ["a", "b", "c"], .top)
        XCTAssertEqual(Set(d.nodes.map(\.frame.minY)), [10])
        DiagramEditing.align(&d, ids: ["a", "b", "c"], .distributeH)
        XCTAssertEqual(d.nodes[1].frame.midX, 300, accuracy: 0.001, "middle node centred between the outer ones")
        d.edges = [DiagramEdge(id: "e", from: "a", to: "b")]
        let copies = DiagramEditing.duplicate(&d, ids: ["a", "b"], by: CGPoint(x: 10, y: 10))
        XCTAssertEqual(copies.count, 2)
        XCTAssertEqual(d.edges.count, 2, "the connector between duplicated nodes is duplicated too")
        XCTAssertTrue(copies.contains(d.edges[1].from) && copies.contains(d.edges[1].to))
    }

    func testComponentLibrarySearch() {
        XCTAssertGreaterThan(ComponentCatalog.all.count, 40)
        XCTAssertEqual(Set(ComponentCatalog.all.map(\.id)).count, ComponentCatalog.all.count, "unique kinds")
        XCTAssertTrue(ComponentCatalog.search("postgres").contains { $0.id == "postgres" })
        XCTAssertTrue(ComponentCatalog.search("kafka").contains { $0.id == "kafka" })
        XCTAssertGreaterThanOrEqual(ComponentCatalog.search("data").count, 6, "category search")
        for c in ComponentCatalog.all { XCTAssertTrue(ComponentCatalog.categories.contains(c.category), c.id) }
    }

    func testDiagramEditsAreUndoableAndSeparateFromInk() {
        let store = StrokeStore()
        store.setDiagram(Diagram(nodes: [node("a", 0, 0)]))
        let start = store.diagram
        var moved = start
        moved.nodes[0].frame.origin.x = 120
        store.previewDiagram(moved)  // live drag: no undo step
        store.commitDiagram(moved, undoFrom: start)
        XCTAssertEqual(store.diagram.nodes[0].frame.minX, 120)
        store.undo()
        XCTAssertEqual(store.diagram.nodes[0].frame.minX, 0, "one drag = one undo step back to where it started")
        store.undo()
        XCTAssertTrue(store.diagram.isEmpty)
        store.redo(); store.redo()
        XCTAssertEqual(store.diagram.nodes[0].frame.minX, 120)
        XCTAssertTrue(store.strokes.isEmpty)
    }

    /// Regression: typing a label made one undo step per keystroke.
    func testTypingALabelIsOneUndoStep() {
        let store = StrokeStore()
        store.setDiagram(Diagram(nodes: [node("a", 0, 0)]))
        for label in ["O", "Or", "Ord", "Orders"] {
            var d = store.diagram
            d.nodes[0].label = label
            store.amendDiagram(d)
        }
        XCTAssertEqual(store.diagram.nodes[0].label, "Orders")
        store.undo()
        XCTAssertTrue(store.diagram.isEmpty, "add + typing collapsed into the add step's successor… one undo removes the edit")
    }

    func testAmendAfterAStrokeStartsANewStep() {
        let store = StrokeStore()
        store.begin(id: "s", tool: .pen, style: StrokeStyle(color: .red, width: 2, pressureSensitive: false), point: InkPoint(x: 0, y: 0, p: 1, t: 0))
        store.end(id: "s")
        store.amendDiagram(Diagram(nodes: [node("a", 0, 0)]))
        store.undo()
        XCTAssertTrue(store.diagram.isEmpty)
        XCTAssertEqual(store.strokes.count, 1, "the stroke was not folded into the diagram step")
    }

    func testDiagramPersistsWithTheSessionAndOnTheWire() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ib-diag-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let d = DiagramTemplate.microservices.build(center: .zero)
        let mapper = CoordinateMapper(canvas: CGSize(width: 800, height: 600), surface: CGSize(width: 800, height: 600))
        let meta = SessionMetadata(id: "s", title: "t", startedAt: Date(), savedAt: Date(), deviceName: nil, displayName: nil, mapper: mapper, strokeCount: 0)
        try SessionArchive.writeStrokes([], metadata: meta, diagram: d, to: dir)
        XCTAssertEqual(SessionArchive.loadDiagram(from: dir), d)

        let wire = try MessageCodec.decode(MessageCodec.encode(Message(sequence: 1, timestampNs: 0, payload: .diagramState(d, revision: 3))))
        guard case let .diagramState(back, rev) = wire.payload else { return XCTFail() }
        XCTAssertEqual(rev, 3)
        XCTAssertEqual(back.nodes.map(\.id), d.nodes.map(\.id))
        XCTAssertEqual(back.edges.map(\.kind), d.edges.map(\.kind))
        let fixture = try MessageCodec.decode(Fixtures.data("valid/diagram.state.json"))
        guard case let .diagramState(f, _) = fixture.payload else { return XCTFail() }
        XCTAssertEqual(f.edges.first?.label, "SQL")
    }

    func testExportIncludesTheDiagram() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ib-diag-exp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let mapper = CoordinateMapper(canvas: CGSize(width: 800, height: 600), surface: CGSize(width: 800, height: 600))
        let meta = SessionMetadata(id: "s", title: "t", startedAt: Date(), savedAt: Date(), deviceName: nil, displayName: nil,
                                   mapper: mapper, strokeCount: 0, background: .studio(CanvasBackground.white))
        let d = Diagram(nodes: [DiagramNode(id: "a", kind: "postgres", label: "DB", frame: CGRect(x: 300, y: 250, width: 200, height: 100))])
        let r = try SessionArchive.export([], metadata: meta, background: nil, backgroundUnavailableReason: nil,
                                          options: ExportOptions(pixelScale: 1), diagram: d, to: dir)
        XCTAssertTrue(r.files.contains("annotations/diagram.json"))
        let src = CGImageSourceCreateWithURL(dir.appendingPathComponent("full-page.png") as CFURL, nil)!
        let img = CGImageSourceCreateImageAtIndex(src, 0, nil)!
        // The cylinder's outline crosses x=300 (its left side) somewhere between y 260..340.
        var dark = 0
        let data = CFDataGetBytePtr(img.dataProvider!.data)!
        for y in 260..<340 { let i = y * img.bytesPerRow + 300 * 4; if data[i] < 120 { dark += 1 } }
        XCTAssertGreaterThan(dark, 10, "the component is drawn in the composite")
    }
}
