import Foundation

/// The selected tool and each tool's size: a **preference**, separate from document data.
///
/// Sizes are canvas px (1 = one tablet pixel at 100 % zoom), the unit strokes are
/// stored in, so a size means the same thickness on the page whatever the zoom or the
/// Mac display. Renderers convert at the boundary (`width × mapper.scale` here,
/// `width × zoom` on the tablet). Pen and highlighter: line width at full pressure.
/// Eraser: radius. A stroke copies the size when it begins; changing a size never
/// touches strokes that already exist.
///
/// The Mac is the source of truth. The tablet edits optimistically and sends
/// `tool.request`; the Mac applies requests in arrival order (last writer wins) and
/// answers every change with `tool.state`. Limits and presets are shared with the
/// tablet through `protocol/fixtures/tool-sizes.json`.
public struct ToolSettings: Equatable, Codable, Sendable {
  public var tool: Tool
  public var pen: Double
  public var highlighter: Double
  public var eraser: Double

  public init(
    tool: Tool = .pen, pen: Double = ToolSize.pen.defaultSize,
    highlighter: Double = ToolSize.highlighter.defaultSize,
    eraser: Double = ToolSize.eraser.defaultSize
  ) {
    self.tool = tool
    self.pen = pen
    self.highlighter = highlighter
    self.eraser = eraser
  }

  /// `nil` for the laser (fixed size).
  public func size(_ t: Tool) -> Double? {
    switch t {
    case .pen: return pen
    case .highlighter: return highlighter
    case .eraser: return eraser
    case .laser: return nil
    }
  }

  /// Sets `t`'s size, clamped to its range. Other tools keep theirs.
  public mutating func setSize(_ t: Tool, _ v: Double) {
    guard let spec = ToolSize(tool: t) else { return }
    switch t {
    case .pen: pen = spec.clamp(v)
    case .highlighter: highlighter = spec.clamp(v)
    case .eraser: eraser = spec.clamp(v)
    case .laser: break
    }
  }

  public var sizes: [Tool: Double] { [.pen: pen, .highlighter: highlighter, .eraser: eraser] }
}

/// Limits, default and presets of a sizable tool, in canvas px.
public enum ToolSize: String, CaseIterable, Sendable {
  case pen, highlighter, eraser

  public init?(tool: Tool) { self.init(rawValue: tool.rawValue) }

  public var tool: Tool { Tool(rawValue: rawValue)! }

  public var defaultSize: Double {
    switch self {
    case .pen: 4
    case .highlighter: 36
    case .eraser: 28
    }
  }

  public var range: ClosedRange<Double> {
    switch self {
    case .pen: 0.5...24
    case .highlighter: 6...96
    case .eraser: 4...160
    }
  }

  /// XS, S, M, L, XL.
  public var presets: [Double] {
    switch self {
    case .pen: [1.5, 3, 4.5, 7, 11]
    case .highlighter: [16, 24, 36, 52, 72]
    case .eraser: [8, 16, 28, 48, 80]
    }
  }

  public static let presetLabels = ["XS", "S", "M", "L", "XL"]

  public func clamp(_ v: Double) -> Double {
    v.isFinite ? min(max(v, range.lowerBound), range.upperBound) : defaultSize
  }

  /// One − / + step: increments grow with the size (0.5 below 6, 1 below 12, 2 below
  /// 24, 4 below 48, else 8); off-grid values snap to the grid. Same rule as the tablet.
  public func step(_ v: Double, up: Bool) -> Double {
    func increment(_ x: Double) -> Double { x < 6 ? 0.5 : x < 12 ? 1 : x < 24 ? 2 : x < 48 ? 4 : 8 }
    let r: Double
    if up {
      let inc = increment(v)
      r = (v / inc + 1e-9).rounded(.down) * inc + inc
    } else {
      let inc = increment(v - 1e-9)
      r = (v / inc - 1e-9).rounded(.up) * inc - inc
    }
    return clamp(r)
  }
}
