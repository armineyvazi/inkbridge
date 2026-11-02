import CoreGraphics

/// Maps canvas coordinates to points on the Mac display.
///
/// The pipeline (ADR-006):
///
///     canvas px ──viewport──▶ view-normalized 0…1 ──calibration──▶
///     aspect fit ──▶ display points (top-left origin)
///
/// The viewport is the region of the infinite canvas the tablet is showing:
/// `origin = (viewport.x, viewport.y)`, `size = surface / viewport.zoom`.
/// The Mac shows exactly that region, so both screens stay in step. Stroke
/// data is never transformed; only this mapping changes when the user zooms
/// or pans. See docs/architecture/coordinate-mapping.md.
public struct CoordinateMapper: Equatable, Sendable {
  public enum Fit: String, Codable, CaseIterable, Sendable {
    /// Preserve the tablet's aspect ratio, centered (letterboxed).
    case aspectFit
    /// Use the whole display; ink stretches if the aspect ratios differ.
    case stretch
  }

  /// Affine correction in view-normalized space, applied before fitting.
  /// Identity by default; a calibration wizard would solve for these.
  public struct Calibration: Equatable, Codable, Sendable {
    public var offsetX = 0.0, offsetY = 0.0, scaleX = 1.0, scaleY = 1.0
    public init(offsetX: Double = 0, offsetY: Double = 0, scaleX: Double = 1, scaleY: Double = 1) {
      self.offsetX = offsetX
      self.offsetY = offsetY
      self.scaleX = scaleX
      self.scaleY = scaleY
    }
    public static let identity = Calibration()
  }

  /// Display size in points.
  public var canvas: CGSize
  /// The tablet's drawing view in px (its size at zoom 1, in canvas px).
  public var surface: CGSize
  public var viewport: Viewport
  public var fit: Fit
  public var calibration: Calibration

  public init(
    canvas: CGSize, surface: CGSize, viewport: Viewport = .home,
    fit: Fit = .aspectFit, calibration: Calibration = .identity
  ) {
    self.canvas = canvas
    self.surface = surface
    self.viewport = viewport
    self.fit = fit
    self.calibration = calibration
  }

  /// The part of the canvas currently on screen, in canvas px.
  public var visibleCanvasRect: CGRect {
    let z = max(viewport.zoom, Viewport.zoomRange.lowerBound)
    return CGRect(
      x: viewport.x, y: viewport.y, width: surface.width / z, height: surface.height / z)
  }

  /// The display rectangle the tablet's view maps onto.
  public var activeRect: CGRect {
    guard fit == .aspectFit, surface.width > 0, surface.height > 0, canvas.width > 0,
      canvas.height > 0
    else {
      return CGRect(origin: .zero, size: canvas)
    }
    let scale = min(canvas.width / surface.width, canvas.height / surface.height)
    let size = CGSize(width: surface.width * scale, height: surface.height * scale)
    return CGRect(
      x: (canvas.width - size.width) / 2, y: (canvas.height - size.height) / 2,
      width: size.width, height: size.height
    )
  }

  /// Display points per canvas px: how thick a 1-unit line looks. Uses the
  /// geometric mean of the two axes so a stretched mapping stays sensible.
  public var scale: Double {
    let v = visibleCanvasRect
    let r = activeRect
    guard v.width > 0, v.height > 0 else { return 1 }
    let sx = Double(r.width / v.width) * calibration.scaleX
    let sy = Double(r.height / v.height) * calibration.scaleY
    return (sx * sy).squareRoot()
  }

  /// Display point for a canvas point. Not clamped: the canvas is infinite,
  /// and points outside the viewport simply land off-screen.
  public func map(x: Double, y: Double) -> CGPoint {
    let v = visibleCanvasRect
    let u = ((x - Double(v.minX)) / Double(v.width) - calibration.offsetX) * calibration.scaleX
    let w = ((y - Double(v.minY)) / Double(v.height) - calibration.offsetY) * calibration.scaleY
    let r = activeRect
    return CGPoint(x: r.minX + u * r.width, y: r.minY + w * r.height)
  }

  public func map(_ p: InkPoint) -> CGPoint { map(x: p.x, y: p.y) }

  /// Canvas point under a display point (inverse of `map`).
  public func unmap(_ p: CGPoint) -> (x: Double, y: Double) {
    let r = activeRect
    let v = visibleCanvasRect
    let u = Double((p.x - r.minX) / r.width) / calibration.scaleX + calibration.offsetX
    let w = Double((p.y - r.minY) / r.height) / calibration.scaleY + calibration.offsetY
    return (Double(v.minX) + u * Double(v.width), Double(v.minY) + w * Double(v.height))
  }
}

extension Viewport {
  /// The viewport that shows `bounds` (canvas px) inside a view of `surface`
  /// px with `margin` (fraction of the view) on each side. Used by "Fit all".
  public static func fitting(_ bounds: CGRect, in surface: CGSize, margin: Double = 0.05)
    -> Viewport
  {
    guard bounds.width > 0 || bounds.height > 0, surface.width > 0, surface.height > 0 else {
      return .home
    }
    let usable = 1 - 2 * margin
    let zx = bounds.width > 0 ? Double(surface.width) * usable / Double(bounds.width) : .infinity
    let zy = bounds.height > 0 ? Double(surface.height) * usable / Double(bounds.height) : .infinity
    // Never magnify past actual size: Fit on a few short strokes used to zoom to 1000 %+.
    let zoom = min(max(min(zx, zy, 1), zoomRange.lowerBound), zoomRange.upperBound)
    let w = Double(surface.width) / zoom
    let h = Double(surface.height) / zoom
    return Viewport(x: Double(bounds.midX) - w / 2, y: Double(bounds.midY) - h / 2, zoom: zoom)
  }

  /// Zooms by `factor` keeping the canvas point under `focus` (view px) fixed.
  public func zoomed(by factor: Double, focus: CGPoint) -> Viewport {
    let newZoom = min(max(zoom * factor, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
    let cx = x + Double(focus.x) / zoom
    let cy = y + Double(focus.y) / zoom
    return Viewport(
      x: cx - Double(focus.x) / newZoom, y: cy - Double(focus.y) / newZoom, zoom: newZoom)
  }
}
