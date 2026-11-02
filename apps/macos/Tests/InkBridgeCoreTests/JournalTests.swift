import CoreGraphics
import XCTest

@testable import InkBridgeCore

final class JournalTests: XCTestCase {
  private let tehran = TimeZone(identifier: "Asia/Tehran")!
  private let newYork = TimeZone(identifier: "America/New_York")!
  private var tmp: URL!

  override func setUp() {
    tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ib-journal-\(UUID().uuidString)")
  }
  override func tearDown() { try? FileManager.default.removeItem(at: tmp) }

  private func date(_ s: String, _ tz: TimeZone) -> Date {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    f.timeZone = tz
    return f.date(from: s)!
  }

  func testCrossingLocalMidnightChangesTheDay() {
    let before = date("2026-11-01 23:59:30", tehran)
    XCTAssertEqual(JournalCalendar.dayID(for: before, in: tehran), "2026-11-01")
    let midnight = JournalCalendar.nextMidnight(after: before, in: tehran)
    XCTAssertEqual(midnight, date("2026-11-02 00:00:00", tehran))
    XCTAssertEqual(JournalCalendar.dayID(for: midnight, in: tehran), "2026-11-02")
    XCTAssertEqual(
      JournalCalendar.dayID(for: midnight.addingTimeInterval(-1), in: tehran), "2026-11-01")
  }

  /// Calendar days, not rolling 24 h: New York's 2026-11-01 lasts 25 hours (DST ends).
  func testDaylightSavingDayIsNotTwentyFourHours() {
    let start = date("2026-11-01 00:30:00", newYork)
    let next = JournalCalendar.nextMidnight(after: start, in: newYork)
    XCTAssertEqual(JournalCalendar.dayID(for: next, in: newYork), "2026-11-02")
    XCTAssertEqual(
      next.timeIntervalSince(JournalCalendar.start(of: "2026-11-01", in: newYork)!), 25 * 3600)
    // 24 h after the start of that day is still 2026-11-01 locally.
    XCTAssertEqual(
      JournalCalendar.dayID(
        for: JournalCalendar.start(of: "2026-11-01", in: newYork)!.addingTimeInterval(86_400),
        in: newYork), "2026-11-01")
  }

  func testTimeZoneChangeUsesTheNewLocalDate() {
    let instant = date("2026-11-01 23:00:00", newYork)  // already 2026-11-02 in Tehran
    XCTAssertEqual(JournalCalendar.dayID(for: instant, in: newYork), "2026-11-01")
    XCTAssertEqual(JournalCalendar.dayID(for: instant, in: tehran), "2026-11-02")
  }

  func testDayNavigationAndValidation() {
    XCTAssertEqual(JournalCalendar.offset("2026-12-31", by: 1, in: tehran), "2027-01-01")
    XCTAssertEqual(JournalCalendar.offset("2026-03-01", by: -1, in: tehran), "2026-02-28")
    XCTAssertTrue(JournalCalendar.isValid("2026-11-01"))
    for bad in ["2026-13-01", "2026-02-30", "../../etc", "2026-1-1", ""] {
      XCTAssertFalse(JournalCalendar.isValid(bad), bad)
    }
  }

  func testTimestampsSurviveSaveAndReload() throws {
    let store = JournalStore(root: tmp)
    var page = JournalPage(day: "2026-11-01", title: "Sync ideas")
    let t1 = date("2026-11-01 09:15:00", tehran)
    let t2 = date("2026-11-01 11:42:00", tehran)
    let a = page.addNote("Investigate a better sync architecture", at: t1)
    let b = page.addNote("Offline-first storage layer", kind: .task, at: t2)
    page.update(b.id, done: true, at: date("2026-11-01 18:35:00", tehran))
    try store.savePage(page)
    let back = store.loadPage("2026-11-01")
    XCTAssertEqual(back, page, "reopening restores everything")
    XCTAssertEqual(back.entries[0].createdAt, t1)
    XCTAssertEqual(back.entries[0].id, a.id)
    XCTAssertEqual(back.entries[1].createdAt, t2, "creation time kept")
    XCTAssertEqual(
      back.entries[1].modifiedAt, date("2026-11-01 18:35:00", tehran),
      "modification time tracked separately")
    let raw = try String(
      contentsOf: store.dayDir("2026-11-01").appendingPathComponent("journal.json"), encoding: .utf8
    )
    XCTAssertTrue(
      raw.contains("2026-11-01T05:45:00.000Z"), "stored as UTC with ms (09:15 Tehran = 05:45Z)")
  }

  func testHandwritingIsGroupedIntoTimestampedSessions() {
    var page = JournalPage(day: "2026-11-01")
    let t0 = date("2026-11-01 09:15:00", tehran)
    page.trackInk(present: ["s1"], at: t0)
    page.trackInk(present: ["s1", "s2"], at: t0.addingTimeInterval(60))
    page.trackInk(present: ["s1", "s2", "s3"], at: t0.addingTimeInterval(7 * 60 - 30))  // 09:21:30, within 2 min of 09:16
    XCTAssertEqual(page.entries.count, 2, "a 5-minute pause starts a new session")
    page = JournalPage(day: "2026-11-01")
    page.trackInk(present: ["s1"], at: t0)
    page.trackInk(present: ["s1", "s2"], at: t0.addingTimeInterval(100))
    page.trackInk(present: ["s1", "s2", "s3"], at: t0.addingTimeInterval(200))
    XCTAssertEqual(page.entries.count, 1, "continuous writing 09:15 → 09:18 is one entry")
    XCTAssertEqual(page.entries[0].createdAt, t0)
    XCTAssertEqual(page.entries[0].modifiedAt, t0.addingTimeInterval(200))
    page.trackInk(present: ["s1"], at: t0.addingTimeInterval(300))  // s2, s3 erased
    XCTAssertEqual(page.entries[0].strokeIDs, ["s1"])
    XCTAssertEqual(page.entries[0].createdAt, t0, "timestamps stay with the original content")
    page.trackInk(present: [], at: t0.addingTimeInterval(400))
    XCTAssertTrue(page.entries.isEmpty, "an emptied session disappears")
  }

  func testDaysAreIndependentAndSearchable() throws {
    let store = JournalStore(root: tmp)
    var d1 = JournalPage(day: "2026-11-01")
    _ = d1.addNote("BOOX stylus latency", at: Date())
    var d2 = JournalPage(day: "2026-11-02")
    _ = d2.addNote("Design system workspace", at: Date())
    try store.savePage(d1)
    try store.savePage(d2)
    d1.title = "Edited later"
    try store.savePage(d1)
    XCTAssertEqual(
      store.loadPage("2026-11-02"), d2, "editing an older day never touches another day")
    XCTAssertEqual(store.days(), ["2026-11-02", "2026-11-01"])
    XCTAssertEqual(store.search("latency").map(\.day), ["2026-11-01"])
    XCTAssertEqual(store.search("EDITED").first?.entry, nil, "title hit")
    XCTAssertTrue(store.search("").isEmpty)
    XCTAssertGreaterThan(store.usageBytes(), 0)
    XCTAssertThrowsError(
      try store.savePage(JournalPage(day: "../x")), "day ids are validated before touching the disk"
    )
  }

  /// Append-only days (strokes.log, empty strokes.json) must still appear in History.
  func testDaysIncludesLogOnlyInk() throws {
    let store = JournalStore(root: tmp)
    let day = "2026-11-03"
    let dir = store.dayDir(day)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let style = StrokeStyle(color: .black, width: 3, pressureSensitive: false)
    let stroke = Stroke(
      id: "s-log-1", tool: .pen, style: style, points: [InkPoint(x: 1, y: 2, p: 1, t: 0)])
    let meta = SessionMetadata(
      id: "journal-\(day)", title: "Journal \(day)", startedAt: Date(), savedAt: Date(),
      deviceName: nil, displayName: nil,
      mapper: CoordinateMapper(
        canvas: CGSize(width: 100, height: 100), surface: CGSize(width: 100, height: 100)),
      strokeCount: 1)
    try SessionArchive.appendStrokes([stroke], metadata: meta, to: dir)
    try Data("[]".utf8).write(to: dir.appendingPathComponent("strokes.json"))
    XCTAssertTrue(store.hasContent(day))
    XCTAssertEqual(store.days(), [day])
    let loaded = try SessionArchive.load(from: dir).1
    XCTAssertEqual(loaded.map(\.id), ["s-log-1"], "load must replay strokes.log onto empty json")
  }

  /// Workspace preservation: the open document, including undo history, comes back exactly.
  func testSnapshotRestoresTheWorkspaceExactly() {
    let store = StrokeStore()
    let style = StrokeStyle(color: .red, width: 3, pressureSensitive: false)
    store.begin(id: "a", tool: .pen, style: style, point: InkPoint(x: 1, y: 1, p: 1, t: 0))
    store.end(id: "a")
    store.begin(id: "b", tool: .pen, style: style, point: InkPoint(x: 2, y: 2, p: 1, t: 0))
    store.end(id: "b")
    store.setBackground(.studio(CanvasBackground.darkGray, pattern: .grid))
    store.setDiagram(
      Diagram(nodes: [
        DiagramNode(
          id: "n", kind: "postgres", label: "DB", frame: CGRect(x: 0, y: 0, width: 10, height: 10))
      ]))
    store.undo()  // diagram undone; redo available
    let snap = store.snapshot()

    // The journal replaces the document…
    store.load([], background: .studio(CanvasBackground.white, pattern: .dots))
    store.begin(id: "j1", tool: .pen, style: style, point: InkPoint(x: 9, y: 9, p: 1, t: 0))
    store.end(id: "j1")

    // …and coming back restores everything, including redo.
    store.restore(snap)
    XCTAssertEqual(store.strokes.map(\.id), ["a", "b"])
    XCTAssertEqual(store.background, .studio(CanvasBackground.darkGray, pattern: .grid))
    XCTAssertTrue(store.diagram.isEmpty)
    store.redo()
    XCTAssertEqual(
      store.diagram.nodes.first?.label, "DB", "undo/redo history survives the round trip")
    store.undo()
    store.undo()
    XCTAssertEqual(store.background.mode, .overlay)
  }
}
