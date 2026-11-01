import XCTest
@testable import InkBridgeCore

final class IncrementalSaveTests: XCTestCase {
    private var dir: URL!
    override func setUp() { dir = FileManager.default.temporaryDirectory.appendingPathComponent("ib-inc-\(UUID().uuidString)") }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private let meta = SessionMetadata(id: "s", title: "t", startedAt: Date(), savedAt: Date(), deviceName: nil, displayName: nil,
                                       mapper: CoordinateMapper(canvas: CGSize(width: 100, height: 100), surface: CGSize(width: 100, height: 100)), strokeCount: 0)

    private func persisted(_ s: [Stroke], log: Int = 0) -> IncrementalSave.Persisted {
        .init(dir: dir, ids: s.map(\.id), background: .overlay, diagram: Diagram(), logCount: log)
    }

    func testPlanAppendsOnlyWhenSavedStrokesAreAnUnchangedPrefix() {
        let s = JournalPerformanceTests.strokes(5, points: 3)
        let p = persisted(Array(s.prefix(3)))
        XCTAssertEqual(IncrementalSave.plan(strokes: s, background: .overlay, diagram: Diagram(), dir: dir, persisted: p), .append(Array(s[3...])))
        XCTAssertEqual(IncrementalSave.plan(strokes: Array(s.prefix(3)), background: .overlay, diagram: Diagram(), dir: dir, persisted: p), .none)
        // Undo / erase removed a saved stroke.
        XCTAssertEqual(IncrementalSave.plan(strokes: [s[0], s[2], s[3]], background: .overlay, diagram: Diagram(), dir: dir, persisted: p), .full)
        // Background changed, other folder, nothing saved yet, log too long.
        XCTAssertEqual(IncrementalSave.plan(strokes: s, background: .studio(.white), diagram: Diagram(), dir: dir, persisted: p), .full)
        XCTAssertEqual(IncrementalSave.plan(strokes: s, background: .overlay, diagram: Diagram(), dir: dir.appendingPathComponent("x"), persisted: p), .full)
        XCTAssertEqual(IncrementalSave.plan(strokes: s, background: .overlay, diagram: Diagram(), dir: dir, persisted: nil), .full)
        XCTAssertEqual(IncrementalSave.plan(strokes: s, background: .overlay, diagram: Diagram(), dir: dir,
                                            persisted: persisted(Array(s.prefix(3)), log: IncrementalSave.compactAfter)), .full)
    }

    func testAppendsReloadInOrderWithoutDuplicatesAndCompact() throws {
        let s = JournalPerformanceTests.strokes(6, points: 4)
        try SessionArchive.writeStrokes(Array(s.prefix(2)), metadata: meta, to: dir)
        try SessionArchive.appendStrokes([s[2], s[3]], metadata: meta, to: dir)
        try SessionArchive.appendStrokes([s[3], s[4]], metadata: meta, to: dir)  // s[3] twice: a retried save
        XCTAssertEqual(try SessionArchive.load(from: dir).1.map(\.id), Array(s.prefix(5)).map(\.id))
        XCTAssertEqual(SessionArchive.logCount(in: dir), 4)
        // A full write folds the log in.
        try SessionArchive.writeStrokes(s, metadata: meta, to: dir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("strokes.log").path))
        XCTAssertEqual(try SessionArchive.load(from: dir).1, s)
    }

    func testTornLastLineIsSkippedAndDoesNotCorruptTheNextAppend() throws {
        let s = JournalPerformanceTests.strokes(4, points: 4)
        try SessionArchive.writeStrokes([s[0]], metadata: meta, to: dir)
        try SessionArchive.appendStrokes([s[1]], metadata: meta, to: dir)
        // Crash mid-append: half a line, no newline.
        let log = dir.appendingPathComponent("strokes.log")
        let h = try FileHandle(forWritingTo: log)
        try h.seekToEnd(); try h.write(contentsOf: Data(#"{"id":"s2","tool":"pen","po"#.utf8)); try h.close()
        XCTAssertEqual(try SessionArchive.load(from: dir).1.map(\.id), ["s0", "s1"])
        try SessionArchive.appendStrokes([s[3]], metadata: meta, to: dir)
        XCTAssertEqual(try SessionArchive.load(from: dir).1.map(\.id), ["s0", "s1", "s3"])
    }
}

final class JournalIndexTests: XCTestCase {
    func testIndexSummarisesAndSearchesInMemory() {
        var a = JournalPage(day: "2026-10-30", title: "Kickoff")
        _ = a.addNote("Café meeting notes", at: Date())
        var b = JournalPage(day: "2026-11-01")
        _ = b.addNote("Call the bank", kind: .task, at: Date())
        let t = b.entries[0].id
        b.update(t, done: true, at: Date())
        _ = b.addNote("Read about CRDTs", at: Date())
        let idx = JournalIndex(pages: [a, b])
        XCTAssertEqual(idx.days.map(\.day), ["2026-11-01", "2026-10-30"])
        XCTAssertEqual(idx.days[0].tasks, 1); XCTAssertEqual(idx.days[0].tasksDone, 1); XCTAssertEqual(idx.days[0].notes, 1)
        XCTAssertEqual(idx.days[0].preview, "Call the bank")
        XCTAssertEqual(idx.days[1].preview, "Kickoff")
        XCTAssertEqual(idx.search("cafe").map(\.day), ["2026-10-30"], "diacritic-insensitive")
        XCTAssertEqual(idx.search("CRDT").first?.snippet, "Read about CRDTs")
        XCTAssertTrue(idx.search("  ").isEmpty)
    }

    func testThumbnailDrawsInkAndIsEmptyForNoInk() {
        let s = JournalPerformanceTests.strokes(3, points: 40)
        let img = InkThumbnail.render(s, size: CGSize(width: 120, height: 40))
        XCTAssertEqual(img?.width, 240)
        XCTAssertNil(InkThumbnail.render([], size: CGSize(width: 120, height: 40)))
        // Some pixels are opaque.
        let data = img!.dataProvider!.data! as Data
        XCTAssertTrue(stride(from: 3, to: data.count, by: 4).contains { data[$0] > 0 })
    }
}
