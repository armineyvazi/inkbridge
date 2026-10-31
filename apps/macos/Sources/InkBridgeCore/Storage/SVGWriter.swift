import CoreGraphics
import Foundation

/// Writes the visible ink as SVG in page (display point) coordinates, so it
/// lines up 1:1 with `annotations.png` and `full-page.png`.
///
/// Uses the same smoothing and width rules as `StrokeRenderer`. Pressure
/// strokes become one short path per segment (SVG, like Core Graphics, has a
/// single width per path). Constant-width strokes become one path.
public enum SVGWriter {
    public static func svg(_ strokes: [Stroke], mapper: CoordinateMapper) -> String {
        let w = mapper.canvas.width, h = mapper.canvas.height
        let page = CGRect(origin: .zero, size: mapper.canvas)
        var out = """
        <?xml version="1.0" encoding="UTF-8"?>
        <svg xmlns="http://www.w3.org/2000/svg" width="\(n(w))" height="\(n(h))" viewBox="0 0 \(n(w)) \(n(h))">
        <!-- InkBridge annotations; vector source of truth: strokes.json -->

        """
        for stroke in strokes where stroke.tool != .eraser && stroke.tool != .laser
            && StrokeRenderer.displayBounds(stroke, mapper: mapper).intersects(page) {
            out += group(stroke, mapper: mapper)
        }
        out += "</svg>\n"
        return out
    }

    private static func group(_ stroke: Stroke, mapper: CoordinateMapper) -> String {
        let c = stroke.style.color
        let color = "rgb(\(Int(c.r * 255)),\(Int(c.g * 255)),\(Int(c.b * 255)))"
        let (pts, pressures) = Smoothing.decimate(stroke.points.map(mapper.map), pressures: stroke.points.map(\.p), minDistance: 0.75)
        let scale = mapper.scale
        var g = "<g id=\"\(escape(stroke.id))\" data-tool=\"\(stroke.tool.rawValue)\" fill=\"none\" stroke=\"\(color)\" stroke-opacity=\"\(n(c.a))\" stroke-linecap=\"round\" stroke-linejoin=\"round\">\n"
        if pts.count == 1 {
            let r = StrokeRenderer.width(stroke.style, pressure: pressures[0]) * scale / 2
            g += "<circle cx=\"\(n(pts[0].x))\" cy=\"\(n(pts[0].y))\" r=\"\(n(r))\" fill=\"\(color)\" stroke=\"none\"/>\n"
        } else {
            let segs = Smoothing.catmullRom(pts, pressures: pressures)
            if stroke.style.pressureSensitive {
                for s in segs {
                    let width = StrokeRenderer.width(stroke.style, pressure: (s.startPressure + s.endPressure) / 2) * scale
                    g += "<path stroke-width=\"\(n(width))\" d=\"M\(p(s.start)) C\(p(s.control1)) \(p(s.control2)) \(p(s.end))\"/>\n"
                }
            } else {
                var d = "M\(p(segs[0].start))"
                for s in segs { d += " C\(p(s.control1)) \(p(s.control2)) \(p(s.end))" }
                g += "<path stroke-width=\"\(n(stroke.style.width * scale))\" d=\"\(d)\"/>\n"
            }
        }
        return g + "</g>\n"
    }

    private static func n<T: BinaryFloatingPoint>(_ v: T) -> String { String(format: "%.2f", Double(v)) }
    private static func p(_ pt: CGPoint) -> String { "\(n(pt.x)),\(n(pt.y))" }
    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
    }
}
