import CoreGraphics
import CoreText
import Foundation

/// Draws a diagram into a top-left-origin context through a `CoordinateMapper`.
/// Shared by the overlay, PNG export and PDF export, so they all match.
public enum DiagramRenderer {
    public struct Theme {
        public var stroke: CGColor
        public var fill: CGColor
        public var text: CGColor
        public var accent: CGColor

        public static func forBackground(_ bg: CanvasBackground) -> Theme {
            bg.isDark
                ? Theme(stroke: CGColor(srgbRed: 0.85, green: 0.88, blue: 0.95, alpha: 1), fill: CGColor(srgbRed: 0.13, green: 0.15, blue: 0.2, alpha: 0.95),
                        text: CGColor(srgbRed: 0.95, green: 0.96, blue: 1, alpha: 1), accent: CGColor(srgbRed: 0.35, green: 0.6, blue: 1, alpha: 1))
                : Theme(stroke: CGColor(srgbRed: 0.2, green: 0.24, blue: 0.32, alpha: 1), fill: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.96),
                        text: CGColor(srgbRed: 0.08, green: 0.1, blue: 0.14, alpha: 1), accent: CGColor(srgbRed: 0.13, green: 0.45, blue: 0.95, alpha: 1))
        }
    }

    /// `icon` returns a template image for an SF Symbol name (the app supplies it; nil = no icon).
    public static func draw(_ d: Diagram, in ctx: CGContext, mapper: CoordinateMapper, theme: Theme,
                            selection: Set<String> = [], icon: ((String) -> CGImage?)? = nil) {
        let s = CGFloat(mapper.scale)
        for e in d.edges { drawEdge(e, d, ctx, mapper, theme, s, selected: selection.contains(e.id)) }
        for n in d.nodes { drawNode(n, ctx, mapper, theme, s, selected: selection.contains(n.id), icon: icon) }
    }

    static func rect(_ r: CGRect, _ m: CoordinateMapper) -> CGRect {
        let a = m.map(x: Double(r.minX), y: Double(r.minY)), b = m.map(x: Double(r.maxX), y: Double(r.maxY))
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    private static func drawNode(_ n: DiagramNode, _ ctx: CGContext, _ m: CoordinateMapper, _ t: Theme, _ s: CGFloat,
                                 selected: Bool, icon: ((String) -> CGImage?)?) {
        let r = rect(n.frame, m)
        let c = n.component
        let path = shapePath(c.shape, r)
        ctx.saveGState()
        ctx.addPath(path)
        ctx.setFillColor(c.shape == .note ? CGColor(srgbRed: 1, green: 0.93, blue: 0.55, alpha: 0.95) : t.fill)
        ctx.fillPath()
        ctx.addPath(path)
        ctx.setStrokeColor(selected ? t.accent : t.stroke)
        ctx.setLineWidth(selected ? 2.5 : 1.4)
        ctx.strokePath()
        if c.shape == .cylinder {
            let h = min(r.height * 0.18, 14)
            ctx.addEllipse(in: CGRect(x: r.minX, y: r.minY, width: r.width, height: h * 2))
            ctx.strokePath()
        }
        if c.shape == .queue {
            for i in 1...3 { let x = r.maxX - CGFloat(i) * 9; ctx.move(to: CGPoint(x: x, y: r.minY + 6)); ctx.addLine(to: CGPoint(x: x, y: r.maxY - 6)) }
            ctx.strokePath()
        }
        ctx.restoreGState()
        if selected {  // resize handle
            ctx.setFillColor(t.accent)
            ctx.fill(CGRect(x: r.maxX - 5, y: r.maxY - 5, width: 10, height: 10))
        }
        let textColor = c.shape == .note ? CGColor(srgbRed: 0.1, green: 0.1, blue: 0.1, alpha: 1) : t.text
        let fontSize = max(8, min(15, 13 * s * 1.6))
        var top = r.minY + r.height * 0.18
        if let img = icon?(c.symbol), r.height > 40 * min(1, s * 1.6) {
            let side = min(22, r.height * 0.3)
            ctx.saveGState()
            let ir = CGRect(x: r.midX - side / 2, y: top, width: side, height: side)
            ctx.translateBy(x: 0, y: ir.maxY + ir.minY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.clip(to: ir, mask: img)
            ctx.setFillColor(selected ? t.accent : t.stroke)
            ctx.fill(ir)
            ctx.restoreGState()
            top += side + 4
        }
        text(n.label, at: CGPoint(x: r.midX, y: top), size: fontSize, bold: true, color: textColor, maxWidth: r.width - 8, ctx)
        if !n.detail.isEmpty {
            var y = top + fontSize * 1.4
            for line in n.detail.split(separator: "\n").prefix(12) where y < r.maxY - 4 {
                text(String(line), at: CGPoint(x: r.midX, y: y), size: fontSize * 0.8, bold: false, color: textColor, maxWidth: r.width - 8, ctx, mono: true)
                y += fontSize * 1.05
            }
        }
    }

    private static func drawEdge(_ e: DiagramEdge, _ d: Diagram, _ ctx: CGContext, _ m: CoordinateMapper, _ t: Theme, _ s: CGFloat, selected: Bool) {
        let pts = d.path(of: e).map { m.map(x: Double($0.x), y: Double($0.y)) }
        guard pts.count > 1 else { return }
        ctx.saveGState()
        ctx.setStrokeColor(selected ? t.accent : t.stroke)
        ctx.setLineWidth(selected ? 2.5 : 1.6)
        ctx.setLineDash(phase: 0, lengths: e.kind.dash)
        ctx.addLines(between: pts)
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])
        // Arrowhead at the target.
        let a = pts[pts.count - 2], b = pts[pts.count - 1]
        let ang = atan2(b.y - a.y, b.x - a.x), len: CGFloat = 10
        ctx.move(to: b)
        ctx.addLine(to: CGPoint(x: b.x - len * cos(ang - 0.4), y: b.y - len * sin(ang - 0.4)))
        ctx.addLine(to: CGPoint(x: b.x - len * cos(ang + 0.4), y: b.y - len * sin(ang + 0.4)))
        ctx.closePath()
        ctx.setFillColor(selected ? t.accent : t.stroke)
        if e.kind == .async || e.kind == .event { ctx.strokePath() } else { ctx.fillPath() }
        ctx.restoreGState()
        if !e.label.isEmpty {
            let mid = ConnectorRouter.midpoint(pts)
            text(e.label, at: CGPoint(x: mid.x, y: mid.y - 16), size: max(8, min(12, 11 * s * 1.6)), bold: false, color: t.text,
                 maxWidth: 160, ctx, plate: t.fill)
        }
    }

    public static func shapePath(_ shape: Component.Shape, _ r: CGRect) -> CGPath {
        let p = CGMutablePath()
        switch shape {
        case .box: p.addRect(r)
        case .rounded, .actor: p.addRoundedRect(in: r, cornerWidth: min(10, r.height / 4), cornerHeight: min(10, r.height / 4))
        case .stadium: p.addRoundedRect(in: r, cornerWidth: r.height / 2, cornerHeight: r.height / 2)
        case .cylinder:
            let h = min(r.height * 0.18, 14)
            p.move(to: CGPoint(x: r.minX, y: r.minY + h))
            p.addLine(to: CGPoint(x: r.minX, y: r.maxY - h))
            p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.maxY - h), control: CGPoint(x: r.midX, y: r.maxY + h))
            p.addLine(to: CGPoint(x: r.maxX, y: r.minY + h))
            p.addQuadCurve(to: CGPoint(x: r.minX, y: r.minY + h), control: CGPoint(x: r.midX, y: r.minY - h))
        case .diamond:
            p.addLines(between: [CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.midY), CGPoint(x: r.midX, y: r.maxY), CGPoint(x: r.minX, y: r.midY)])
            p.closeSubpath()
        case .parallelogram:
            let k = r.width * 0.12
            p.addLines(between: [CGPoint(x: r.minX + k, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX - k, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)])
            p.closeSubpath()
        case .note:
            let k = min(16, r.width * 0.12)
            p.addLines(between: [r.origin, CGPoint(x: r.maxX - k, y: r.minY), CGPoint(x: r.maxX, y: r.minY + k), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)])
            p.closeSubpath()
        case .queue: p.addRoundedRect(in: r, cornerWidth: r.height / 2, cornerHeight: r.height / 2)
        case .hexagon:
            let k = r.width * 0.2
            p.addLines(between: [CGPoint(x: r.minX + k, y: r.minY), CGPoint(x: r.maxX - k, y: r.minY), CGPoint(x: r.maxX, y: r.midY),
                                 CGPoint(x: r.maxX - k, y: r.maxY), CGPoint(x: r.minX + k, y: r.maxY), CGPoint(x: r.minX, y: r.midY)])
            p.closeSubpath()
        case .cloud: p.addEllipse(in: r)
        }
        return p
    }

    /// Centred single-line text in a flipped (top-left) context.
    static func text(_ s: String, at p: CGPoint, size: CGFloat, bold: Bool, color: CGColor, maxWidth: CGFloat, _ ctx: CGContext,
                     mono: Bool = false, plate: CGColor? = nil) {
        let font = CTFontCreateWithName((mono ? "Menlo" : (bold ? "Helvetica-Bold" : "Helvetica")) as CFString, size, nil)
        let attr = NSAttributedString(string: s, attributes: [kCTFontAttributeName as NSAttributedString.Key: font,
                                                             kCTForegroundColorAttributeName as NSAttributedString.Key: color])
        var line = CTLineCreateWithAttributedString(attr)
        var w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        if w > maxWidth, maxWidth > 10,
           let ell = CTLineCreateTruncatedLine(line, Double(maxWidth), .end,
                                               CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: [kCTFontAttributeName as NSAttributedString.Key: font, kCTForegroundColorAttributeName as NSAttributedString.Key: color]))) {
            line = ell
            w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        }
        if let plate {
            ctx.setFillColor(plate)
            ctx.fill(CGRect(x: p.x - w / 2 - 4, y: p.y - 2, width: w + 8, height: size * 1.3))
        }
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(x: p.x - w / 2, y: p.y + size)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}
