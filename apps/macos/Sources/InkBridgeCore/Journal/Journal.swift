import CoreGraphics
import Foundation

/// Calendar-day logic for the Daily Journal. Days follow real local calendar
/// boundaries (including DST days of 23 or 25 hours), never a rolling 24 h.
public enum JournalCalendar {
    static func calendar(_ tz: TimeZone) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = tz
        return c
    }

    /// "2026-11-01" for `date` as seen in `tz`.
    public static func dayID(for date: Date, in tz: TimeZone = .current) -> String {
        let c = calendar(tz).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    /// Start of the day `id` in `tz`.
    public static func start(of id: String, in tz: TimeZone = .current) -> Date? {
        let parts = id.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(parts[1]), (1...31).contains(parts[2]) else { return nil }
        return calendar(tz).date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// The next local midnight strictly after `date`.
    public static func nextMidnight(after date: Date, in tz: TimeZone = .current) -> Date {
        let c = calendar(tz)
        return c.nextDate(after: date, matching: DateComponents(hour: 0, minute: 0, second: 0), matchingPolicy: .nextTime) ?? date.addingTimeInterval(86_400)
    }

    public static func offset(_ id: String, by days: Int, in tz: TimeZone = .current) -> String? {
        guard let s = start(of: id, in: tz), let d = calendar(tz).date(byAdding: .day, value: days, to: s) else { return nil }
        return dayID(for: d, in: tz)
    }

    public static func isValid(_ id: String) -> Bool {
        id.count == 10 && start(of: id, in: TimeZone(identifier: "UTC")!) != nil && dayID(for: start(of: id, in: TimeZone(identifier: "UTC")!)!, in: TimeZone(identifier: "UTC")!) == id
    }
}

/// One timestamped item on a day: a typed note, a task, or a handwriting session.
public struct JournalEntry: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case note, task, ink }

    public var id: String
    public var kind: Kind
    public var text: String
    public var done: Bool
    /// UTC instants; shown in the local time zone.
    public var createdAt: Date
    public var modifiedAt: Date
    /// For `.ink`: the strokes written in this capture session.
    public var strokeIDs: [String]

    public init(id: String = "j-\(UUID().uuidString.prefix(8))", kind: Kind, text: String = "", done: Bool = false,
                createdAt: Date, modifiedAt: Date? = nil, strokeIDs: [String] = []) {
        self.id = id
        self.kind = kind
        self.text = text
        self.done = done
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt ?? createdAt
        self.strokeIDs = strokeIDs
    }
}

/// A day's journal: title and timestamped entries. Ink lives in the day's
/// session files (SessionArchive) next to it.
public struct JournalPage: Codable, Equatable, Sendable {
    public var day: String
    public var title: String = ""
    public var entries: [JournalEntry] = []
    /// The day's time zone when it was first written (for display and audits).
    public var timeZone: String = TimeZone.current.identifier

    public init(day: String, title: String = "", entries: [JournalEntry] = []) {
        self.day = day
        self.title = title
        self.entries = entries
    }

    public var isEmpty: Bool { title.isEmpty && entries.isEmpty }

    // MARK: Editing (every change stamps modifiedAt)

    public mutating func addNote(_ text: String, kind: JournalEntry.Kind = .note, at now: Date) -> JournalEntry {
        let e = JournalEntry(kind: kind, text: String(text.prefix(4_000)), createdAt: Self.ms(now))
        entries.append(e)
        return e
    }

    public mutating func update(_ id: String, text: String? = nil, done: Bool? = nil, at now: Date) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        if let text { entries[i].text = String(text.prefix(4_000)) }
        if let done { entries[i].done = done }
        entries[i].modifiedAt = Self.ms(now)
    }

    public mutating func remove(_ id: String) {
        entries.removeAll { $0.id == id }
    }

    /// Groups handwriting into capture sessions: strokes within `gap` of the
    /// session's last stroke join it (09:15 → 09:22 is one entry); a longer
    /// pause starts a new timestamped entry. Strokes no longer in the
    /// document (erased, undone) are dropped from their entries.
    public mutating func trackInk(present: [String], at now: Date, gap: TimeInterval = 120) {
        let presentSet = Set(present)
        for i in entries.indices where entries[i].kind == .ink {
            entries[i].strokeIDs.removeAll { !presentSet.contains($0) }
        }
        entries.removeAll { $0.kind == .ink && $0.strokeIDs.isEmpty }
        let known = Set(entries.flatMap(\.strokeIDs))
        let new = present.filter { !known.contains($0) }
        guard !new.isEmpty else { return }
        if let i = entries.lastIndex(where: { $0.kind == .ink }), now.timeIntervalSince(entries[i].modifiedAt) <= gap {
            entries[i].strokeIDs += new
            entries[i].modifiedAt = Self.ms(now)
        } else {
            entries.append(JournalEntry(kind: .ink, text: "", createdAt: Self.ms(now), strokeIDs: new))
        }
    }

    /// Where each handwriting session's time label goes (top-left of its ink, canvas px).
    /// Computed once per document change, not per frame.
    public func inkAnchors(_ strokes: [Stroke]) -> [(date: Date, point: CGPoint)] {
        let byID = Dictionary(strokes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return entries.compactMap { e -> (Date, CGPoint)? in
            guard e.kind == .ink else { return nil }
            var minX = Double.infinity, minY = Double.infinity
            for id in e.strokeIDs {
                guard let b = byID[id]?.bounds else { continue }
                minX = min(minX, b.minX); minY = min(minY, b.minY)
            }
            return minX.isFinite ? (e.createdAt, CGPoint(x: minX, y: minY)) : nil
        }
    }

    /// Timestamps are kept to the millisecond, the precision they are stored with.
    static func ms(_ d: Date) -> Date { Date(timeIntervalSince1970: (d.timeIntervalSince1970 * 1000).rounded() / 1000) }
}

/// Where journal days live. Separate from projects (`ProjectStore`).
///
///     <root>/2026/11/2026-11-01/journal.json    title + timestamped entries
///                              /session.json    ink metadata (SessionArchive)
///                              /strokes.json    editable strokes
///                              /attachments/
public final class JournalStore {
    public let root: URL
    private let fm = FileManager.default

    public init(root: URL) { self.root = root }

    public static var defaultRoot: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("InkBridge Journal")
    }

    public func dayDir(_ day: String) -> URL {
        root.appendingPathComponent(String(day.prefix(4))).appendingPathComponent(String(day.dropFirst(5).prefix(2))).appendingPathComponent(day)
    }

    /// UTC ISO-8601 with milliseconds ("2026-11-01T05:45:00.123Z"): unambiguous and
    /// exact enough that a reloaded timestamp equals the one recorded.
    /// One shared formatter (ISO8601DateFormatter is thread-safe). Creating one
    /// per timestamp made a 300-entry page save take ~80 ms.
    nonisolated(unsafe) static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) static let isoPlain = ISO8601DateFormatter()

    static func isoFormatter() -> ISO8601DateFormatter { iso }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, enc in
            // Round to whole milliseconds so encode → decode is lossless.
            let ms = (date.timeIntervalSince1970 * 1000).rounded() / 1000
            var c = enc.singleValueContainer()
            try c.encode(isoFormatter().string(from: Date(timeIntervalSince1970: ms)))
        }
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            if let date = iso.date(from: s) ?? isoPlain.date(from: s) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: dec.codingPath, debugDescription: "bad date \(s)"))
        }
        return d
    }()

    public func loadPage(_ day: String) -> JournalPage {
        guard let data = try? Data(contentsOf: dayDir(day).appendingPathComponent("journal.json")),
              let page = try? Self.decoder.decode(JournalPage.self, from: data) else { return JournalPage(day: day) }
        return page
    }

    /// Atomic write (temp + rename): a crash leaves the previous version.
    public func savePage(_ page: JournalPage) throws {
        guard JournalCalendar.isValid(page.day) else { throw StorageError.invalidName(page.day) }
        let dir = dayDir(page.day)
        do {
            try fm.createDirectory(at: dir.appendingPathComponent("attachments"), withIntermediateDirectories: true)
            try Self.encoder.encode(page).write(to: dir.appendingPathComponent("journal.json"), options: .atomic)
        } catch { throw StorageError.from(error, path: dir.path) }
    }

    /// Days that have a journal page or ink, newest first.
    public func days() -> [String] {
        var out: [String] = []
        for y in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] where y.count == 4 {
            for m in (try? fm.contentsOfDirectory(atPath: root.appendingPathComponent(y).path)) ?? [] {
                for d in (try? fm.contentsOfDirectory(atPath: root.appendingPathComponent(y).appendingPathComponent(m).path)) ?? []
                where JournalCalendar.isValid(d) {
                    let dir = dayDir(d)
                    if fm.fileExists(atPath: dir.appendingPathComponent("journal.json").path)
                        || fm.fileExists(atPath: dir.appendingPathComponent("strokes.json").path) { out.append(d) }
                }
            }
        }
        return out.sorted(by: >)
    }

    public struct SearchHit: Equatable, Sendable {
        public var day: String
        public var entry: JournalEntry?
        public var snippet: String
    }

    /// Case-insensitive search over titles and typed entries of every day.
    public func search(_ query: String) -> [SearchHit] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        var hits: [SearchHit] = []
        for d in days() {
            let p = loadPage(d)
            if p.title.localizedCaseInsensitiveContains(q) { hits.append(SearchHit(day: d, entry: nil, snippet: p.title)) }
            for e in p.entries where e.text.localizedCaseInsensitiveContains(q) {
                hits.append(SearchHit(day: d, entry: e, snippet: String(e.text.prefix(120))))
            }
        }
        return hits
    }

    /// Bytes used by the journal folder.
    public func usageBytes() -> Int64 {
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in e { total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return total
    }
}
