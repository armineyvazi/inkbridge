import Foundation

/// An sRGB color with straight (non-premultiplied) alpha.
public struct RGBA: Equatable, Hashable, Codable, Sendable {
    public var r: Double, g: Double, b: Double, a: Double

    public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    public static let black = RGBA(0.08, 0.08, 0.09)
    public static let red = RGBA(0.92, 0.23, 0.20)
    public static let blue = RGBA(0.13, 0.45, 0.95)
    public static let green = RGBA(0.16, 0.68, 0.33)
    public static let yellow = RGBA(1.0, 0.86, 0.10)
    public static let white = RGBA(1, 1, 1)

    /// `#rrggbbaa`, the protocol's color encoding.
    public var hex: String {
        func byte(_ v: Double) -> String { String(format: "%02x", Int((min(max(v, 0), 1) * 255).rounded())) }
        return "#" + byte(r) + byte(g) + byte(b) + byte(a)
    }

    public init?(hex: String) {
        guard hex.count == 9, hex.first == "#", let v = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        self.init(Double(v >> 24 & 0xff) / 255, Double(v >> 16 & 0xff) / 255, Double(v >> 8 & 0xff) / 255, Double(v & 0xff) / 255)
    }
}

/// How a stroke looks. Captured when the stroke begins so later toolbar
/// changes do not restyle strokes that are already on screen.
public struct StrokeStyle: Equatable, Codable, Sendable {
    public var color: RGBA
    /// Nominal line width in **canvas px** at full pressure (scales with zoom).
    public var width: Double
    /// Whether width follows pressure. Off for highlighter and for devices
    /// that do not report pressure.
    public var pressureSensitive: Bool

    public init(color: RGBA, width: Double, pressureSensitive: Bool) {
        self.color = color
        self.width = width
        self.pressureSensitive = pressureSensitive
    }
}

/// A single continuous stylus stroke.
public struct Stroke: Identifiable, Equatable, Codable, Sendable {
    public let id: String
    public let tool: Tool
    public var style: StrokeStyle
    /// Samples in normalized device-surface coordinates.
    public var points: [InkPoint]

    public init(id: String, tool: Tool, style: StrokeStyle, points: [InkPoint]) {
        self.id = id
        self.tool = tool
        self.style = style
        self.points = points
    }

    /// Axis-aligned bounds in normalized coordinates.
    public var bounds: (minX: Double, minY: Double, maxX: Double, maxY: Double) {
        var b = (minX: Double.infinity, minY: Double.infinity, maxX: -Double.infinity, maxY: -Double.infinity)
        for p in points {
            b.minX = min(b.minX, p.x)
            b.minY = min(b.minY, p.y)
            b.maxX = max(b.maxX, p.x)
            b.maxY = max(b.maxY, p.y)
        }
        return b
    }
}
