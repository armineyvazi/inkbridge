import CoreGraphics
import XCTest
@testable import InkBridgeCore

final class BackgroundTests: XCTestCase {
    private func stroke(_ id: String, x: Double = 100) -> Stroke {
        Stroke(id: id, tool: .pen, style: StrokeStyle(color: .red, width: 4, pressureSensitive: false),
               points: [InkPoint(x: x, y: 100, p: 1, t: 0), InkPoint(x: x + 200, y: 300, p: 1, t: 1)])
    }

    func testSwitchingPreservesStrokesAndIsOneUndoStep() {
        let store = StrokeStore()
        store.load([stroke("a"), stroke("b", x: 400)])
        let before = store.strokes
        let strokeRevision = store.revision

        XCTAssertTrue(store.setBackground(.studio(CanvasBackground.black)))
        XCTAssertTrue(store.setBackground(.studio(CanvasBackground.white)))
        XCTAssertTrue(store.setBackground(.studio(RGBA(0.1, 0.2, 0.5), pattern: .graph)))
        XCTAssertTrue(store.setBackground(.overlay))
        XCTAssertFalse(store.setBackground(.overlay), "no-op changes are not recorded")
        XCTAssertEqual(store.strokes, before, "backgrounds never touch ink")
        XCTAssertEqual(store.revision, strokeRevision, "stroke cache is not invalidated")
        XCTAssertEqual(store.backgroundRevision, 4)

        store.undo()
        XCTAssertEqual(store.background, .studio(RGBA(0.1, 0.2, 0.5), pattern: .graph))
        store.undo(); store.undo()
        XCTAssertEqual(store.background, .studio(CanvasBackground.black))
        store.redo()
        XCTAssertEqual(store.background.color, CanvasBackground.white)
        XCTAssertEqual(store.backgroundRevision, 8, "every change, including undo/redo, gets a new revision")
        XCTAssertEqual(store.strokes, before)
    }

    func testBackgroundAndStrokeUndoInterleave() {
        let store = StrokeStore()
        store.begin(id: "s", tool: .pen, style: StrokeStyle(color: .red, width: 2, pressureSensitive: false), point: InkPoint(x: 0, y: 0, p: 1, t: 0))
        store.end(id: "s")
        store.setBackground(.studio(CanvasBackground.black))
        store.clear()
        store.undo()  // clear
        XCTAssertEqual(store.strokes.count, 1)
        XCTAssertEqual(store.background.mode, .studio)
        store.undo()  // background
        XCTAssertEqual(store.background, .overlay)
        XCTAssertEqual(store.strokes.count, 1)
    }

    func testWireFormatRoundTrips() throws {
        let m = try MessageCodec.decode(Fixtures.data("valid/canvas.background.json"))
        XCTAssertEqual(m.payload, .canvasBackground(.studio(CanvasBackground.black, pattern: .graph), revision: 7))
        XCTAssertThrowsError(try MessageCodec.decode(Fixtures.data("invalid/bad-background-mode.json"))) {
            XCTAssertEqual($0 as? ProtocolError, .invalidField("mode"))
        }
    }

    func testDarknessDrivesPatternContrast() {
        XCTAssertTrue(CanvasBackground.studio(CanvasBackground.black).isDark)
        XCTAssertTrue(CanvasBackground.studio(CanvasBackground.darkGray).isDark)
        XCTAssertFalse(CanvasBackground.studio(CanvasBackground.lightGray).isDark)
        XCTAssertFalse(CanvasBackground.overlay.isDark, "the overlay is not a surface")
        XCTAssertGreaterThan(CanvasBackground.studio(CanvasBackground.black).patternColor.r, 0.5)
    }

    func testSessionPersistsBackground() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ib-bg-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let mapper = CoordinateMapper(canvas: CGSize(width: 800, height: 600), surface: CGSize(width: 1404, height: 1872))
        let meta = SessionMetadata(id: "s", title: "t", startedAt: Date(), savedAt: Date(), deviceName: nil, displayName: nil,
                                   mapper: mapper, strokeCount: 1, background: .studio(CanvasBackground.darkGray, pattern: .dots))
        try SessionArchive.writeStrokes([stroke("a")], metadata: meta, to: dir)
        let (loaded, strokes) = try SessionArchive.load(from: dir)
        XCTAssertEqual(loaded.background, .studio(CanvasBackground.darkGray, pattern: .dots))
        let store = StrokeStore()
        store.load(strokes, background: loaded.background)
        XCTAssertEqual(store.background.color, CanvasBackground.darkGray)
    }

    func testOldSessionsWithoutBackgroundLoadAsOverlay() throws {
        let json = #"{"format":2,"id":"s","title":"t","startedAt":"2026-10-31T10:00:00Z","savedAt":"2026-10-31T10:00:00Z","canvasWidth":800,"canvasHeight":600,"surfaceWidth":1404,"surfaceHeight":1872,"viewport":{"x":0,"y":0,"zoom":1},"fit":"aspectFit","calibration":{"offsetX":0,"offsetY":0,"scaleX":1,"scaleY":1},"strokeCount":0}"#
        let meta = try JSONDecoder.iso.decode(SessionMetadata.self, from: Data(json.utf8))
        XCTAssertNil(meta.background)
    }

    /// The layering contract: annotations stay transparent on a Studio Canvas,
    /// the background is its own file, and the composite has the studio colour.
    func testStudioExportKeepsLayersSeparate() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ib-exp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let mapper = CoordinateMapper(canvas: CGSize(width: 400, height: 300), surface: CGSize(width: 400, height: 300))
        let meta = SessionMetadata(id: "s", title: "t", startedAt: Date(), savedAt: Date(), deviceName: nil, displayName: nil,
                                   mapper: mapper, strokeCount: 1, background: .studio(CanvasBackground.black, pattern: .grid))
        let result = try SessionArchive.export([stroke("a")], metadata: meta, background: nil, backgroundUnavailableReason: nil,
                                               options: ExportOptions(pixelScale: 1), to: dir)
        for f in ["full-page.png", "full-page.pdf", "background/canvas-background.png", "background/background.json", "annotations/annotations.png"] {
            XCTAssertTrue(result.files.contains(f), f)
        }
        XCTAssertFalse(result.files.contains("background/screen.png"))

        let ink = try image(dir.appendingPathComponent("annotations/annotations.png"))
        XCTAssertEqual(pixel(ink, 5, 5).a, 0, "a corner with no ink must be transparent, never the studio black")
        let full = try image(dir.appendingPathComponent("full-page.png"))
        let corner = pixel(full, 5, 5)
        XCTAssertEqual(corner.a, 255)
        XCTAssertLessThan(Int(corner.r), 60, "composite uses the studio background")
        let layer = try image(dir.appendingPathComponent("background/canvas-background.png"))
        XCTAssertLessThan(Int(pixel(layer, 5, 5).r), 60)
        let pdf = try Data(contentsOf: dir.appendingPathComponent("full-page.pdf"))
        XCTAssertTrue(pdf.starts(with: Data("%PDF".utf8)))
    }

    func testOverlayExportWithoutPatternHasNoBackgroundImage() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ib-exp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let mapper = CoordinateMapper(canvas: CGSize(width: 200, height: 100), surface: CGSize(width: 200, height: 100))
        let meta = SessionMetadata(id: "s", title: "t", startedAt: Date(), savedAt: Date(), deviceName: nil, displayName: nil,
                                   mapper: mapper, strokeCount: 0)
        let result = try SessionArchive.export([], metadata: meta, background: nil, backgroundUnavailableReason: "off",
                                               options: ExportOptions(pixelScale: 1), to: dir)
        XCTAssertTrue(result.files.contains("background/background.json"))
        XCTAssertFalse(result.files.contains("background/canvas-background.png"))
    }

    private func image(_ url: URL) throws -> CGImage {
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
    }

    private func pixel(_ img: CGImage, _ x: Int, _ y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        var buf = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &buf, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: -x, y: -(img.height - 1 - y), width: img.width, height: img.height))
        return (buf[0], buf[1], buf[2], buf[3])
    }
}
