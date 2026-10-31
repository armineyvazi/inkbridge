import XCTest
@testable import InkBridgeCore

final class DocumentSyncTests: XCTestCase {
    private let style = StrokeStyle(color: .red, width: 3, pressureSensitive: true)

    private func stroke(_ id: String, points n: Int = 3) -> Stroke {
        Stroke(id: id, tool: .pen, style: style, points: (0..<n).map { InkPoint(x: Double($0), y: 0, p: 0.5, t: Int64($0)) })
    }

    private func types(_ p: [Payload]) -> [String] { p.map(\.type) }

    func testResyncSendsResetThenWholeDocumentInOrder() {
        var sync = DocumentSync()
        let out = sync.resync([stroke("a"), stroke("b")])
        XCTAssertEqual(types(out), ["doc.reset", "stroke.begin", "stroke.point", "stroke.end", "stroke.begin", "stroke.point", "stroke.end"])
        XCTAssertEqual(sync.known, ["a", "b"])
        guard case let .strokeBegin(_, _, _, s) = out[1] else { return XCTFail() }
        XCTAssertEqual(s?.color, .red, "host strokes carry their style")
    }

    func testDeviceOwnStrokesAreNotEchoed() {
        var sync = DocumentSync()
        sync.markKnown("dev-1")
        XCTAssertTrue(sync.diff([stroke("dev-1")]).isEmpty)
    }

    func testEraseUndoAndRedoProduceMinimalDiffs() {
        var sync = DocumentSync()
        _ = sync.resync([stroke("a"), stroke("b"), stroke("c")])
        // Erase b.
        XCTAssertEqual(sync.diff([stroke("a"), stroke("c")]), [.docRemove(strokeIDs: ["b"])])
        // Undo the erase: only b comes back, nothing else is resent.
        let back = sync.diff([stroke("a"), stroke("b"), stroke("c")])
        XCTAssertEqual(types(back), ["stroke.begin", "stroke.point", "stroke.end"])
        // Nothing changed: nothing sent.
        XCTAssertTrue(sync.diff([stroke("a"), stroke("b"), stroke("c")]).isEmpty)
    }

    func testDeviceStrokeTheHostDroppedIsRemovedOnDevice() {
        // Eraser and laser strokes are drawn on the tablet but never stored by the host.
        var sync = DocumentSync()
        sync.markKnown("eraser-stroke")
        XCTAssertEqual(sync.diff([]), [.docRemove(strokeIDs: ["eraser-stroke"])])
    }

    func testLargeChangesAreChunkedWithinProtocolLimits() throws {
        var sync = DocumentSync()
        let many = (0..<600).map { stroke("s\($0)", points: 1) }
        _ = sync.resync(many)
        let removes = sync.diff([])
        XCTAssertEqual(removes.count, 3)
        for r in removes { _ = try MessageCodec.decode(MessageCodec.encode(Message(sequence: 1, timestampNs: 0, payload: r))) }

        let long = stroke("long", points: 2_000)
        let out = DocumentSync.payloads(for: long)
        XCTAssertEqual(out.count, 1 + 8 + 1, "1999 points → 8 batches of ≤256")
        for p in out {
            let frame = try FrameCodec.frame(Message(sequence: 1, timestampNs: 0, payload: p))
            XCTAssertLessThanOrEqual(frame.count, FrameCodec.maxPayloadSize + 4)
        }
    }

    func testIngestorAppliesCommandsAndViewport() {
        let ing = StrokeIngestor(store: StrokeStore())
        func m(_ seq: UInt64, _ p: Payload) -> Message { Message(sequence: seq, timestampNs: 0, payload: p) }
        _ = ing.handle(m(1, .strokeBegin(strokeID: "a", tool: .pen, point: InkPoint(x: 0, y: 0, p: 1, t: 0))), streamID: "s")
        _ = ing.handle(m(2, .strokeEnd(strokeID: "a")), streamID: "s")
        XCTAssertEqual(ing.handle(m(3, .canvasCommand(.clear)), streamID: "s"), .documentChanged)
        XCTAssertTrue(ing.store.strokes.isEmpty)
        XCTAssertEqual(ing.handle(m(4, .canvasCommand(.undo)), streamID: "s"), .documentChanged)
        XCTAssertEqual(ing.store.strokes.map(\.id), ["a"], "tablet Clear is undoable")
        let v = Viewport(x: 10, y: 20, zoom: 0.5)
        XCTAssertEqual(ing.handle(m(5, .canvasViewport(v)), streamID: "s"), .viewportChanged(v))
        XCTAssertEqual(ing.viewport, v)
    }
}
