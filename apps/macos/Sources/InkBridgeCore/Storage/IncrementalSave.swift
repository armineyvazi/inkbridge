import Foundation

/// Incremental autosave: while someone is writing, each save appends only the
/// strokes finished since the last save to `strokes.log` (JSON Lines) instead
/// of re-encoding the whole document.
///
/// Measured (release, M-series): a full `strokes.json` write of 2000 strokes
/// takes ~200 ms and grows with the document; an append of one stroke is
/// constant and well under a millisecond (`JournalPerformanceTests`).
///
/// Strokes are never edited in place (erase, undo and redo add or remove whole
/// strokes), so "the last saved strokes are an unchanged prefix of the current
/// ones" is exactly the case where appending is correct. Anything else (an
/// undo, an erase, a background or diagram change, a different folder, or a
/// long log) falls back to a full write, which also compacts the log.
///
/// Loading reads `strokes.json`, then replays the log in order, skipping ids
/// already present (no duplicates) and a torn last line (crash mid-append).
public struct IncrementalSave: Sendable {
  /// What is on disk for one session folder.
  public struct Persisted: Sendable {
    public var dir: URL
    public var ids: [String]
    public var background: CanvasBackground
    public var diagram: Diagram
    public var logCount: Int

    public init(
      dir: URL, ids: [String], background: CanvasBackground, diagram: Diagram, logCount: Int
    ) {
      self.dir = dir
      self.ids = ids
      self.background = background
      self.diagram = diagram
      self.logCount = logCount
    }
  }

  public enum Plan: Equatable, Sendable {
    case full
    case append([Stroke])
    case none
  }

  /// After this many logged strokes the next save rewrites `strokes.json` (compaction).
  public static let compactAfter = 400

  public static func plan(
    strokes: [Stroke], background: CanvasBackground, diagram: Diagram,
    dir: URL, persisted p: Persisted?
  ) -> Plan {
    guard let p, p.dir == dir, p.background == background, p.diagram == diagram,
      strokes.count >= p.ids.count
    else { return .full }
    for i in p.ids.indices where strokes[i].id != p.ids[i] { return .full }
    let new = Array(strokes[p.ids.count...])
    if new.isEmpty { return .none }
    if p.logCount + new.count > compactAfter { return .full }
    return .append(new)
  }
}

extension SessionArchive {
  static let logName = "strokes.log"

  /// Appends strokes to the session's log (one JSON object per line). If a previous
  /// append was cut off, the partial line is terminated first so it can't corrupt this one.
  public static func appendStrokes(_ strokes: [Stroke], metadata: SessionMetadata, to dir: URL)
    throws
  {
    let url = dir.appendingPathComponent(logName)
    if !FileManager.default.fileExists(atPath: url.path) {
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      FileManager.default.createFile(atPath: url.path, contents: nil)
    }
    let h = try FileHandle(forUpdating: url)
    defer { try? h.close() }
    var out = Data()
    let end = try h.seekToEnd()
    if end > 0 {
      try h.seek(toOffset: end - 1)
      if h.readData(ofLength: 1) != Data([0x0A]) { out.append(0x0A) }
      try h.seekToEnd()
    }
    for s in strokes {
      out.append(try compactEncoder.encode(s))
      out.append(0x0A)
    }
    try h.write(contentsOf: out)
    try encoder.encode(metadata).write(
      to: dir.appendingPathComponent("session.json"), options: .atomic)
  }

  /// Strokes from the log that are not already in `base`, in log order. A line that
  /// doesn't decode (a crash mid-append) is skipped.
  static func replayLog(in dir: URL, onto base: [Stroke]) -> [Stroke] {
    guard let data = try? Data(contentsOf: dir.appendingPathComponent(logName)), !data.isEmpty
    else { return base }
    var out = base
    var seen = Set(base.map(\.id))
    for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
      guard let s = try? decoder.decode(Stroke.self, from: Data(line)), seen.insert(s.id).inserted
      else { continue }
      out.append(s)
    }
    return out
  }

  /// Number of strokes in the log (for the compaction threshold after loading).
  public static func logCount(in dir: URL) -> Int {
    guard let data = try? Data(contentsOf: dir.appendingPathComponent(logName)) else { return 0 }
    return data.split(separator: 0x0A, omittingEmptySubsequences: true).count
  }
}
