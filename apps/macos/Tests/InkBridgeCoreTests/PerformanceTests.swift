import CoreGraphics
import XCTest

@testable import InkBridgeCore

/// Micro-benchmarks for the receive path. Run with `swift test -c release
/// --filter PerformanceTests`; debug numbers are only useful as relative ones.
final class PerformanceTests: XCTestCase {
  private func pointMessage(_ i: Int) -> Message {
    Message(
      sequence: UInt64(i), timestampNs: Int64(i),
      payload: .strokePoint(
        strokeID: "s-bench-1",
        points: [
          InkPoint(x: Double(i % 1000) / 1000, y: 0.5, p: 0.6, t: Int64(i)),
          InkPoint(
            x: Double(i % 1000) / 1000 + 0.0005, y: 0.5005, p: 0.61, t: Int64(i) + 2_500_000),
        ]))
  }

  /// Decode + deframe one stroke.point with two samples (typical batch).
  func testDecodeThroughput() throws {
    var stream = Data()
    for i in 0..<5_000 { stream.append(try FrameCodec.frame(pointMessage(i))) }
    let start = monotonicNowNs()
    var decoder = FrameDecoder()
    decoder.append(stream)
    var n = 0
    while let f = try decoder.nextFrame() {
      _ = try MessageCodec.decode(f)
      n += 1
    }
    let perMessageUs = Double(monotonicNowNs() - start) / Double(n) / 1000
    print(
      "[bench] decode stroke.point: \(String(format: "%.2f", perMessageUs)) µs/message over \(n)")
    XCTAssertEqual(n, 5_000)
    // Budget: input processing under 2 ms. Leave two orders of magnitude.
    XCTAssertLessThan(perMessageUs, 200)
  }

  func testCoordinateMappingThroughput() {
    let m = CoordinateMapper(
      canvas: CGSize(width: 1728, height: 1117), surface: CGSize(width: 1404, height: 1872))
    let start = monotonicNowNs()
    var acc = 0.0
    for i in 0..<1_000_000 { acc += m.map(x: Double(i % 1000) / 1000, y: 0.5).x }
    let ns = Double(monotonicNowNs() - start) / 1_000_000
    print("[bench] coordinate map: \(String(format: "%.1f", ns)) ns/point")
    XCTAssertGreaterThan(acc, 0)
  }

  /// Rendering a long stroke into a Retina-sized bitmap: the worst case for a full redraw.
  func testRenderLongStroke() throws {
    let points = (0..<2_000).map { i -> InkPoint in
      let a = Double(i) / 2_000 * .pi * 8
      return InkPoint(
        x: 0.5 + 0.3 * cos(a) * Double(i) / 2_000, y: 0.5 + 0.3 * sin(a) * Double(i) / 2_000,
        p: 0.5 + 0.5 * sin(a * 3), t: Int64(i))
    }
    let stroke = Stroke(
      id: "s", tool: .pen, style: StrokeStyle(color: .black, width: 3, pressureSensitive: true),
      points: points)
    let mapper = CoordinateMapper(
      canvas: CGSize(width: 1728, height: 1117), surface: CGSize(width: 1404, height: 1872))
    let start = monotonicNowNs()
    _ = try SessionArchive.renderImage([stroke], mapper: mapper, background: nil, scale: 2)
    let ms = Double(monotonicNowNs() - start) / 1e6
    print("[bench] render 2000-point pressure stroke at 2x: \(String(format: "%.2f", ms)) ms")
  }
}
