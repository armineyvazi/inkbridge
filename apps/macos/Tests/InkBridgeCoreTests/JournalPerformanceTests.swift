import CoreGraphics
import XCTest
@testable import InkBridgeCore

/// Writing-path costs on the Mac, per frame and per save. Prints p50/p95 in ms.
/// Run with `make bench` (release) for numbers comparable to the app.
final class JournalPerformanceTests: XCTestCase {
    static let mapper = CoordinateMapper(canvas: CGSize(width: 1512, height: 982), surface: CGSize(width: 1404, height: 1872))

    static func strokes(_ n: Int, points: Int) -> [Stroke] {
        (0..<n).map { i in
            Stroke(id: "s\(i)", tool: .pen, style: StrokeStyle(color: .black, width: 3, pressureSensitive: true),
                   points: (0..<points).map { k in InkPoint(x: Double(i % 40) * 30 + Double(k), y: Double(i / 40) * 40 + Double(k % 7), p: 0.6, t: Int64(k)) })
        }
    }

    static func ctx() -> CGContext {
        let c = CGContext(data: nil, width: 1512 * 2, height: 982 * 2, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.translateBy(x: 0, y: 982 * 2); c.scaleBy(x: 2, y: -2)
        return c
    }

    static func time(_ n: Int, _ body: () -> Void) -> (p50: Double, p95: Double) {
        var t: [Double] = []
        for _ in 0..<n {
            let s = DispatchTime.now().uptimeNanoseconds
            body()
            t.append(Double(DispatchTime.now().uptimeNanoseconds - s) / 1e6)
        }
        t.sort()
        return (t[n / 2], t[Int(Double(n) * 0.95)])
    }

    /// Per-frame cost while writing one long stroke (the live stroke is redrawn each frame).
    func testLiveStrokeFrameCost() {
        let c = Self.ctx()
        for len in [100, 1000, 3000] {
            let s = Self.strokes(1, points: len)[0]
            // The app invalidates the rect around the newest points; use exactly that.
            let dirty = StrokeRenderer.dirtyRect(for: s, tail: 2, mapper: Self.mapper)
            let r = Self.time(60) {
                c.saveGState(); c.clip(to: dirty)
                StrokeRenderer.draw(s, in: c, mapper: Self.mapper)
                c.restoreGState()
            }
            let culled = Self.time(60) {
                c.saveGState(); c.clip(to: dirty)
                StrokeRenderer.draw(s, in: c, mapper: Self.mapper, clip: dirty)
                c.restoreGState()
            }
            print(String(format: "[bench] live stroke %4d pts: frame p50 %.3f / p95 %.3f ms → dirty-culled p50 %.3f / p95 %.3f ms",
                         len, r.p50, r.p95, culled.p50, culled.p95))
        }
    }

    /// Culling must not change a single pixel inside the dirty rect, also where the stroke loops back.
    func testCulledStrokeIsPixelIdenticalInTheDirtyRect() {
        let pts = (0..<800).map { k -> InkPoint in
            let a = Double(k) / 40
            return InkPoint(x: 600 + cos(a) * Double(200 - k / 8), y: 900 + sin(a) * Double(200 - k / 8), p: 0.3 + 0.6 * abs(sin(a * 3)), t: Int64(k))
        }
        let s = Stroke(id: "spiral", tool: .pen, style: StrokeStyle(color: .black, width: 4, pressureSensitive: true), points: pts)
        let dirty = StrokeRenderer.dirtyRect(for: s, tail: 3, mapper: Self.mapper)
        func render(_ cull: Bool) -> [UInt8] {
            let w = 1512, h = 982
            var buf = [UInt8](repeating: 0, count: w * h * 4)
            buf.withUnsafeMutableBytes { raw in
                let c = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                c.translateBy(x: 0, y: CGFloat(h)); c.scaleBy(x: 1, y: -1)
                c.clip(to: dirty)
                if cull { StrokeRenderer.draw(s, in: c, mapper: Self.mapper, clip: dirty) } else { StrokeRenderer.draw(s, in: c, mapper: Self.mapper) }
            }
            return buf
        }
        let full = render(false), culled = render(true)
        let diff = zip(full, culled).filter { abs(Int($0) - Int($1)) > 2 }.count
        XCTAssertGreaterThan(full.reduce(0) { $0 + Int($1) }, 0, "something was drawn in the dirty rect")
        XCTAssertEqual(diff, 0, "culled rendering differs in \(diff) bytes")
    }

    /// Per-frame diagram cost in a small dirty rect (drawUnderInk runs on every frame).
    func testDiagramFrameCost() {
        var d = Diagram()
        for i in 0..<12 { let t = DiagramTemplate.microservices.build(center: CGPoint(x: Double(i % 4) * 1200, y: Double(i / 4) * 700)); d.nodes += t.nodes; d.edges += t.edges }
        let c = Self.ctx()
        let dirty = CGRect(x: 100, y: 100, width: 40, height: 40)
        let full = Self.time(30) {
            c.saveGState(); c.clip(to: dirty)
            DiagramRenderer.draw(d, in: c, mapper: Self.mapper, theme: .forBackground(.overlay))
            c.restoreGState()
        }
        let culled = Self.time(30) {
            c.saveGState(); c.clip(to: dirty)
            DiagramRenderer.draw(d, in: c, mapper: Self.mapper, theme: .forBackground(.overlay), dirty: dirty)
            c.restoreGState()
        }
        print(String(format: "[bench] diagram %d nodes per frame: all p50 %.3f / p95 %.3f ms → dirty-culled p50 %.3f / p95 %.3f ms",
                     d.nodes.count, full.p50, full.p95, culled.p50, culled.p95))
        XCTAssertLessThan(culled.p95, full.p95, "culling to the dirty rect must be cheaper")
    }

    /// Journal time labels: the old per-frame scan of every point vs the cached anchors.
    func testJournalTimeLabelCost() {
        let strokes = Self.strokes(600, points: 120)
        var page = JournalPage(day: "2026-11-01")
        for i in stride(from: 0, to: 600, by: 20) {
            page.trackInk(present: strokes.prefix(i + 20).map(\.id), at: Date(timeIntervalSince1970: Double(i) * 300))
        }
        let perFrameScan = Self.time(30) {
            let byID = Dictionary(strokes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for e in page.entries where e.kind == .ink {
                let pts = e.strokeIDs.compactMap { byID[$0] }.flatMap(\.points)
                _ = pts.map(\.x).min(); _ = pts.map(\.y).min()
            }
        }
        let anchors = page.inkAnchors(strokes)
        let cached = Self.time(30) { for a in anchors { _ = a.point } }
        print(String(format: "[bench] journal time labels (%d sessions, 72k pts): per-frame scan p50 %.3f / p95 %.3f ms → cached p95 %.4f ms",
                     anchors.count, perFrameScan.p50, perFrameScan.p95, cached.p95))
        XCTAssertEqual(anchors.count, page.entries.filter { $0.kind == .ink }.count)
    }

    /// Persistence costs: these must never run on the main thread while writing.
    func testPersistenceCost() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ib-perf-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let mapper = Self.mapper
        let meta = SessionMetadata(id: "s", title: "t", startedAt: Date(), savedAt: Date(), deviceName: nil, displayName: nil, mapper: mapper, strokeCount: 0)
        for n in [200, 2000] {
            let strokes = Self.strokes(n, points: 120)
            let r = Self.time(5) { try? SessionArchive.writeStrokes(strokes, metadata: meta, to: dir) }
            print(String(format: "[bench] full session save %5d strokes (%dk pts): p50 %.1f ms p95 %.1f ms", n, n * 120 / 1000, r.p50, r.p95))
        }
        // Incremental: append one finished stroke to a 2000-stroke session.
        let big = Self.strokes(2000, points: 120)
        try SessionArchive.writeStrokes(big, metadata: meta, to: dir)
        let extra = Self.strokes(2400, points: 120)
        var k = 2000
        let app = Self.time(200) {
            try? SessionArchive.appendStrokes([extra[k]], metadata: meta, to: dir)
            k += 1
        }
        print(String(format: "[bench] incremental save: append 1 stroke to a 2000-stroke session: p50 %.2f ms p95 %.2f ms", app.p50, app.p95))
        XCTAssertLessThan(app.p95, 20, "an append must not scale with the document")
        let loaded = try SessionArchive.load(from: dir).1
        XCTAssertEqual(loaded.count, 2200)

        var page = JournalPage(day: "2026-11-01")
        for i in 0..<300 { _ = page.addNote("Entry \(i) with some text about the sync engine", at: Date()) }
        let store = JournalStore(root: dir)
        let r = Self.time(20) { try? store.savePage(page) }
        print(String(format: "[bench] journal page save (300 entries): p50 %.2f ms p95 %.2f ms", r.p50, r.p95))
    }

    /// History over 400 days: build the index once, then search per keystroke in memory.
    func testHistoryWithHundredsOfDays() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ib-hist-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = JournalStore(root: dir)
        var day = "2026-11-01"
        for i in 0..<400 {
            var p = JournalPage(day: day, title: i % 10 == 0 ? "Week \(i / 7)" : "")
            for k in 0..<8 { _ = p.addNote("Day \(i) note \(k) about latency budgets", at: Date()) }
            try store.savePage(p)
            day = JournalCalendar.offset(day, by: -1)!
        }
        let build = Self.time(3) { _ = JournalIndex(store: store) }
        let idx = JournalIndex(store: store)
        let perKey = Self.time(20) { _ = idx.search("budgets 3") }
        let diskSearch = Self.time(3) { _ = store.search("budgets 3") }
        print(String(format: "[bench] history 400 days: index build p50 %.0f ms (once) · search per keystroke p95 %.2f ms (in memory) vs %.0f ms re-reading disk",
                     build.p50, perKey.p95, diskSearch.p50))
        XCTAssertEqual(idx.days.count, 400)
        XCTAssertLessThan(perKey.p95, diskSearch.p50)
    }
}
