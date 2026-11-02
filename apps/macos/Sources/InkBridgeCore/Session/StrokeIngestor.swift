import CoreGraphics
import Foundation

/// Applies stroke messages from the active device to a `StrokeStore`.
///
/// This is the seam between the protocol and the drawing engine: it knows
/// about sequence numbers and device tools, but not about sockets or views.
public final class StrokeIngestor {
  /// What a message changed, so the view can invalidate as little as possible.
  public enum Change: Equatable {
    case none
    /// A stroke grew by `added` samples.
    case strokeUpdated(id: String, added: Int)
    /// Committed ink changed (stroke ended, erased, cancelled).
    case documentChanged
    case surfaceChanged(CGSize)
    /// The device moved its view.
    case viewportChanged(Viewport)
  }

  /// Resolves the device's physical tool into the tool and style to draw with.
  /// The default draws plain black pen strokes.
  public var resolveTool: (Tool) -> (Tool, StrokeStyle) = { tool in
    (tool, StrokeStyle(color: .black, width: 3, pressureSensitive: true))
  }

  public let store: StrokeStore
  public private(set) var surface: CGSize
  /// The active device's current view of the canvas.
  public var viewport: Viewport = .home
  /// Messages dropped as duplicates or out of order, for diagnostics.
  public private(set) var droppedCount = 0

  private var lastSequence: [String: UInt64] = [:]

  public init(store: StrokeStore, surface: CGSize = CGSize(width: 3, height: 4)) {
    self.store = store
    self.surface = surface
  }

  /// Handles one message from the stream identified by `streamID`.
  public func handle(_ message: Message, streamID: String) -> Change {
    if let last = lastSequence[streamID], message.sequence <= last {
      droppedCount += 1
      return .none
    }
    lastSequence[streamID] = message.sequence

    switch message.payload {
    case .deviceHello(let hello):
      return setSurface(CGSize(width: hello.surfaceWidthPx, height: hello.surfaceHeightPx))
    case .deviceSurface(let w, let h):
      return setSurface(CGSize(width: w, height: h))
    case .canvasViewport(let v):
      guard v != viewport else { return .none }
      viewport = v
      return .viewportChanged(v)
    case .canvasCommand(let command):
      switch command {
      case .undo: store.undo()
      case .redo: store.redo()
      case .clear: store.clear()
      }
      return .documentChanged
    case .strokeBegin(let id, let deviceTool, let point, _):
      let (tool, style) = resolveTool(deviceTool)
      store.begin(id: id, tool: tool, style: style, point: point)
      return tool == .eraser ? .documentChanged : .strokeUpdated(id: id, added: 1)
    case .strokePoint(let id, let points):
      guard let stroke = store.append(id: id, points: points) else { return .none }
      return stroke.tool == .eraser ? .documentChanged : .strokeUpdated(id: id, added: points.count)
    case .strokeEnd(let id):
      store.end(id: id)
      return .documentChanged
    case .strokeCancel(let id):
      store.cancel(id: id)
      return .documentChanged
    default:
      return .none
    }
  }

  /// Forgets sequence state for a stream that will not come back.
  public func forget(streamID: String) {
    lastSequence.removeValue(forKey: streamID)
  }

  /// Sets the device surface size, e.g. when a different peer becomes active.
  @discardableResult
  public func setSurface(_ size: CGSize) -> Change {
    guard size != surface else { return .none }
    surface = size
    return .surfaceChanged(size)
  }
}
