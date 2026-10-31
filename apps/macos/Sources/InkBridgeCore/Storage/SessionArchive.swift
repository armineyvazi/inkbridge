import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Metadata stored next to a session's strokes.
public struct SessionMetadata: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var startedAt: Date
    public var savedAt: Date
    public var deviceName: String?
    public var displayName: String?
    /// Canvas size in points that the strokes were mapped onto.
    public var canvasWidth: Double
    public var canvasHeight: Double
    public var surfaceWidth: Double
    public var surfaceHeight: Double
    public var fit: CoordinateMapper.Fit
    public var calibration: CoordinateMapper.Calibration
    public var strokeCount: Int

    public init(
        id: String, title: String, startedAt: Date, savedAt: Date, deviceName: String?, displayName: String?,
        mapper: CoordinateMapper, strokeCount: Int
    ) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.savedAt = savedAt
        self.deviceName = deviceName
        self.displayName = displayName
        canvasWidth = mapper.canvas.width
        canvasHeight = mapper.canvas.height
        surfaceWidth = mapper.surface.width
        surfaceHeight = mapper.surface.height
        fit = mapper.fit
        calibration = mapper.calibration
        self.strokeCount = strokeCount
    }

    public var mapper: CoordinateMapper {
        CoordinateMapper(
            canvas: CGSize(width: canvasWidth, height: canvasHeight),
            surface: CGSize(width: surfaceWidth, height: surfaceHeight),
            fit: fit, calibration: calibration
        )
    }
}

/// Reads and writes session folders:
///
///     <name>/session.json   metadata
///     <name>/strokes.json   vector strokes (normalized, re-renderable)
///     <name>/preview.png    raster render
///     <name>/export.pdf     vector render
///
/// Strokes stay in normalized coordinates, so a saved session can be
/// re-rendered at any size and remains editable.
public enum SessionArchive {
    public enum ArchiveError: Error { case renderFailed, writeFailed(String) }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Writes metadata and strokes only. Cheap enough for autosave.
    public static func writeStrokes(_ strokes: [Stroke], metadata: SessionMetadata, to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try encoder.encode(strokes).write(to: dir.appendingPathComponent("strokes.json"), options: .atomic)
        try encoder.encode(metadata).write(to: dir.appendingPathComponent("session.json"), options: .atomic)
    }

    /// Writes strokes plus PNG and PDF renders.
    public static func save(_ strokes: [Stroke], metadata: SessionMetadata, to dir: URL, background: CGImage? = nil) throws {
        try writeStrokes(strokes, metadata: metadata, to: dir)
        let mapper = metadata.mapper
        try writePNG(strokes, mapper: mapper, background: background, to: dir.appendingPathComponent("preview.png"))
        try writePDF(strokes, mapper: mapper, background: background, to: dir.appendingPathComponent("export.pdf"))
        if let background {
            try writeImage(background, to: dir.appendingPathComponent("background.png"))
        }
    }

    public static func load(from dir: URL) throws -> (SessionMetadata, [Stroke]) {
        let meta = try decoder.decode(SessionMetadata.self, from: Data(contentsOf: dir.appendingPathComponent("session.json")))
        let strokes = try decoder.decode([Stroke].self, from: Data(contentsOf: dir.appendingPathComponent("strokes.json")))
        return (meta, strokes)
    }

    // MARK: Rendering

    /// Renders strokes on a white (or screenshot) background at `scale` pixels per point.
    public static func renderImage(_ strokes: [Stroke], mapper: CoordinateMapper, background: CGImage?, scale: CGFloat = 2) throws -> CGImage {
        let w = Int(mapper.canvas.width * scale), h = Int(mapper.canvas.height * scale)
        guard w > 0, h > 0, let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw ArchiveError.renderFailed }
        drawPage(strokes, mapper: mapper, background: background, in: ctx, height: CGFloat(h), scale: scale)
        guard let image = ctx.makeImage() else { throw ArchiveError.renderFailed }
        return image
    }

    static func writePNG(_ strokes: [Stroke], mapper: CoordinateMapper, background: CGImage?, to url: URL) throws {
        try writeImage(try renderImage(strokes, mapper: mapper, background: background), to: url)
    }

    static func writeImage(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw ArchiveError.writeFailed(url.path)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw ArchiveError.writeFailed(url.path) }
    }

    static func writePDF(_ strokes: [Stroke], mapper: CoordinateMapper, background: CGImage?, to url: URL) throws {
        var box = CGRect(origin: .zero, size: mapper.canvas)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { throw ArchiveError.writeFailed(url.path) }
        ctx.beginPDFPage(nil)
        drawPage(strokes, mapper: mapper, background: background, in: ctx, height: box.height, scale: 1)
        ctx.endPDFPage()
        ctx.closePDF()
    }

    private static func drawPage(_ strokes: [Stroke], mapper: CoordinateMapper, background: CGImage?, in ctx: CGContext, height: CGFloat, scale: CGFloat) {
        let bounds = CGRect(x: 0, y: 0, width: mapper.canvas.width * scale, height: height)
        if let background {
            ctx.draw(background, in: bounds)
        } else {
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(bounds)
        }
        // Core Graphics contexts are bottom-left origin; the renderer expects top-left.
        ctx.translateBy(x: 0, y: height)
        ctx.scaleBy(x: scale, y: -scale)
        StrokeRenderer.draw(strokes, in: ctx, mapper: mapper)
    }
}
