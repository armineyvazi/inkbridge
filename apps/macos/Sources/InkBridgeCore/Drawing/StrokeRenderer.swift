import CoreGraphics

/// Draws strokes into any Core Graphics context: the live overlay view,
/// an offscreen bitmap for PNG export, or a PDF context.
///
/// Expects a top-left-origin (flipped) context in display points.
public enum StrokeRenderer {
    /// Width multiplier at zero pressure; keeps light touches visible.
    static let minPressureFactor = 0.3

    public static func draw(_ strokes: [Stroke], in ctx: CGContext, mapper: CoordinateMapper) {
        // On an infinite canvas most strokes can be off-screen; skip them cheaply.
        let clip = ctx.boundingBoxOfClipPath
        for s in strokes where displayBounds(s, mapper: mapper).intersects(clip) {
            draw(s, in: ctx, mapper: mapper)
        }
    }

    /// Stroke bounds in display points, padded for line width.
    public static func displayBounds(_ stroke: Stroke, mapper: CoordinateMapper) -> CGRect {
        let b = stroke.bounds
        guard b.minX.isFinite else { return .null }
        let a = mapper.map(x: b.minX, y: b.minY), c = mapper.map(x: b.maxX, y: b.maxY)
        let pad = stroke.style.width * mapper.scale + 2
        return CGRect(x: min(a.x, c.x), y: min(a.y, c.y), width: abs(c.x - a.x), height: abs(c.y - a.y))
            .insetBy(dx: -pad, dy: -pad)
    }

    public static func draw(_ stroke: Stroke, in ctx: CGContext, mapper: CoordinateMapper, opacity: Double = 1) {
        guard !stroke.points.isEmpty, stroke.tool != .eraser else { return }
        let mapped = stroke.points.map(mapper.map)
        let (points, pressures) = Smoothing.decimate(
            mapped, pressures: stroke.points.map(\.p), minDistance: 0.75
        )
        let c = stroke.style.color
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setStrokeColor(CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a * opacity))
        ctx.setFillColor(CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a * opacity))

        // Widths are in canvas px; convert to display points at the current zoom.
        let scale = mapper.scale
        if stroke.tool == .laser {
            ctx.setShadow(offset: .zero, blur: 8, color: CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 0.8 * opacity))
        }

        if points.count == 1 {
            let w = width(stroke.style, pressure: pressures[0]) * scale
            ctx.fillEllipse(in: CGRect(x: points[0].x - w / 2, y: points[0].y - w / 2, width: w, height: w))
            return
        }

        let segments = Smoothing.catmullRom(points, pressures: pressures)
        if stroke.style.pressureSensitive {
            // Core Graphics strokes a path at one width, so variable width is
            // drawn as one short path per segment. Round caps hide the joins.
            for seg in segments {
                ctx.setLineWidth(width(stroke.style, pressure: (seg.startPressure + seg.endPressure) / 2) * scale)
                ctx.beginPath()
                ctx.move(to: seg.start)
                ctx.addCurve(to: seg.end, control1: seg.control1, control2: seg.control2)
                ctx.strokePath()
            }
        } else {
            // One path, so translucent strokes (highlighter) don't darken where
            // consecutive segments overlap.
            ctx.setLineWidth(stroke.style.width * scale)
            ctx.beginPath()
            ctx.move(to: segments[0].start)
            for seg in segments {
                ctx.addCurve(to: seg.end, control1: seg.control1, control2: seg.control2)
            }
            ctx.strokePath()
        }
    }

    static func width(_ style: StrokeStyle, pressure: Double) -> CGFloat {
        guard style.pressureSensitive else { return style.width }
        let p = min(max(pressure, 0), 1)
        return style.width * (minPressureFactor + (1 - minPressureFactor) * p)
    }

    /// The canvas area touched by the last `tail` samples of a stroke, padded
    /// for line width and smoothing overshoot. Used to invalidate only the
    /// part of the overlay that changed.
    public static func dirtyRect(for stroke: Stroke, tail: Int, mapper: CoordinateMapper) -> CGRect {
        // Two extra samples: Catmull-Rom tangents reach one point back and the
        // previous last span is re-curved once a new point arrives.
        let pts = stroke.points.suffix(tail + 2).map(mapper.map)
        guard let first = pts.first else { return .null }
        var r = CGRect(origin: first, size: .zero)
        for p in pts.dropFirst() { r = r.union(CGRect(origin: p, size: .zero)) }
        let pad = stroke.style.width * mapper.scale + (stroke.tool == .laser ? 16 : 4)
        return r.insetBy(dx: -pad, dy: -pad)
    }
}
