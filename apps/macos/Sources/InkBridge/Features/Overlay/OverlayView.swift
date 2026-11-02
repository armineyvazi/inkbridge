import AppKit
import InkBridgeCore

/// Draws the stroke document.
///
/// Committed strokes are rendered once into a cached bitmap, refreshed only
/// when `StrokeStore.revision` changes. Live strokes and laser trails are
/// drawn on top each frame, and incoming points invalidate only the small
/// rect they touch, so a long session does not make each new point slower.
final class OverlayView: NSView {
  let store: StrokeStore
  var mapper: CoordinateMapper {
    didSet { if mapper != oldValue { invalidateCache() } }
  }
  /// Called at the end of each draw with the draw time, for latency stats.
  var onDraw: ((Int64) -> Void)?

  // Mouse / trackpad input, routed to the coordinator. Only delivered when
  // the window is not click-through (see WindowInteraction).
  enum MouseEvent {
    case down(CGPoint)
    case drag(CGPoint)
    case up
  }
  var onMouse: ((MouseEvent) -> Void)?
  /// Scroll or two-finger pan, in view points.
  var onPan: ((CGFloat, CGFloat) -> Void)?
  /// Pinch: factor around a view point.
  var onZoom: ((Double, CGPoint) -> Void)?
  /// Key commands while the studio has focus; returns true if handled.
  var onKey: ((NSEvent) -> Bool)?
  /// Drawn after the background and before ink: the engineering diagram.
  var drawUnderInk: ((CGContext, CoordinateMapper, CGRect) -> Void)?
  private(set) var lastClickCount = 1
  private(set) var lastShift = false
  var crosshair = false {
    didSet {
      window?.invalidateCursorRects(for: self)
      if crosshair != oldValue { updateTrackingAreas() }
    }
  }

  private var cache: CGImage?
  private var cacheRevision = -1
  private var laserTimer: Timer?

  init(store: StrokeStore, mapper: CoordinateMapper) {
    self.store = store
    self.mapper = mapper
    super.init(frame: .zero)
    wantsLayer = true
    layer?.backgroundColor = .clear
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("not used") }

  // Top-left origin, matching the normalized tablet coordinates.
  override var isFlipped: Bool { true }
  override var isOpaque: Bool { store.background.mode == .studio }

  // MARK: Mouse

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override var acceptsFirstResponder: Bool { true }

  override func mouseDown(with e: NSEvent) {
    lastClickCount = e.clickCount
    lastShift = e.modifierFlags.contains(.shift)
    onMouse?(.down(convert(e.locationInWindow, from: nil)))
  }
  override func mouseDragged(with e: NSEvent) {
    onMouse?(.drag(convert(e.locationInWindow, from: nil)))
  }
  override func mouseUp(with e: NSEvent) { onMouse?(.up) }

  override func scrollWheel(with e: NSEvent) {
    // Trackpads report precise deltas in points; wheels report lines.
    let k: CGFloat = e.hasPreciseScrollingDeltas ? 1 : 12
    onPan?(e.scrollingDeltaX * k, e.scrollingDeltaY * k)
  }

  override func magnify(with e: NSEvent) {
    onZoom?(1 + Double(e.magnification), convert(e.locationInWindow, from: nil))
  }

  override func keyDown(with e: NSEvent) {
    if onKey?(e) != true { super.keyDown(with: e) }
  }

  override func updateTrackingAreas() {
    trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(
      NSTrackingArea(
        rect: bounds, options: [.cursorUpdate, .activeAlways, .inVisibleRect], owner: self))
    super.updateTrackingAreas()
  }

  override func cursorUpdate(with event: NSEvent) {
    (crosshair ? NSCursor.crosshair : NSCursor.arrow).set()
  }

  func invalidateCache() {
    cacheRevision = -1
    needsDisplay = true
  }

  func strokeDidUpdate(_ id: String, added: Int) {
    guard let stroke = store.active[id] else { return }
    setNeedsDisplay(StrokeRenderer.dirtyRect(for: stroke, tail: added, mapper: mapper))
    if stroke.tool == .laser { startLaserTimer() }
  }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    invalidateCache()
  }

  override func draw(_ dirtyRect: NSRect) {
    guard let ctx = NSGraphicsContext.current?.cgContext else { return }
    // Background layer first (own layer: never baked into the stroke cache).
    if store.background.mode == .overlay { ctx.clear(dirtyRect) }
    BackgroundRenderer.draw(store.background, in: ctx, mapper: mapper, rect: dirtyRect)
    drawUnderInk?(ctx, mapper, dirtyRect)
    if cacheRevision != store.revision { rebuildCache() }
    if let cache {
      // CGImages draw bottom-up; undo the view's flip for the blit.
      ctx.saveGState()
      ctx.translateBy(x: 0, y: bounds.height)
      ctx.scaleBy(x: 1, y: -1)
      ctx.draw(cache, in: bounds)
      ctx.restoreGState()
    }
    for stroke in store.active.values {
      StrokeRenderer.draw(stroke, in: ctx, mapper: mapper, clip: dirtyRect)
    }
    let now = Date().timeIntervalSinceReferenceDate
    for (stroke, endedAt) in store.laser {
      let fade = max(0, 1 - (now - endedAt) / StrokeStore.laserLifetime)
      StrokeRenderer.draw(stroke, in: ctx, mapper: mapper, opacity: fade)
    }
    onDraw?(monotonicNowNs())
  }

  private func rebuildCache() {
    cacheRevision = store.revision
    let scale = window?.backingScaleFactor ?? 2
    let w = Int(bounds.width * scale)
    let h = Int(bounds.height * scale)
    guard !store.strokes.isEmpty, w > 0, h > 0,
      let ctx = CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else {
      cache = nil
      return
    }
    ctx.translateBy(x: 0, y: CGFloat(h))
    ctx.scaleBy(x: scale, y: -scale)
    StrokeRenderer.draw(store.strokes, in: ctx, mapper: mapper)
    cache = ctx.makeImage()
  }

  // Laser trails fade over time, so they need frames even without input.
  private func startLaserTimer() {
    guard laserTimer == nil else { return }
    laserTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] t in
      guard let self else { return t.invalidate() }
      let fading = self.store.pruneLaser(now: Date().timeIntervalSinceReferenceDate)
      let drawing = self.store.active.values.contains { $0.tool == .laser }
      self.needsDisplay = true
      if !fading && !drawing {
        t.invalidate()
        self.laserTimer = nil
      }
    }
  }
}
