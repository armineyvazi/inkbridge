import CoreGraphics
import Foundation

/// The drawing document: committed strokes, strokes in progress, and an
/// undo history of whole-stroke operations.
///
/// Every user-visible change is a `Command`, so undo/redo, erase and clear
/// share one mechanism and clearing the canvas is always recoverable.
///
/// Not thread-safe; owned by the main thread.
public final class StrokeStore {
    enum Command {
        case add(Stroke)
        /// Strokes removed by one eraser gesture, with their original indices.
        case erase([(index: Int, stroke: Stroke)])
        case clear([Stroke])
        /// Background layer change; strokes are untouched.
        case background(from: CanvasBackground, to: CanvasBackground)
    }

    public private(set) var strokes: [Stroke] = []
    public private(set) var active: [String: Stroke] = [:]
    /// Finished laser strokes and the time they ended; they fade then vanish
    /// and never enter the undo history.
    public private(set) var laser: [(stroke: Stroke, endedAt: TimeInterval)] = []

    private var undoStack: [Command] = []
    private var redoStack: [Command] = []
    /// Strokes the current eraser gesture has removed so far, keyed by eraser stroke ID.
    private var pendingErase: [String: [(index: Int, stroke: Stroke)]] = [:]

    /// Bumped whenever `strokes` changes, so renderers can cache committed ink.
    public private(set) var revision = 0

    /// The background layer. Independent of strokes: changing it never touches ink.
    public private(set) var background = CanvasBackground.overlay
    /// Bumped on every background change (including undo/redo). Sent with
    /// `canvas.background` so a tablet never applies an older state over a newer one.
    public private(set) var backgroundRevision: UInt64 = 0
    /// Changes whenever strokes or background change; for autosave.
    public var documentVersion: Int { revision + Int(backgroundRevision) }

    /// Eraser radius in canvas px. The coordinator converts the toolbar's
    /// on-screen size using the current zoom.
    public var eraserRadius = 20.0
    /// How long a laser stroke stays visible after pen-up.
    public static let laserLifetime: TimeInterval = 1.2

    public init() {}

    /// Bounding box of all committed ink in canvas px, or nil when empty.
    public var contentBounds: CGRect? {
        var r: CGRect?
        for s in strokes where !s.points.isEmpty {
            let b = s.bounds
            let pad = s.style.width / 2
            let sr = CGRect(x: b.minX - pad, y: b.minY - pad, width: b.maxX - b.minX + 2 * pad, height: b.maxY - b.minY + 2 * pad)
            r = r.map { $0.union(sr) } ?? sr
        }
        return r
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    // MARK: Stroke lifecycle

    public func begin(id: String, tool: Tool, style: StrokeStyle, point: InkPoint) {
        if active[id] != nil { return }
        active[id] = Stroke(id: id, tool: tool, style: style, points: [point])
        if tool == .eraser {
            pendingErase[id] = []
            erase(along: [point], gesture: id)
        }
    }

    /// Appends samples; returns the stroke so callers can compute dirty rects.
    @discardableResult
    public func append(id: String, points: [InkPoint]) -> Stroke? {
        guard var stroke = active[id] else { return nil }
        let previous = stroke.points.last
        stroke.points.append(contentsOf: points)
        active[id] = stroke
        // Include the previous sample so the gap between batches is swept too.
        if stroke.tool == .eraser { erase(along: (previous.map { [$0] } ?? []) + points, gesture: id) }
        return stroke
    }

    public func end(id: String, now: TimeInterval = Date().timeIntervalSinceReferenceDate) {
        guard let stroke = active.removeValue(forKey: id) else { return }
        switch stroke.tool {
        case .eraser:
            let removed = pendingErase.removeValue(forKey: id) ?? []
            if !removed.isEmpty { record(.erase(removed)) }
        case .laser:
            laser.append((stroke, now))
        case .pen, .highlighter:
            strokes.append(stroke)
            revision += 1
            record(.add(stroke))
        }
    }

    /// Discards a stroke in progress. An eraser gesture is rolled back.
    public func cancel(id: String) {
        guard let stroke = active.removeValue(forKey: id) else { return }
        if stroke.tool == .eraser, let removed = pendingErase.removeValue(forKey: id), !removed.isEmpty {
            restore(removed)
        }
    }

    /// Commits every in-progress stroke, e.g. when the device disconnects mid-stroke.
    public func endAll() {
        for id in Array(active.keys) { end(id: id) }
    }

    /// Drops faded laser strokes. Returns whether anything is still fading.
    @discardableResult
    public func pruneLaser(now: TimeInterval) -> Bool {
        laser.removeAll { now - $0.endedAt > Self.laserLifetime }
        return !laser.isEmpty
    }

    // MARK: Editing

    public func clear() {
        guard !strokes.isEmpty else { return }
        let removed = strokes
        strokes.removeAll()
        revision += 1
        record(.clear(removed))
    }

    /// Changes the background as one undoable step. Returns false if nothing changed.
    @discardableResult
    public func setBackground(_ bg: CanvasBackground) -> Bool {
        guard bg != background else { return false }
        let old = background
        applyBackground(bg)
        record(.background(from: old, to: bg))
        return true
    }

    private func applyBackground(_ bg: CanvasBackground) {
        background = bg
        backgroundRevision += 1
    }

    public func undo() {
        guard let command = undoStack.popLast() else { return }
        switch command {
        case let .background(from, _):
            applyBackground(from)
            redoStack.append(command)
            return
        case .add(let s):
            strokes.removeAll { $0.id == s.id }
        case .erase(let removed):
            restore(removed)
        case .clear(let removed):
            strokes = removed + strokes
        }
        revision += 1
        redoStack.append(command)
    }

    public func redo() {
        guard let command = redoStack.popLast() else { return }
        switch command {
        case let .background(_, to):
            applyBackground(to)
            undoStack.append(command)
            return
        case .add(let s):
            strokes.append(s)
        case .erase(let removed):
            let ids = Set(removed.map(\.stroke.id))
            strokes.removeAll { ids.contains($0.id) }
        case .clear(let removed):
            let ids = Set(removed.map(\.id))
            strokes.removeAll { ids.contains($0.id) }
        }
        revision += 1
        undoStack.append(command)
    }

    /// Replaces the document, e.g. when restoring a saved session.
    public func load(_ strokes: [Stroke], background: CanvasBackground? = nil) {
        if let background { applyBackground(background) }
        self.strokes = strokes
        active.removeAll()
        undoStack.removeAll()
        redoStack.removeAll()
        revision += 1
    }

    private func record(_ command: Command) {
        undoStack.append(command)
        redoStack.removeAll()
    }

    private func restore(_ removed: [(index: Int, stroke: Stroke)]) {
        // Each index was recorded at the moment of removal, so undoing the
        // removals in reverse order reproduces the original array exactly.
        for item in removed.reversed() {
            strokes.insert(item.stroke, at: min(item.index, strokes.count))
        }
        revision += 1
    }

    // MARK: Eraser

    /// Removes every stroke within `eraserRadius` of the eraser path.
    ///
    /// The path is tested segment by segment, not sample by sample: a fast
    /// swipe can place consecutive samples on either side of a thin line,
    /// and a point test would miss it.
    private func erase(along path: [InkPoint], gesture: String) {
        guard !path.isEmpty else { return }
        let sweep = path.count == 1 ? [(path[0], path[0])] : Array(zip(path, path.dropFirst()))
        var removedAny = false
        var i = 0
        while i < strokes.count {
            if sweep.contains(where: { hits(strokes[i], $0.0, $0.1) }) {
                pendingErase[gesture, default: []].append((i, strokes[i]))
                strokes.remove(at: i)
                removedAny = true
            } else {
                i += 1
            }
        }
        if removedAny { revision += 1 }
    }

    /// Whether the eraser segment a→b passes within the eraser radius of `stroke`.
    func hits(_ stroke: Stroke, _ a: InkPoint, _ b: InkPoint) -> Bool {
        let r = eraserRadius + stroke.style.width / 2
        let bb = stroke.bounds
        guard max(a.x, b.x) >= bb.minX - r, min(a.x, b.x) <= bb.maxX + r,
              max(a.y, b.y) >= bb.minY - r, min(a.y, b.y) <= bb.maxY + r else { return false }
        let e0 = scaled(a), e1 = scaled(b)
        let pts = stroke.points.map(scaled)
        if pts.count == 1 { return Geometry.segmentDistance(pts[0], e0, e1) <= r }
        for j in 1..<pts.count where Geometry.segmentsDistance(e0, e1, pts[j - 1], pts[j]) <= r {
            return true
        }
        return false
    }

    private func scaled(_ p: InkPoint) -> SIMD2<Double> { SIMD2(p.x, p.y) }
}

/// 2-D distance helpers for hit testing.
enum Geometry {
    static func segmentDistance(_ p: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
        let d = b - a
        let len2 = (d * d).sum()
        guard len2 > 0 else { return length(p - a) }
        let t = max(0, min(1, ((p - a) * d).sum() / len2))
        return length(p - (a + t * d))
    }

    /// Minimum distance between segments ab and cd (zero if they cross).
    static func segmentsDistance(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>, _ d: SIMD2<Double>) -> Double {
        if intersects(a, b, c, d) { return 0 }
        return min(segmentDistance(a, c, d), segmentDistance(b, c, d), segmentDistance(c, a, b), segmentDistance(d, a, b))
    }

    private static func cross(_ o: SIMD2<Double>, _ p: SIMD2<Double>, _ q: SIMD2<Double>) -> Double {
        (p.x - o.x) * (q.y - o.y) - (p.y - o.y) * (q.x - o.x)
    }

    private static func intersects(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>, _ d: SIMD2<Double>) -> Bool {
        let d1 = cross(c, d, a), d2 = cross(c, d, b), d3 = cross(a, b, c), d4 = cross(a, b, d)
        return ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0))
    }

    private static func length(_ v: SIMD2<Double>) -> Double { (v * v).sum().squareRoot() }
}
