import CoreGraphics

/// Maps normalized device-surface coordinates to points in a target canvas.
///
/// The pipeline is: device px → normalized 0...1 (on the tablet) →
/// calibration (here) → aspect fitting → canvas points (top-left origin).
/// Canvas points are AppKit points, so Retina scaling is applied by the
/// window server, not here. See docs/architecture/coordinate-mapping.md.
public struct CoordinateMapper: Equatable, Sendable {
    public enum Fit: String, Codable, CaseIterable, Sendable {
        /// Preserve the tablet's aspect ratio, centered (letterboxed).
        case aspectFit
        /// Use the whole canvas; strokes stretch if the aspect ratios differ.
        case stretch
    }

    /// Optional affine correction in normalized space, applied before fitting.
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

    public var canvas: CGSize
    /// Device surface size in pixels; only the ratio matters.
    public var surface: CGSize
    public var fit: Fit
    public var calibration: Calibration

    public init(canvas: CGSize, surface: CGSize, fit: Fit = .aspectFit, calibration: Calibration = .identity) {
        self.canvas = canvas
        self.surface = surface
        self.fit = fit
        self.calibration = calibration
    }

    /// The canvas rectangle that the device surface maps onto.
    public var activeRect: CGRect {
        guard fit == .aspectFit, surface.width > 0, surface.height > 0, canvas.width > 0, canvas.height > 0 else {
            return CGRect(origin: .zero, size: canvas)
        }
        let scale = min(canvas.width / surface.width, canvas.height / surface.height)
        let size = CGSize(width: surface.width * scale, height: surface.height * scale)
        return CGRect(
            x: (canvas.width - size.width) / 2, y: (canvas.height - size.height) / 2,
            width: size.width, height: size.height
        )
    }

    /// Canvas point for a normalized sample. Out-of-range input is clamped
    /// to the active rect so edge noise never draws outside it.
    public func map(x: Double, y: Double) -> CGPoint {
        let cx = min(max((x - calibration.offsetX) * calibration.scaleX, 0), 1)
        let cy = min(max((y - calibration.offsetY) * calibration.scaleY, 0), 1)
        let r = activeRect
        return CGPoint(x: r.minX + cx * r.width, y: r.minY + cy * r.height)
    }

    public func map(_ p: InkPoint) -> CGPoint { map(x: p.x, y: p.y) }

    /// Width / height of the active rect; the eraser uses it to measure
    /// distance in normalized space without distortion.
    public var aspectRatio: Double {
        let r = activeRect
        return r.height > 0 ? Double(r.width / r.height) : 1
    }
}
