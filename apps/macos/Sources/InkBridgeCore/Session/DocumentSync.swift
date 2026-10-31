import Foundation

/// Keeps a device's mirror of the document in step with the host's
/// `StrokeStore`, by diffing stroke IDs rather than sending snapshots.
///
/// The host owns the document (ADR-006). After every change, `diff` returns
/// only what the device lacks (`stroke.*` with style) and what it must drop
/// (`doc.remove`). A full transfer happens once per connection (`resync`).
public struct DocumentSync: Sendable {
    /// Stroke IDs the device currently has.
    public private(set) var known: Set<String> = []

    public init() {}

    /// The device drew this stroke itself, so it already has it. If the host
    /// did not keep it (eraser, laser), the next `diff` tells the device to drop it.
    public mutating func markKnown(_ id: String) {
        known.insert(id)
    }

    /// Everything a freshly connected device needs: reset, then all strokes.
    public mutating func resync(_ strokes: [Stroke]) -> [Payload] {
        known = Set(strokes.map(\.id))
        return [.docReset] + strokes.flatMap(Self.payloads(for:))
    }

    /// Messages that bring the device from `known` to `strokes`.
    public mutating func diff(_ strokes: [Stroke]) -> [Payload] {
        let current = Set(strokes.map(\.id))
        let removed = known.subtracting(current).sorted()
        var out: [Payload] = stride(from: 0, to: removed.count, by: MessageCodec.maxIDsPerMessage).map {
            .docRemove(strokeIDs: Array(removed[$0..<min($0 + MessageCodec.maxIDsPerMessage, removed.count)]))
        }
        // Keep document order so z-order matches on both screens.
        for stroke in strokes where !known.contains(stroke.id) {
            out += Self.payloads(for: stroke)
        }
        known = current
        return out
    }

    public mutating func reset() { known.removeAll() }

    /// A whole stroke as wire messages, split to respect the per-message point limit.
    public static func payloads(for stroke: Stroke) -> [Payload] {
        guard let first = stroke.points.first else { return [] }
        let style = WireStyle(color: stroke.style.color, width: stroke.style.width)
        var out: [Payload] = [.strokeBegin(strokeID: stroke.id, tool: stroke.tool, point: first, style: style)]
        let rest = Array(stroke.points.dropFirst())
        for start in stride(from: 0, to: rest.count, by: MessageCodec.maxPointsPerMessage) {
            out.append(.strokePoint(strokeID: stroke.id, points: Array(rest[start..<min(start + MessageCodec.maxPointsPerMessage, rest.count)])))
        }
        out.append(.strokeEnd(strokeID: stroke.id))
        return out
    }
}
