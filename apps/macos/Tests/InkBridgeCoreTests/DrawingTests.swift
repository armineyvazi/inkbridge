import CoreGraphics
import XCTest
@testable import InkBridgeCore

private let pen = StrokeStyle(color: .black, width: 3, pressureSensitive: true)

private func pt(_ x: Double, _ y: Double, p: Double = 0.5, t: Int64 = 0) -> InkPoint {
    InkPoint(x: x, y: y, p: p, t: t)
}

final class CoordinateMapperTests: XCTestCase {
    func testStretchMapsCornersToCanvasCorners() {
        let m = CoordinateMapper(canvas: CGSize(width: 1440, height: 900), surface: CGSize(width: 1404, height: 1872), fit: .stretch)
        XCTAssertEqual(m.map(x: 0, y: 0), CGPoint(x: 0, y: 0))
        XCTAssertEqual(m.map(x: 1, y: 1), CGPoint(x: 1440, y: 900))
        XCTAssertEqual(m.map(x: 0.5, y: 0.25), CGPoint(x: 720, y: 225))
    }

    func testAspectFitLetterboxesPortraitTabletOnLandscapeDisplay() {
        // 3:4 portrait tablet on a 16:10 display: full height, centered horizontally.
        let m = CoordinateMapper(canvas: CGSize(width: 1600, height: 1000), surface: CGSize(width: 1404, height: 1872))
        let r = m.activeRect
        XCTAssertEqual(r.height, 1000, accuracy: 0.001)
        XCTAssertEqual(r.width, 750, accuracy: 0.001)
        XCTAssertEqual(r.minX, 425, accuracy: 0.001)
        XCTAssertEqual(m.map(x: 0, y: 0).x, 425, accuracy: 0.001)
        XCTAssertEqual(m.map(x: 1, y: 1).x, 1175, accuracy: 0.001)
        XCTAssertEqual(m.aspectRatio, 0.75, accuracy: 0.0001)
    }

    func testLandscapeTabletOnLandscapeDisplay() {
        let m = CoordinateMapper(canvas: CGSize(width: 1600, height: 1000), surface: CGSize(width: 1872, height: 1404))
        XCTAssertEqual(m.activeRect.width, 1333.333, accuracy: 0.01)
        XCTAssertEqual(m.activeRect.height, 1000, accuracy: 0.001)
    }

    func testOutOfRangeIsClamped() {
        let m = CoordinateMapper(canvas: CGSize(width: 100, height: 100), surface: CGSize(width: 1, height: 1))
        XCTAssertEqual(m.map(x: -0.05, y: 1.08), CGPoint(x: 0, y: 100))
    }

    func testCalibrationOffsetAndScale() {
        let cal = CoordinateMapper.Calibration(offsetX: 0.1, offsetY: 0, scaleX: 1.25, scaleY: 1)
        let m = CoordinateMapper(canvas: CGSize(width: 100, height: 100), surface: CGSize(width: 1, height: 1), calibration: cal)
        XCTAssertEqual(m.map(x: 0.1, y: 0).x, 0, accuracy: 1e-9)
        XCTAssertEqual(m.map(x: 0.9, y: 0).x, 100, accuracy: 1e-9)
    }
}

final class SmoothingTests: XCTestCase {
    func testCatmullRomPassesThroughEverySample() {
        let pts = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 5), CGPoint(x: 20, y: 0), CGPoint(x: 30, y: 8)]
        let segs = Smoothing.catmullRom(pts, pressures: [0.1, 0.2, 0.3, 0.4])
        XCTAssertEqual(segs.count, 3)
        for (i, s) in segs.enumerated() {
            XCTAssertEqual(s.start, pts[i])
            XCTAssertEqual(s.end, pts[i + 1])
            XCTAssertEqual(s.startPressure, [0.1, 0.2, 0.3, 0.4][i])
        }
    }

    func testCollinearInputStaysCollinear() {
        let pts = (0..<5).map { CGPoint(x: Double($0) * 10, y: 0) }
        for s in Smoothing.catmullRom(pts, pressures: Array(repeating: 1, count: 5)) {
            XCTAssertEqual(s.control1.y, 0)
            XCTAssertEqual(s.control2.y, 0)
        }
    }

    func testDecimateKeepsEndpoints() {
        let pts = [CGPoint(x: 0, y: 0), CGPoint(x: 0.1, y: 0), CGPoint(x: 0.2, y: 0), CGPoint(x: 5, y: 0), CGPoint(x: 5.1, y: 0)]
        let (out, w) = Smoothing.decimate(pts, pressures: [1, 2, 3, 4, 5], minDistance: 1)
        XCTAssertEqual(out, [CGPoint(x: 0, y: 0), CGPoint(x: 5, y: 0), CGPoint(x: 5.1, y: 0)])
        XCTAssertEqual(w, [1, 4, 5])
    }

    func testPressureWidth() {
        XCTAssertEqual(StrokeRenderer.width(pen, pressure: 1), 3)
        XCTAssertEqual(StrokeRenderer.width(pen, pressure: 0), 0.9, accuracy: 1e-9)
        XCTAssertEqual(StrokeRenderer.width(pen, pressure: 5), 3)
        let flat = StrokeStyle(color: .yellow, width: 18, pressureSensitive: false)
        XCTAssertEqual(StrokeRenderer.width(flat, pressure: 0.1), 18)
    }
}

final class StrokeStoreTests: XCTestCase {
    private func draw(_ store: StrokeStore, _ id: String, tool: Tool = .pen, _ points: [InkPoint]) {
        store.begin(id: id, tool: tool, style: pen, point: points[0])
        if points.count > 1 { store.append(id: id, points: Array(points.dropFirst())) }
        store.end(id: id)
    }

    func testStrokeLifecycleCommitsOnEnd() {
        let s = StrokeStore()
        s.begin(id: "a", tool: .pen, style: pen, point: pt(0.1, 0.1))
        s.append(id: "a", points: [pt(0.2, 0.2), pt(0.3, 0.3)])
        XCTAssertEqual(s.active["a"]?.points.count, 3)
        XCTAssertTrue(s.strokes.isEmpty)
        s.end(id: "a")
        XCTAssertEqual(s.strokes.map(\.id), ["a"])
        XCTAssertTrue(s.active.isEmpty)
    }

    func testPointsForUnknownStrokeAreIgnored() {
        let s = StrokeStore()
        XCTAssertNil(s.append(id: "ghost", points: [pt(0, 0)]))
        s.end(id: "ghost")
        XCTAssertTrue(s.strokes.isEmpty)
    }

    func testCancelDiscardsStroke() {
        let s = StrokeStore()
        s.begin(id: "a", tool: .pen, style: pen, point: pt(0.1, 0.1))
        s.cancel(id: "a")
        XCTAssertTrue(s.strokes.isEmpty)
        XCTAssertFalse(s.canUndo)
    }

    func testUndoRedoWholeStrokes() {
        let s = StrokeStore()
        draw(s, "a", [pt(0.1, 0.1), pt(0.2, 0.2)])
        draw(s, "b", [pt(0.5, 0.5), pt(0.6, 0.6)])
        s.undo()
        XCTAssertEqual(s.strokes.map(\.id), ["a"])
        s.undo()
        XCTAssertTrue(s.strokes.isEmpty)
        s.redo()
        s.redo()
        XCTAssertEqual(s.strokes.map(\.id), ["a", "b"])
        XCTAssertFalse(s.canRedo)
    }

    func testNewStrokeClearsRedo() {
        let s = StrokeStore()
        draw(s, "a", [pt(0.1, 0.1)])
        s.undo()
        draw(s, "b", [pt(0.2, 0.2)])
        XCTAssertFalse(s.canRedo)
        XCTAssertEqual(s.strokes.map(\.id), ["b"])
    }

    func testClearIsUndoable() {
        let s = StrokeStore()
        draw(s, "a", [pt(0.1, 0.1)])
        draw(s, "b", [pt(0.2, 0.2)])
        s.clear()
        XCTAssertTrue(s.strokes.isEmpty)
        s.undo()
        XCTAssertEqual(s.strokes.map(\.id), ["a", "b"])
        s.redo()
        XCTAssertTrue(s.strokes.isEmpty)
        s.undo()
        XCTAssertEqual(s.strokes.map(\.id), ["a", "b"])
    }

    func testEraserRemovesOnlyTouchedStrokesAndUndoRestoresOrder() {
        let s = StrokeStore()
        draw(s, "top", [pt(0.1, 0.1), pt(0.9, 0.1)])
        draw(s, "mid", [pt(0.1, 0.5), pt(0.9, 0.5)])
        draw(s, "bot", [pt(0.1, 0.9), pt(0.9, 0.9)])
        // One gesture, in two batches, that crosses the top line, detours around
        // the right end of the middle line, then crosses the bottom line.
        s.begin(id: "e", tool: .eraser, style: pen, point: pt(0.3, 0.08))
        s.append(id: "e", points: [pt(0.3, 0.12), pt(0.95, 0.12)])
        s.append(id: "e", points: [pt(0.95, 0.88), pt(0.7, 0.88), pt(0.7, 0.92)])
        XCTAssertEqual(s.strokes.map(\.id), ["mid"])
        s.end(id: "e")
        s.undo()
        XCTAssertEqual(s.strokes.map(\.id), ["top", "mid", "bot"])
        s.redo()
        XCTAssertEqual(s.strokes.map(\.id), ["mid"])
    }

    func testCancelledEraserGestureRestoresStrokes() {
        let s = StrokeStore()
        draw(s, "a", [pt(0.1, 0.5), pt(0.9, 0.5)])
        s.begin(id: "e", tool: .eraser, style: pen, point: pt(0.5, 0.5))
        XCTAssertTrue(s.strokes.isEmpty)
        s.cancel(id: "e")
        XCTAssertEqual(s.strokes.map(\.id), ["a"])
    }

    func testEraserRespectsAspectRatio() {
        let s = StrokeStore()
        s.aspectRatio = 2  // canvas twice as wide as tall
        s.eraserRadius = 0.02
        draw(s, "v", [pt(0.5, 0.1), pt(0.5, 0.9)])
        // 0.015 normalized-x away is 0.03 in height units: outside the radius.
        s.begin(id: "e", tool: .eraser, style: pen, point: pt(0.515, 0.5))
        s.end(id: "e")
        XCTAssertEqual(s.strokes.count, 1)
    }

    func testLaserStrokesFadeAndAreNotUndoable() {
        let s = StrokeStore()
        s.begin(id: "l", tool: .laser, style: pen, point: pt(0.5, 0.5))
        s.end(id: "l", now: 100)
        XCTAssertTrue(s.strokes.isEmpty)
        XCTAssertEqual(s.laser.count, 1)
        XCTAssertFalse(s.canUndo)
        XCTAssertTrue(s.pruneLaser(now: 100.5))
        XCTAssertFalse(s.pruneLaser(now: 100 + StrokeStore.laserLifetime + 0.01))
    }

    func testRevisionChangesOnlyWithCommittedInk() {
        let s = StrokeStore()
        let r0 = s.revision
        s.begin(id: "a", tool: .pen, style: pen, point: pt(0.1, 0.1))
        s.append(id: "a", points: [pt(0.2, 0.2)])
        XCTAssertEqual(s.revision, r0)
        s.end(id: "a")
        XCTAssertGreaterThan(s.revision, r0)
    }
}

final class StrokeIngestorTests: XCTestCase {
    private func msg(_ seq: UInt64, _ payload: Payload) -> Message {
        Message(sequence: seq, timestampNs: 0, payload: payload)
    }

    func testDropsDuplicateAndStaleSequences() {
        let ing = StrokeIngestor(store: StrokeStore())
        XCTAssertEqual(ing.handle(msg(1, .strokeBegin(strokeID: "a", tool: .pen, point: pt(0, 0))), streamID: "s"), .strokeUpdated(id: "a", added: 1))
        XCTAssertEqual(ing.handle(msg(2, .strokePoint(strokeID: "a", points: [pt(0.1, 0.1)])), streamID: "s"), .strokeUpdated(id: "a", added: 1))
        // Replayed after a reconnect: must not double the stroke.
        XCTAssertEqual(ing.handle(msg(2, .strokePoint(strokeID: "a", points: [pt(0.1, 0.1)])), streamID: "s"), .none)
        XCTAssertEqual(ing.store.active["a"]?.points.count, 2)
        XCTAssertEqual(ing.droppedCount, 1)
        // A new app process has a new stream and starts over at 1.
        XCTAssertEqual(ing.handle(msg(1, .strokeBegin(strokeID: "b", tool: .pen, point: pt(0, 0))), streamID: "s2"), .strokeUpdated(id: "b", added: 1))
    }

    func testResolvesDeviceToolThroughHostSelection() {
        let ing = StrokeIngestor(store: StrokeStore())
        ing.resolveTool = { tool in
            (tool == .eraser ? .eraser : .highlighter, StrokeStyle(color: .yellow, width: 18, pressureSensitive: false))
        }
        _ = ing.handle(msg(1, .strokeBegin(strokeID: "a", tool: .pen, point: pt(0, 0))), streamID: "s")
        XCTAssertEqual(ing.store.active["a"]?.tool, .highlighter)
    }

    func testSurfaceFromHelloAndResize() throws {
        let ing = StrokeIngestor(store: StrokeStore())
        let hello = try MessageCodec.decode(Fixtures.data("valid/device.hello.json"))
        XCTAssertEqual(ing.handle(hello, streamID: "s"), .surfaceChanged(CGSize(width: 1404, height: 1872)))
        XCTAssertEqual(ing.handle(msg(5, .deviceSurface(widthPx: 1872, heightPx: 1404)), streamID: "s"), .surfaceChanged(CGSize(width: 1872, height: 1404)))
    }
}

final class SessionTests: XCTestCase {
    func testClockSyncUsesLowestRTTSample() {
        var c = ClockSync()
        // Device clock is 1_000_000 ns ahead. Symmetric 2 ms path...
        c.addPong(hostSentNs: 0, deviceNs: 1_000_000 + 1_000_000, hostReceivedNs: 2_000_000)
        // ...then a congested 20 ms sample with asymmetric delay.
        c.addPong(hostSentNs: 10_000_000, deviceNs: 1_000_000 + 28_000_000, hostReceivedNs: 30_000_000)
        XCTAssertEqual(c.offsetNs, 1_000_000)
        XCTAssertEqual(c.lastRTTNs, 20_000_000)
        XCTAssertEqual(c.hostTime(forDeviceNs: 5_000_000), 4_000_000)
    }

    func testLatencyStats() {
        var s = LatencyStats(capacity: 4)
        [10, 20, 30, 40, 50].forEach { s.add($0) }
        XCTAssertEqual(s.count, 4)
        XCTAssertEqual(s.mean, 35)
        XCTAssertEqual(s.percentile(0.5), 40)
        XCTAssertEqual(s.percentile(1), 50)
    }

    func testArbiterPrefersUSBAndFallsBack() {
        var a = PeerArbiter()
        let wifi = PeerArbiter.Peer(id: UUID(), kind: .wifi, connectedAt: Date(timeIntervalSince1970: 1))
        let usb = PeerArbiter.Peer(id: UUID(), kind: .usb, connectedAt: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(a.add(wifi), wifi.id)
        XCTAssertEqual(a.add(usb), usb.id)
        XCTAssertFalse(a.isActive(wifi.id))
        XCTAssertEqual(a.remove(usb.id), wifi.id)
        XCTAssertEqual(a.setPreference(.usbOnly), nil)
    }

    func testArbiterPrefersNewestOfSameKind() {
        var a = PeerArbiter()
        let old = PeerArbiter.Peer(id: UUID(), kind: .usb, connectedAt: Date(timeIntervalSince1970: 0))
        let new = PeerArbiter.Peer(id: UUID(), kind: .usb, connectedAt: Date(timeIntervalSince1970: 5))
        a.add(old)
        XCTAssertEqual(a.add(new), new.id)
    }

    func testArchiveRoundTripAndExports() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("inkbridge-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let strokes = [
            Stroke(id: "a", tool: .pen, style: pen, points: [pt(0.1, 0.1, p: 0.2), pt(0.5, 0.4, p: 0.9), pt(0.9, 0.2)]),
            Stroke(id: "b", tool: .highlighter, style: StrokeStyle(color: RGBA(1, 0.9, 0, 0.35), width: 18, pressureSensitive: false), points: [pt(0.2, 0.8), pt(0.8, 0.8)]),
        ]
        let mapper = CoordinateMapper(canvas: CGSize(width: 800, height: 500), surface: CGSize(width: 1404, height: 1872))
        let meta = SessionMetadata(id: "s1", title: "Test", startedAt: Date(timeIntervalSince1970: 0), savedAt: Date(timeIntervalSince1970: 60),
                                   deviceName: "BOOX", displayName: "Built-in", mapper: mapper, strokeCount: 2)
        try SessionArchive.save(strokes, metadata: meta, to: dir)

        let (loadedMeta, loaded) = try SessionArchive.load(from: dir)
        XCTAssertEqual(loaded, strokes)
        XCTAssertEqual(loadedMeta, meta)
        XCTAssertEqual(loadedMeta.mapper, mapper)

        let png = try Data(contentsOf: dir.appendingPathComponent("preview.png"))
        XCTAssertEqual(Array(png.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let pdf = try Data(contentsOf: dir.appendingPathComponent("export.pdf"))
        XCTAssertEqual(String(decoding: pdf.prefix(5), as: UTF8.self), "%PDF-")
        XCTAssertNotNil(CGPDFDocument(dir.appendingPathComponent("export.pdf") as CFURL)?.page(at: 1))
    }

    func testRenderedImageContainsInk() throws {
        let mapper = CoordinateMapper(canvas: CGSize(width: 100, height: 100), surface: CGSize(width: 1, height: 1))
        let stroke = Stroke(id: "a", tool: .pen, style: StrokeStyle(color: RGBA(1, 0, 0), width: 6, pressureSensitive: false),
                            points: [pt(0.1, 0.5), pt(0.9, 0.5)])
        let image = try SessionArchive.renderImage([stroke], mapper: mapper, background: nil, scale: 1)
        let data = image.dataProvider!.data! as Data
        let bpr = image.bytesPerRow
        func pixel(_ x: Int, _ y: Int) -> [UInt8] { let o = y * bpr + x * 4; return Array(data[o..<o + 3]) }
        XCTAssertEqual(pixel(50, 50), [255, 0, 0], "stroke centre should be red")
        XCTAssertEqual(pixel(50, 10), [255, 255, 255], "far from the stroke should be white")
    }
}

final class GeometryTests: XCTestCase {
    func testSegmentDistances() {
        let a = SIMD2<Double>(0, 0), b = SIMD2<Double>(10, 0)
        XCTAssertEqual(Geometry.segmentDistance(SIMD2(5, 3), a, b), 3)
        XCTAssertEqual(Geometry.segmentDistance(SIMD2(13, 4), a, b), 5)
        XCTAssertEqual(Geometry.segmentsDistance(a, b, SIMD2(5, -1), SIMD2(5, 1)), 0, "crossing")
        XCTAssertEqual(Geometry.segmentsDistance(a, b, SIMD2(0, 2), SIMD2(10, 2)), 2, "parallel")
    }

    func testFastSwipeBetweenSamplesStillErases() {
        let s = StrokeStore()
        s.begin(id: "line", tool: .pen, style: pen, point: pt(0.1, 0.5))
        s.append(id: "line", points: [pt(0.9, 0.5)])
        s.end(id: "line")
        // Two eraser samples 0.2 apart straddle the line; neither is within the radius.
        s.begin(id: "e", tool: .eraser, style: pen, point: pt(0.5, 0.4))
        s.append(id: "e", points: [pt(0.5, 0.6)])
        XCTAssertTrue(s.strokes.isEmpty)
    }
}
