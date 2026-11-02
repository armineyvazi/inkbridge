import CoreGraphics
import Foundation

/// Every journal day loaded once, for History: the day list, counts, and search
/// run in memory. The previous History view re-scanned the folder and re-read
/// pages on every redraw and every keystroke of a search.
public struct JournalIndex: Sendable {
  public struct Day: Equatable, Sendable, Identifiable {
    public var id: String { day }
    public var day: String
    public var title: String
    public var notes: Int
    public var tasks: Int
    public var tasksDone: Int
    public var ink: Int
    /// The title, else the first typed entry, else "".
    public var preview: String
  }

  public private(set) var days: [Day] = []
  private var pages: [String: JournalPage] = [:]

  public init(store: JournalStore) {
    for d in store.days() { add(store.loadPage(d), hasInk: store.hasInk(d)) }
  }

  public init(pages: [JournalPage]) {
    for p in pages { add(p, hasInk: false) }
  }

  private mutating func add(_ p: JournalPage, hasInk: Bool) {
    pages[p.day] = p
    let typed = p.entries.filter { $0.kind != .ink }
    days.append(
      Day(
        day: p.day, title: p.title,
        notes: typed.filter { $0.kind == .note }.count,
        tasks: typed.filter { $0.kind == .task }.count,
        tasksDone: typed.filter { $0.kind == .task && $0.done }.count,
        ink: max(p.entries.filter { $0.kind == .ink }.count, hasInk ? 1 : 0),
        preview: p.title.isEmpty ? (typed.first?.text ?? "") : p.title))
    days.sort { $0.day > $1.day }
  }

  public func page(_ day: String) -> JournalPage? { pages[day] }

  public var dayIDs: Set<String> { Set(days.map(\.day)) }

  /// Case- and diacritic-insensitive search over titles and typed entries, newest day first.
  public func search(_ query: String) -> [JournalStore.SearchHit] {
    let q = query.trimmingCharacters(in: .whitespaces)
    guard !q.isEmpty else { return [] }
    var hits: [JournalStore.SearchHit] = []
    for d in days {
      guard let p = pages[d.day] else { continue }
      if p.title.localizedStandardContains(q) {
        hits.append(.init(day: d.day, entry: nil, snippet: p.title))
      }
      for e in p.entries where e.text.localizedStandardContains(q) {
        hits.append(.init(day: d.day, entry: e, snippet: String(e.text.prefix(120))))
      }
    }
    return hits
  }
}

extension JournalStore {
  /// The day has saved ink.
  public func hasInk(_ day: String) -> Bool {
    let d = dayDir(day)
    return FileManager.default.fileExists(atPath: d.appendingPathComponent("strokes.json").path)
      || FileManager.default.fileExists(atPath: d.appendingPathComponent("strokes.log").path)
  }
}

/// A small picture of some strokes, for journal entries (handwriting previews).
public enum InkThumbnail {
  /// Renders `strokes` fitted into `size` points at `scale`x, transparent background.
  /// `color` overrides the ink colour (e.g. for dark mode); nil keeps each stroke's own.
  public static func render(
    _ strokes: [Stroke], size: CGSize, scale: CGFloat = 2, color: RGBA? = nil
  ) -> CGImage? {
    let pens = strokes.filter { $0.tool != .eraser && $0.tool != .laser && !$0.points.isEmpty }
    guard !pens.isEmpty else { return nil }
    var b = CGRect.null
    for s in pens {
      let r = s.bounds
      b = b.union(CGRect(x: r.minX, y: r.minY, width: r.maxX - r.minX, height: r.maxY - r.minY))
    }
    let pad = (pens.map(\.style.width).max() ?? 2) + 4
    let box = b.insetBy(dx: -pad, dy: -pad)
    let w = Int(size.width * scale)
    let h = Int(size.height * scale)
    guard w > 0, h > 0,
      let ctx = CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    ctx.translateBy(x: 0, y: CGFloat(h))
    ctx.scaleBy(x: scale, y: -scale)
    let mapper = CoordinateMapper(
      canvas: size, surface: box.size, viewport: Viewport(x: box.minX, y: box.minY, zoom: 1))
    for var s in pens {
      if let color { s.style.color = color }
      StrokeRenderer.draw(s, in: ctx, mapper: mapper)
    }
    return ctx.makeImage()
  }
}
