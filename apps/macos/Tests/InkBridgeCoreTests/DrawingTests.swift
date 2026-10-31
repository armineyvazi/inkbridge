import CoreGraphics
import ImageIO
import XCTest
@testable import InkBridgeCore

private let pen = StrokeStyle(color: .black, width: 3, pressureSensitive: true)

private func pt(_ x: Double, _ y: Double, p: Double = 0.5, t: Int64 = 0) -> InkPoint {
    InkPoint(x: x, y: y, p: p, t: t)
}

final class CoordinateMapperTests: XCTestCase {
    let display = CGSize(width: 1600, height: 1000)
    let tablet = CGSize(width: 1404, height: 1872)  // portrait, px

    func testHomeViewportStretchMapsTabletCornersToDisplayCorners() {
        let m = CoordinateMapper(canvas: CGSize(width: 1440, height: 900), surface: tablet, fit: .stretch)
        XCTAssertEqual(m.map(x: 0, y: 0), CGPoint(x: 0, y: 0))
        XCTAssertEqual(m.map(x: 1404, y: 1872), CGPoint(x: 1440, y: 900))
        XCTAssertEqual(m.map(x: 702, y: 468).x, 720, accuracy: 1e-9)
    }

    func testAspectFitLetterboxesPortraitTabletOnLandscapeDisplay() {
        let m = CoordinateMapper(canvas: display, surface: tablet)
        let r = m.activeRect
        XCTAssertEqual(r.height, 1000, accuracy: 0.001)
        XCTAssertEqual(r.width, 750, accuracy: 0.001)
        XCTAssertEqual(r.minX, 425, accuracy: 0.001)
        XCTAssertEqual(m.map(x: 0, y: 0).x, 425, accuracy: 0.001)
        XCTAssertEqual(m.map(x: 1404, y: 1872).x, 1175, accuracy: 0.001)
        XCTAssertEqual(m.scale, 1000.0 / 1872.0, accuracy: 1e-9, "display points per canvas px")
    }

    func testZoomingOutShowsMoreCanvasWithoutChangingStrokeData() {
        var m = CoordinateMapper(canvas: display, surface: tablet)
        let p = InkPoint(x: 702, y: 936, p: 1, t: 0)  // tablet centre at home view
        let before = m.map(p)
        m.viewport = Viewport(x: -702, y: -936, zoom: 0.5)  // zoomed out around the same centre
        XCTAssertEqual(m.map(p).x, before.x, accuracy: 1e-9, "centre stays put")
        XCTAssertEqual(m.map(p).y, before.y, accuracy: 1e-9)
        XCTAssertEqual(m.visibleCanvasRect.width, 2808, accuracy: 1e-9)
        XCTAssertEqual(m.scale, 0.5 * 1000.0 / 1872.0, accuracy: 1e-9, "ink thins as you zoom out")
    }

    func testPanningMovesTheViewNotTheInk() {
        var m = CoordinateMapper(canvas: display, surface: tablet)
        m.viewport = Viewport(x: 5000, y: 0, zoom: 1)
        XCTAssertEqual(m.map(x: 5000, y: 0).x, 425, accuracy: 1e-9, "canvas x=5000 is now the left edge")
        XCTAssertLessThan(m.map(x: 0, y: 0).x, 0, "old content is off-screen, not clamped or lost")
    }

    func testUnmapInvertsMap() {
        var m = CoordinateMapper(canvas: display, surface: tablet, calibration: .init(offsetX: 0.01, scaleX: 1.02))
        m.viewport = Viewport(x: -300, y: 250, zoom: 1.7)
        let q = m.unmap(m.map(x: 123.4, y: -56.7))
        XCTAssertEqual(q.x, 123.4, accuracy: 1e-6)
        XCTAssertEqual(q.y, -56.7, accuracy: 1e-6)
    }

    func testCalibrationOffsetAndScale() {
        let cal = CoordinateMapper.Calibration(offsetX: 0.1, offsetY: 0, scaleX: 1.25, scaleY: 1)
        let m = CoordinateMapper(canvas: CGSize(width: 100, height: 100), surface: CGSize(width: 100, height: 100), calibration: cal)
        XCTAssertEqual(m.map(x: 10, y: 0).x, 0, accuracy: 1e-9)
        XCTAssertEqual(m.map(x: 90, y: 0).x, 100, accuracy: 1e-9)
    }
}

final class ViewportTests: XCTestCase {
    func testFittingCentresContentWithMargin() {
        let v = Viewport.fitting(CGRect(x: 1000, y: 2000, width: 2808, height: 100), in: CGSize(width: 1404, height: 1872))
        XCTAssertEqual(v.zoom, 1404 * 0.9 / 2808, accuracy: 1e-9, "width-limited")
        XCTAssertEqual(v.x + 1404 / v.zoom / 2, 1000 + 1404, accuracy: 1e-6, "horizontally centred")
    }

    func testZoomKeepsFocusPointFixed() {
        let v = Viewport(x: 100, y: 200, zoom: 1)
        let z = v.zoomed(by: 2, focus: CGPoint(x: 300, y: 400))
        XCTAssertEqual(z.zoom, 2)
        XCTAssertEqual(z.x + 300 / z.zoom, 100 + 300, accuracy: 1e-9)
        XCTAssertEqual(z.y + 400 / z.zoom, 200 + 400, accuracy: 1e-9)
    }

    func testZoomIsClamped() {
        XCTAssertEqual(Viewport.home.zoomed(by: 1e-9, focus: .zero).zoom, Viewport.zoomRange.lowerBound)
        XCTAssertEqual(Viewport.home.zoomed(by: 1e9, focus: .zero).zoom, Viewport.zoomRange.upperBound)
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
    // These tests use small coordinates, so scale style and eraser to match.
    private let pen = StrokeStyle(color: .black, width: 0.003, pressureSensitive: true)
    private func makeStore() -> StrokeStore {
        let s = StrokeStore()
        s.eraserRadius = 0.015
        return s
    }

    private func draw(_ store: StrokeStore, _ id: String, tool: Tool = .pen, _ points: [InkPoint]) {
        store.begin(id: id, tool: tool, style: pen, point: points[0])
        if points.count > 1 { store.append(id: id, points: Array(points.dropFirst())) }
        store.end(id: id)
    }

    func testStrokeLifecycleCommitsOnEnd() {
        let s = makeStore()
        s.begin(id: "a", tool: .pen, style: pen, point: pt(0.1, 0.1))
        s.append(id: "a", points: [pt(0.2, 0.2), pt(0.3, 0.3)])
        XCTAssertEqual(s.active["a"]?.points.count, 3)
        XCTAssertTrue(s.strokes.isEmpty)
        s.end(id: "a")
        XCTAssertEqual(s.strokes.map(\.id), ["a"])
        XCTAssertTrue(s.active.isEmpty)
    }

    func testPointsForUnknownStrokeAreIgnored() {
        let s = makeStore()
        XCTAssertNil(s.append(id: "ghost", points: [pt(0, 0)]))
        s.end(id: "ghost")
        XCTAssertTrue(s.strokes.isEmpty)
    }

    func testCancelDiscardsStroke() {
        let s = makeStore()
        s.begin(id: "a", tool: .pen, style: pen, point: pt(0.1, 0.1))
        s.cancel(id: "a")
        XCTAssertTrue(s.strokes.isEmpty)
        XCTAssertFalse(s.canUndo)
    }

    func testUndoRedoWholeStrokes() {
        let s = makeStore()
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
        let s = makeStore()
        draw(s, "a", [pt(0.1, 0.1)])
        s.undo()
        draw(s, "b", [pt(0.2, 0.2)])
        XCTAssertFalse(s.canRedo)
        XCTAssertEqual(s.strokes.map(\.id), ["b"])
    }

    func testClearIsUndoable() {
        let s = makeStore()
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
        let s = makeStore()
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
        let s = makeStore()
        draw(s, "a", [pt(0.1, 0.5), pt(0.9, 0.5)])
        s.begin(id: "e", tool: .eraser, style: pen, point: pt(0.5, 0.5))
        XCTAssertTrue(s.strokes.isEmpty)
        s.cancel(id: "e")
        XCTAssertEqual(s.strokes.map(\.id), ["a"])
    }

    func testEraserRadiusIsIsotropicInCanvasUnits() {
        let s = makeStore()
        s.eraserRadius = 0.02
        draw(s, "v", [pt(0.5, 0.1), pt(0.5, 0.9)])
        s.begin(id: "e", tool: .eraser, style: pen, point: pt(0.53, 0.5))  // 0.03 away: outside
        s.end(id: "e")
        XCTAssertEqual(s.strokes.count, 1)
        s.begin(id: "e2", tool: .eraser, style: pen, point: pt(0.515, 0.5))  // 0.015 away: inside
        s.end(id: "e2")
        XCTAssertTrue(s.strokes.isEmpty)
    }

    func testContentBoundsCoverInkIncludingWidth() {
        let s = StrokeStore()
        XCTAssertNil(s.contentBounds)
        let wide = StrokeStyle(color: .black, width: 10, pressureSensitive: false)
        s.begin(id: "a", tool: .pen, style: wide, point: pt(-500, 100))
        s.append(id: "a", points: [pt(2000, 300)])
        s.end(id: "a")
        XCTAssertEqual(s.contentBounds, CGRect(x: -505, y: 95, width: 2510, height: 210))
    }

    func testLaserStrokesFadeAndAreNotUndoable() {
        let s = makeStore()
        s.begin(id: "l", tool: .laser, style: pen, point: pt(0.5, 0.5))
        s.end(id: "l", now: 100)
        XCTAssertTrue(s.strokes.isEmpty)
        XCTAssertEqual(s.laser.count, 1)
        XCTAssertFalse(s.canUndo)
        XCTAssertTrue(s.pruneLaser(now: 100.5))
        XCTAssertFalse(s.pruneLaser(now: 100 + StrokeStore.laserLifetime + 0.01))
    }

    func testRevisionChangesOnlyWithCommittedInk() {
        let s = makeStore()
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

    private func sampleSession() -> ([Stroke], SessionMetadata) {
        let strokes = [
            Stroke(id: "a", tool: .pen, style: pen, points: [pt(140, 187, p: 0.2), pt(702, 750, p: 0.9), pt(1260, 374)]),
            Stroke(id: "b", tool: .highlighter, style: StrokeStyle(color: RGBA(1, 0.9, 0, 0.35), width: 30, pressureSensitive: false),
                   points: [pt(280, 1500), pt(1120, 1500)]),
            // Far outside the current view: must survive in strokes.json, not in the page images.
            Stroke(id: "far", tool: .pen, style: pen, points: [pt(90_000, 90_000), pt(90_100, 90_000)]),
        ]
        let mapper = CoordinateMapper(canvas: CGSize(width: 800, height: 500), surface: CGSize(width: 1404, height: 1872))
        let meta = SessionMetadata(id: "s1", title: "Test", startedAt: Date(timeIntervalSince1970: 0), savedAt: Date(timeIntervalSince1970: 60),
                                   deviceName: "BOOX", displayName: "Built-in", mapper: mapper, strokeCount: strokes.count)
        return (strokes, meta)
    }

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("inkbridge-test-\(UUID().uuidString)")
    }

    func testAutosaveRoundTrip() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (strokes, meta) = sampleSession()
        try SessionArchive.writeStrokes(strokes, metadata: meta, to: dir)
        let (loadedMeta, loaded) = try SessionArchive.load(from: dir)
        XCTAssertEqual(loaded, strokes)
        XCTAssertEqual(loadedMeta, meta)
        XCTAssertEqual(loadedMeta.mapper, meta.mapper)
    }

    func testOldFormatSessionsAreRejectedNotMisread() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (strokes, original) = sampleSession()
        var meta = original
        meta.format = 1
        try SessionArchive.writeStrokes(strokes, metadata: meta, to: dir)
        XCTAssertThrowsError(try SessionArchive.load(from: dir))
    }

    func testExportWithBackgroundWritesEveryLayerSeparately() throws {
        let parent = tempDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let dest = parent.appendingPathComponent("Design Session")
        let (strokes, meta) = sampleSession()
        let background = try SessionArchive.renderImage([], mapper: meta.mapper, background: nil, scale: 1)  // white page
        let result = try SessionArchive.export(strokes, metadata: meta, background: background, backgroundUnavailableReason: nil,
                                               options: ExportOptions(fullPageFormat: .jpeg, pixelScale: 1), to: dest)
        XCTAssertTrue(result.skipped.isEmpty)
        for f in ["full-page.jpg", "preview.png", "annotations/annotations.png", "annotations/annotations.svg",
                  "annotations/strokes.json", "background/screen.png", "session/metadata.json",
                  "session/coordinate-mapping.json", "manifest.json"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent(f).path), f)
        }
        // Vector data is complete, including ink outside the visible page.
        let saved = try JSONDecoder().decode([Stroke].self, from: Data(contentsOf: dest.appendingPathComponent("annotations/strokes.json")))
        XCTAssertEqual(saved.map(\.id), ["a", "b", "far"])
        // The annotation layer is genuinely transparent where there is no ink.
        let ink = try XCTUnwrap(CGImageSourceCreateWithURL(dest.appendingPathComponent("annotations/annotations.png") as CFURL, nil)
            .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        XCTAssertEqual(alpha(ink, x: 5, y: 5), 0)
        // SVG has the visible strokes and not the far one.
        let svg = try String(contentsOf: dest.appendingPathComponent("annotations/annotations.svg"), encoding: .utf8)
        XCTAssertTrue(svg.contains("id=\"a\"") && svg.contains("id=\"b\""))
        XCTAssertFalse(svg.contains("id=\"far\""))
        XCTAssertTrue(svg.hasPrefix("<?xml"))
        XCTAssertEqual(Array(try Data(contentsOf: dest.appendingPathComponent("full-page.jpg")).prefix(2)), [0xFF, 0xD8])
        // No staging folders left behind.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), ["Design Session"])
    }

    func testExportWithoutScreenPermissionStillSavesInkAndExplains() throws {
        let parent = tempDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let dest = parent.appendingPathComponent("No Background")
        let (strokes, meta) = sampleSession()
        let result = try SessionArchive.export(strokes, metadata: meta, background: nil,
                                               backgroundUnavailableReason: "Screen Recording permission not granted",
                                               options: ExportOptions(pixelScale: 1), to: dest)
        XCTAssertEqual(result.skipped["full-page.png"], "Screen Recording permission not granted")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.appendingPathComponent("full-page.png").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("annotations/annotations.png").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("annotations/strokes.json").path))
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: dest.appendingPathComponent("manifest.json"))) as? [String: Any]
        XCTAssertNotNil((manifest?["skipped"] as? [String: String])?["full-page.png"])
    }

    func testExportReplacesExistingFolderWholesale() throws {
        let parent = tempDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        let dest = parent.appendingPathComponent("Session")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: dest.appendingPathComponent("stale.txt"))
        let (strokes, meta) = sampleSession()
        try SessionArchive.export(strokes, metadata: meta, background: nil, backgroundUnavailableReason: nil,
                                  options: ExportOptions(pixelScale: 1), to: dest)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.appendingPathComponent("stale.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("manifest.json").path))
    }

    private func alpha(_ image: CGImage, x: Int, y: Int) -> UInt8 {
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return ctx.data!.load(fromByteOffset: 3, as: UInt8.self)
    }

    func testRenderedImageContainsInk() throws {
        let mapper = CoordinateMapper(canvas: CGSize(width: 100, height: 100), surface: CGSize(width: 100, height: 100))
        let stroke = Stroke(id: "a", tool: .pen, style: StrokeStyle(color: RGBA(1, 0, 0), width: 6, pressureSensitive: false),
                            points: [pt(10, 50), pt(90, 50)])
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
        s.eraserRadius = 0.015
        let pen = StrokeStyle(color: .black, width: 0.003, pressureSensitive: true)
        s.begin(id: "line", tool: .pen, style: pen, point: pt(0.1, 0.5))
        s.append(id: "line", points: [pt(0.9, 0.5)])
        s.end(id: "line")
        // Two eraser samples 0.2 apart straddle the line; neither is within the radius.
        s.begin(id: "e", tool: .eraser, style: pen, point: pt(0.5, 0.4))
        s.append(id: "e", points: [pt(0.5, 0.6)])
        XCTAssertTrue(s.strokes.isEmpty)
    }
}
