import CoreGraphics
import Foundation

/// The background layer of the canvas (Phase 1 of the design studio).
///
/// It belongs to the document, not to the view: it is saved with the session,
/// synced to the tablet, undoable, and exported as its own layer. It is never
/// merged into stroke data.
///
/// - `overlay`: transparent; ink floats over whatever is on the Mac screen.
/// - `studio`: an opaque surface in `color` covering the drawing display.
/// - `pattern` is drawn in either mode, anchored to canvas coordinates so it
///   pans and zooms with the ink.
public struct CanvasBackground: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, CaseIterable, Sendable {
        case overlay, studio
    }

    public enum Pattern: String, Codable, CaseIterable, Sendable {
        case none, grid, dots, graph, engineering

        /// Minor and major line spacing in canvas px (major = 0: no major lines).
        public var spacing: (minor: Double, major: Double) {
            switch self {
            case .none: return (0, 0)
            case .grid, .dots: return (48, 0)
            case .graph: return (12, 60)
            case .engineering: return (10, 100)
            }
        }
    }

    public var mode: Mode
    public var color: RGBA
    public var pattern: Pattern

    public init(mode: Mode = .overlay, color: RGBA = .white, pattern: Pattern = .none) {
        self.mode = mode
        self.color = color
        self.pattern = pattern
    }

    public static let overlay = CanvasBackground()

    /// Presets offered in both apps.
    public static let white = RGBA(1, 1, 1)
    public static let black = RGBA(0, 0, 0)
    public static let lightGray = RGBA(242.0 / 255, 242.0 / 255, 242.0 / 255)
    public static let darkGray = RGBA(32.0 / 255, 32.0 / 255, 32.0 / 255)

    public static func studio(_ color: RGBA, pattern: Pattern = .none) -> CanvasBackground {
        CanvasBackground(mode: .studio, color: color, pattern: pattern)
    }

    /// Relative luminance (sRGB approximation), 0 = black, 1 = white.
    public var luminance: Double { 0.2126 * color.r + 0.7152 * color.g + 0.0722 * color.b }

    /// A studio surface dark enough that ink and patterns should be light.
    public var isDark: Bool { mode == .studio && luminance < 0.5 }

    /// Pattern lines: light on dark surfaces, dark on light ones, neutral over the desktop.
    public var patternColor: RGBA {
        switch (mode, isDark) {
        // Strong enough to read on non-Retina external displays (1 px lines/dots).
        case (.overlay, _): return RGBA(0.5, 0.5, 0.5, 0.5)
        case (_, true): return RGBA(1, 1, 1, 0.3)
        default: return RGBA(0, 0, 0, 0.2)
        }
    }
}

/// Draws a `CanvasBackground` for a given view of the canvas.
public enum BackgroundRenderer {
    /// Fills `rect` (view points, top-left origin) with the background as seen through `mapper`.
    /// In overlay mode only the pattern is drawn, over transparency.
    public static func draw(_ bg: CanvasBackground, in ctx: CGContext, mapper: CoordinateMapper, rect: CGRect) {
        if bg.mode == .studio {
            ctx.setFillColor(bg.color.cgColor)
            ctx.fill(rect)
        }
        guard bg.pattern != .none else { return }
        let spacing = bg.pattern.spacing
        let scale = mapper.scale
        // Never draw lines closer than 6 points apart: a grey wash, not a grid.
        guard spacing.minor * scale >= 6 || (spacing.major > 0 && spacing.major * scale >= 6) else { return }
        let tl = mapper.unmap(CGPoint(x: rect.minX, y: rect.minY))
        let br = mapper.unmap(CGPoint(x: rect.maxX, y: rect.maxY))
        let minX = min(tl.x, br.x), maxX = max(tl.x, br.x), minY = min(tl.y, br.y), maxY = max(tl.y, br.y)
        let c = bg.patternColor
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.clip(to: rect)

        if bg.pattern == .dots {
            ctx.setFillColor(RGBA(c.r, c.g, c.b, min(1, c.a * 2.2)).cgColor)
            let r = max(1.6, 1.8 * min(scale, 2))
            forEachLine(from: minX, to: maxX, step: spacing.minor) { x in
                forEachLine(from: minY, to: maxY, step: spacing.minor) { y in
                    let p = mapper.map(x: x, y: y)
                    ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
                }
            }
            return
        }
        func lines(step: Double, width: CGFloat, alpha: Double) {
            guard step > 0, step * scale >= 6 else { return }
            ctx.setStrokeColor(RGBA(c.r, c.g, c.b, min(1, c.a * alpha)).cgColor)
            ctx.setLineWidth(width)
            forEachLine(from: minX, to: maxX, step: step) { x in
                let a = mapper.map(x: x, y: minY), b = mapper.map(x: x, y: maxY)
                ctx.move(to: a); ctx.addLine(to: b)
            }
            forEachLine(from: minY, to: maxY, step: step) { y in
                let a = mapper.map(x: minX, y: y), b = mapper.map(x: maxX, y: y)
                ctx.move(to: a); ctx.addLine(to: b)
            }
            ctx.strokePath()
        }
        lines(step: spacing.minor, width: 1, alpha: 1)
        if spacing.major > 0 { lines(step: spacing.major, width: 1.5, alpha: 1.8) }
    }

    private static func forEachLine(from a: Double, to b: Double, step: Double, _ body: (Double) -> Void) {
        guard step > 0, b > a, (b - a) / step < 4_000 else { return }
        var v = (a / step).rounded(.down) * step
        while v <= b {
            body(v)
            v += step
        }
    }
}

extension RGBA {
    public var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
}
