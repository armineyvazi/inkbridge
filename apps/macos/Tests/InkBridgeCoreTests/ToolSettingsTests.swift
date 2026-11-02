import XCTest

@testable import InkBridgeCore

/// Pen-size model: shared limits with the tablet, per-tool memory, wire format,
/// and the rule that a size change never restyles existing strokes.
final class ToolSettingsTests: XCTestCase {
  private func config() throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: Fixtures.data("tool-sizes.json")) as! [String: Any]
  }

  func testLimitsAndPresetsMatchSharedFixture() throws {
    let tools = try config()["tools"] as! [String: [String: Any]]
    XCTAssertEqual(Set(tools.keys), Set(ToolSize.allCases.map(\.rawValue)))
    for spec in ToolSize.allCases {
      let t = tools[spec.rawValue]!
      XCTAssertEqual(t["default"] as! Double, spec.defaultSize, spec.rawValue)
      XCTAssertEqual(t["min"] as! Double, spec.range.lowerBound, spec.rawValue)
      XCTAssertEqual(t["max"] as! Double, spec.range.upperBound, spec.rawValue)
      XCTAssertEqual(t["presets"] as! [Double], spec.presets, spec.rawValue)
    }
  }

  func testStepVectorsMatchSharedFixture() throws {
    for v in try config()["steps"] as! [[String: Any]] {
      let spec = ToolSize(rawValue: v["tool"] as! String)!
      let from = v["from"] as! Double
      XCTAssertEqual(spec.step(from, up: true), v["up"] as! Double, "\(spec) \(from) up")
      XCTAssertEqual(spec.step(from, up: false), v["down"] as! Double, "\(spec) \(from) down")
    }
  }

  func testEachToolKeepsItsOwnSize() {
    var s = ToolSettings()
    s.tool = .pen
    s.setSize(.pen, 2)
    s.tool = .highlighter
    s.setSize(.highlighter, 12)
    s.tool = .pen
    XCTAssertEqual(s.size(.pen), 2)
    XCTAssertEqual(s.size(.highlighter), 12)
    XCTAssertNil(s.size(.laser))
  }

  func testSizesAreClamped() {
    var s = ToolSettings()
    s.setSize(.pen, 500)
    XCTAssertEqual(s.pen, 24)
    s.setSize(.pen, -1)
    XCTAssertEqual(s.pen, 0.5)
    s.setSize(.eraser, .nan)
    XCTAssertEqual(s.eraser, ToolSize.eraser.defaultSize)
  }

  func testWireRoundTrip() throws {
    let st = try MessageCodec.decode(Fixtures.data("valid/tool.state.json"))
    guard case .toolState(let t, let rev, let ack) = st.payload else { return XCTFail() }
    XCTAssertEqual(t, ToolSettings(tool: .highlighter, pen: 4.5, highlighter: 36, eraser: 28))
    XCTAssertEqual(rev, 7)
    XCTAssertEqual(ack, 3)
    let rq = try MessageCodec.decode(Fixtures.data("valid/tool.request.json"))
    guard case .toolRequest(let seq, let tool, let sizes) = rq.payload else { return XCTFail() }
    XCTAssertEqual(seq, 4)
    XCTAssertEqual(tool, .pen)
    XCTAssertEqual(sizes, [.pen: 5])
    XCTAssertEqual(try MessageCodec.decode(MessageCodec.encode(rq)), rq)
  }

  /// A size change applies to the next stroke only: strokes copy their style at begin.
  func testChangingSizeDoesNotRestyleExistingStrokes() {
    let store = StrokeStore()
    let p = InkPoint(x: 10, y: 10, p: 1, t: 0)
    store.begin(
      id: "a", tool: .pen, style: StrokeStyle(color: .black, width: 2, pressureSensitive: true),
      point: p)
    store.end(id: "a")
    var s = ToolSettings()
    s.setSize(.pen, 11)
    store.begin(
      id: "b", tool: .pen, style: StrokeStyle(color: .black, width: s.pen, pressureSensitive: true),
      point: p)
    store.end(id: "b")
    XCTAssertEqual(store.strokes.map(\.style.width), [2, 11])
  }

  /// Regression: eraser stroke.style must carry the radius (width 0 is outside the protocol
  /// range and used to disconnect the tablet when it decoded the Mac's reply).
  func testEraserStrokeStyleCarriesRadiusNotZero() throws {
    let ok = try MessageCodec.decode(Fixtures.data("valid/stroke.style.eraser.json"))
    guard case .strokeStyle(_, let tool, let style) = ok.payload else { return XCTFail() }
    XCTAssertEqual(tool, .eraser)
    XCTAssertEqual(style.width, 28)
    XCTAssertThrowsError(
      try MessageCodec.decode(Fixtures.data("invalid/bad-style-width-zero.json")))
    // The Mac's resolve() must use eraserSize, not 0: encoding a zero-width style is
    // rejected on decode by both peers (contract of WIDTH_RANGE).
    let zero = Message(
      version: 3, sequence: 1, timestampNs: 1,
      payload: .strokeStyle(
        strokeID: "e", tool: .eraser,
        style: WireStyle(color: .white, width: 0)))
    let encoded = try MessageCodec.encode(zero)
    XCTAssertThrowsError(try MessageCodec.decode(encoded))
  }
}
