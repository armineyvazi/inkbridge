import Foundation

/// What the Mac's own mouse does over InkBridge's surface.
/// The tablet pen always draws, whatever this is.
public enum PointerMode: String, Codable, CaseIterable, Sendable {
  /// Clicks go to the apps underneath (overlay) or pan the canvas (studio).
  case pointer
  /// The mouse/trackpad draws with the selected tool.
  case draw
}

/// How the drawing window must behave, derived from workspace state.
///
/// This is the whole interaction model in one place (docs/architecture/macos-interaction-model.md):
///
/// | Workspace        | Pointer mode | Window                     | Mouse does                  | Follows clicks |
/// |------------------|--------------|----------------------------|-----------------------------|----------------|
/// | Desktop Overlay  | pointer      | click-through, never key   | uses apps underneath        | yes            |
/// | Desktop Overlay  | draw         | catches mouse, never key   | draws; other displays free  | no             |
/// | Studio Canvas    | pointer      | catches mouse, may be key  | drag pans, scroll/pinch     | no             |
/// | Studio Canvas    | draw         | catches mouse, may be key  | draws; scroll/pinch navigate| no             |
///
/// Following clicks is only safe while the window is click-through: an opaque
/// or click-catching surface that follows clicks jumps onto the monitor the
/// user is trying to use (the bug behind "I clicked my monitor and nothing worked").
public struct WindowInteraction: Equatable, Sendable {
  /// `NSWindow.ignoresMouseEvents`.
  public var clickThrough: Bool
  /// May take keyboard focus (Esc, ⌘Z…). Never in the overlay: typing must keep going to the app underneath.
  public var canBecomeKey: Bool
  /// Moves to the display the user clicks (when "follow" is enabled).
  public var followsClicks: Bool
  /// Mouse drags create strokes.
  public var mouseDraws: Bool
  /// Mouse drags pan the canvas.
  public var mousePans: Bool

  public static func resolve(workspace: CanvasBackground.Mode, pointer: PointerMode)
    -> WindowInteraction
  {
    switch (workspace, pointer) {
    case (.overlay, .pointer):
      return WindowInteraction(
        clickThrough: true, canBecomeKey: false, followsClicks: true, mouseDraws: false,
        mousePans: false)
    case (.overlay, .draw):
      return WindowInteraction(
        clickThrough: false, canBecomeKey: false, followsClicks: false, mouseDraws: true,
        mousePans: false)
    case (.studio, .pointer):
      return WindowInteraction(
        clickThrough: false, canBecomeKey: true, followsClicks: false, mouseDraws: false,
        mousePans: true)
    case (.studio, .draw):
      return WindowInteraction(
        clickThrough: false, canBecomeKey: true, followsClicks: false, mouseDraws: true,
        mousePans: false)
    }
  }
}

/// Turns mouse events in view points into stroke operations in canvas px.
/// View-local points, so it is independent of where the display sits in the
/// global desktop (displays need not start at 0,0) and of Retina scale.
public struct MouseStrokeBuilder {
  public private(set) var activeID: String?
  private var counter = 0
  private let prefix: String

  public init(prefix: String = "m-\(UUID().uuidString.prefix(8))") {
    self.prefix = prefix
  }

  public enum Op: Equatable {
    case begin(id: String, InkPoint)
    case append(id: String, [InkPoint])
    case end(id: String)
  }

  public mutating func down(_ p: CGPoint, mapper: CoordinateMapper, t: Int64) -> Op {
    counter += 1
    let id = "\(prefix)-\(counter)"
    activeID = id
    return .begin(id: id, point(p, mapper, t))
  }

  public mutating func drag(_ p: CGPoint, mapper: CoordinateMapper, t: Int64) -> Op? {
    guard let id = activeID else { return nil }
    return .append(id: id, [point(p, mapper, t)])
  }

  public mutating func up() -> Op? {
    guard let id = activeID else { return nil }
    activeID = nil
    return .end(id: id)
  }

  private func point(_ p: CGPoint, _ mapper: CoordinateMapper, _ t: Int64) -> InkPoint {
    let c = mapper.unmap(p)
    // A mouse has no pressure; 0.6 gives a mid width for pressure-sensitive pens.
    return InkPoint(x: c.x, y: c.y, p: 0.6, t: t)
  }
}
