import CoreGraphics

/// A cubic Bézier segment.
public struct CubicSegment: Equatable, Sendable {
  public var start: CGPoint, control1: CGPoint, control2: CGPoint, end: CGPoint
  /// Pressure at `start` and `end`, used for width interpolation.
  public var startPressure: Double, endPressure: Double
}

/// Catmull-Rom smoothing expressed as cubic Bézier segments.
///
/// Catmull-Rom passes through every input sample, so the curve never lags
/// behind or cuts corners off the pen tip (unlike averaging filters, which
/// trade smoothness for visible latency). Converting each span to a Bézier
/// lets Core Graphics draw it natively.
public enum Smoothing {
  /// Segments through `points`. The span from `points[i]` to `points[i+1]`
  /// uses `points[i-1]` and `points[i+2]` as tangents; endpoints are mirrored.
  public static func catmullRom(_ points: [CGPoint], pressures: [Double]) -> [CubicSegment] {
    precondition(points.count == pressures.count)
    guard points.count >= 2 else { return [] }
    var out: [CubicSegment] = []
    out.reserveCapacity(points.count - 1)
    for i in 0..<(points.count - 1) {
      let p1 = points[i]
      let p2 = points[i + 1]
      let p0 = i > 0 ? points[i - 1] : p1
      let p3 = i + 2 < points.count ? points[i + 2] : p2
      let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
      let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
      out.append(
        CubicSegment(
          start: p1, control1: c1, control2: c2, end: p2,
          startPressure: pressures[i], endPressure: pressures[i + 1]
        ))
    }
    return out
  }

  /// Removes consecutive samples closer than `minDistance` points.
  /// Digitizers report at a high rate even when the pen barely moves; those
  /// near-duplicates add cost and create kinks in the tangent estimates.
  public static func decimate(_ points: [CGPoint], pressures: [Double], minDistance: CGFloat) -> (
    [CGPoint], [Double]
  ) {
    guard points.count > 2 else { return (points, pressures) }
    var outP = [points[0]]
    var outW = [pressures[0]]
    for i in 1..<(points.count - 1) {
      let last = outP[outP.count - 1]
      if hypot(points[i].x - last.x, points[i].y - last.y) >= minDistance {
        outP.append(points[i])
        outW.append(pressures[i])
      }
    }
    // Always keep the final sample so the stroke ends where the pen lifted.
    outP.append(points[points.count - 1])
    outW.append(pressures[pressures.count - 1])
    return (outP, outW)
  }
}
