import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Session metadata: everything needed to re-render the strokes exactly as
/// they appeared, without making the view part of the stroke data.
public struct SessionMetadata: Codable, Equatable, Sendable {
    /// 2 = canvas px coordinates (ADR-006). Format 1 sessions are not loaded.
    public static let currentFormat = 2

    public var format: Int
    public var id: String
    public var title: String
    public var startedAt: Date
    public var savedAt: Date
    public var deviceName: String?
    public var displayName: String?
    /// Display size in points that the viewport was mapped onto.
    public var canvasWidth: Double
    public var canvasHeight: Double
    /// Tablet view size in px (canvas px at zoom 1).
    public var surfaceWidth: Double
    public var surfaceHeight: Double
    /// View state at save time. Not part of the stroke coordinates.
    public var viewport: Viewport
    public var fit: CoordinateMapper.Fit
    public var calibration: CoordinateMapper.Calibration
    public var strokeCount: Int

    public init(
        id: String, title: String, startedAt: Date, savedAt: Date, deviceName: String?, displayName: String?,
        mapper: CoordinateMapper, strokeCount: Int
    ) {
        format = Self.currentFormat
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
        viewport = mapper.viewport
        fit = mapper.fit
        calibration = mapper.calibration
        self.strokeCount = strokeCount
    }

    public var mapper: CoordinateMapper {
        CoordinateMapper(
            canvas: CGSize(width: canvasWidth, height: canvasHeight),
            surface: CGSize(width: surfaceWidth, height: surfaceHeight),
            viewport: viewport, fit: fit, calibration: calibration
        )
    }
}

/// How a user export should be written.
public struct ExportOptions: Sendable {
    public enum ImageFormat: String, CaseIterable, Sendable {
        case png, jpeg
        var fileExtension: String { self == .png ? "png" : "jpg" }
        var type: UTType { self == .png ? .png : .jpeg }
    }

    public var fullPageFormat: ImageFormat = .png
    public var jpegQuality: Double = 0.9
    /// Pixels per display point for raster output (the display's backing scale).
    public var pixelScale: CGFloat = 2

    public init(fullPageFormat: ImageFormat = .png, jpegQuality: Double = 0.9, pixelScale: CGFloat = 2) {
        self.fullPageFormat = fullPageFormat
        self.jpegQuality = jpegQuality
        self.pixelScale = pixelScale
    }
}

/// What an export wrote, and what it could not write and why.
public struct ExportResult: Equatable, Sendable {
    public var files: [String]
    public var skipped: [String: String]
}

/// Reads and writes sessions.
///
/// **Autosave** (internal, `writeStrokes`): `session.json` + `strokes.json`.
///
/// **Export** (user-chosen folder, `export`). Layers are never merged destructively:
///
///     <name>/
///       full-page.png|jpg            screen + ink composite        (needs background)
///       preview.png                  composite, or ink on white
///       annotations/annotations.png  ink only, transparent, display resolution
///       annotations/annotations.svg  ink only, vector, display coordinates
///       annotations/strokes.json     every stroke on the infinite canvas (canvas px)
///       background/screen.png        the screenshot alone               (if captured)
///       session/metadata.json        session + view state
///       session/coordinate-mapping.json  how canvas px map to the page
///       manifest.json                file list + what was skipped and why
public enum SessionArchive {
    public enum ArchiveError: Error, LocalizedError {
        case renderFailed, writeFailed(String), unsupportedFormat(Int)
        public var errorDescription: String? {
            switch self {
            case .renderFailed: return "Rendering the image failed."
            case .writeFailed(let p): return "Could not write \(p)."
            case .unsupportedFormat(let f): return "Session format \(f) is not supported by this version."
            }
        }
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: Autosave

    /// Writes metadata and strokes only. Cheap enough for autosave.
    public static func writeStrokes(_ strokes: [Stroke], metadata: SessionMetadata, to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try encoder.encode(strokes).write(to: dir.appendingPathComponent("strokes.json"), options: .atomic)
        try encoder.encode(metadata).write(to: dir.appendingPathComponent("session.json"), options: .atomic)
    }

    public static func load(from dir: URL) throws -> (SessionMetadata, [Stroke]) {
        let meta = try decoder.decode(SessionMetadata.self, from: Data(contentsOf: dir.appendingPathComponent("session.json")))
        guard meta.format == SessionMetadata.currentFormat else { throw ArchiveError.unsupportedFormat(meta.format) }
        let strokes = try decoder.decode([Stroke].self, from: Data(contentsOf: dir.appendingPathComponent("strokes.json")))
        return (meta, strokes)
    }

    // MARK: Export

    /// Writes a complete export to `destination`.
    ///
    /// Files are first written to a temporary sibling folder, then moved into
    /// place in one step, so a failed export never leaves a half-written folder
    /// or damages an existing one. An existing `destination` is replaced only
    /// because the caller (the save panel) already confirmed it with the user.
    @discardableResult
    public static func export(
        _ strokes: [Stroke], metadata: SessionMetadata, background: CGImage?, backgroundUnavailableReason: String?,
        options: ExportOptions, to destination: URL
    ) throws -> ExportResult {
        let fm = FileManager.default
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).inkbridge-tmp-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        let result = try writeBundle(strokes, metadata: metadata, background: background,
                                     backgroundUnavailableReason: backgroundUnavailableReason, options: options, into: staging)
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: staging)
        } else {
            try fm.moveItem(at: staging, to: destination)
        }
        return result
    }

    static func writeBundle(
        _ strokes: [Stroke], metadata: SessionMetadata, background: CGImage?, backgroundUnavailableReason: String?,
        options: ExportOptions, into dir: URL
    ) throws -> ExportResult {
        let fm = FileManager.default
        let mapper = metadata.mapper
        var files: [String] = []
        var skipped: [String: String] = [:]
        func url(_ path: String) -> URL { dir.appendingPathComponent(path) }
        for sub in ["annotations", "session"] { try fm.createDirectory(at: url(sub), withIntermediateDirectories: true) }

        let ink = try renderImage(strokes, mapper: mapper, background: nil, transparent: true, scale: options.pixelScale)
        try writeImage(ink, to: url("annotations/annotations.png"), type: .png)
        try SVGWriter.svg(strokes, mapper: mapper).write(to: url("annotations/annotations.svg"), atomically: true, encoding: .utf8)
        try encoder.encode(strokes).write(to: url("annotations/strokes.json"))
        files += ["annotations/annotations.png", "annotations/annotations.svg", "annotations/strokes.json"]

        let fullPageName = "full-page.\(options.fullPageFormat.fileExtension)"
        if let background {
            try fm.createDirectory(at: url("background"), withIntermediateDirectories: true)
            try writeImage(background, to: url("background/screen.png"), type: .png)
            let composite = try renderImage(strokes, mapper: mapper, background: background, transparent: false, scale: options.pixelScale)
            try writeImage(composite, to: url(fullPageName), type: options.fullPageFormat.type, quality: options.jpegQuality)
            try writeImage(composite, to: url("preview.png"), type: .png)
            files += ["background/screen.png", fullPageName, "preview.png"]
        } else {
            let onWhite = try renderImage(strokes, mapper: mapper, background: nil, transparent: false, scale: options.pixelScale)
            try writeImage(onWhite, to: url("preview.png"), type: .png)
            files.append("preview.png")
            let reason = backgroundUnavailableReason ?? "no screenshot requested"
            skipped["background/screen.png"] = reason
            skipped[fullPageName] = reason
        }

        try encoder.encode(metadata).write(to: url("session/metadata.json"))
        try encoder.encode(CoordinateMappingInfo(mapper: mapper, pixelScale: Double(options.pixelScale)))
            .write(to: url("session/coordinate-mapping.json"))
        files += ["session/metadata.json", "session/coordinate-mapping.json"]

        let manifest = Manifest(app: "InkBridge", format: SessionMetadata.currentFormat, title: metadata.title,
                                savedAt: metadata.savedAt, files: files + ["manifest.json"], skipped: skipped)
        try encoder.encode(manifest).write(to: url("manifest.json"))
        return ExportResult(files: files + ["manifest.json"], skipped: skipped)
    }

    struct Manifest: Codable {
        var app: String
        var format: Int
        var title: String
        var savedAt: Date
        var files: [String]
        var skipped: [String: String]
    }

    /// Documents the canvas → page transform so other tools can place the ink.
    struct CoordinateMappingInfo: Codable {
        var description = "page_point = active_rect.origin + ((canvas - visible_canvas.origin) / visible_canvas.size - calibration.offset) * calibration.scale * active_rect.size; page_pixel = page_point * pixel_scale"
        var pageSizePoints: [Double]
        var pixelScale: Double
        var activeRect: [Double]
        var visibleCanvas: [Double]
        var viewport: Viewport
        var surfacePx: [Double]
        var fit: CoordinateMapper.Fit
        var calibration: CoordinateMapper.Calibration
        var pointsPerCanvasPx: Double

        init(mapper: CoordinateMapper, pixelScale: Double) {
            func r(_ r: CGRect) -> [Double] { [r.minX, r.minY, r.width, r.height].map(Double.init) }
            pageSizePoints = [mapper.canvas.width, mapper.canvas.height].map(Double.init)
            self.pixelScale = pixelScale
            activeRect = r(mapper.activeRect)
            visibleCanvas = r(mapper.visibleCanvasRect)
            viewport = mapper.viewport
            surfacePx = [mapper.surface.width, mapper.surface.height].map(Double.init)
            fit = mapper.fit
            calibration = mapper.calibration
            pointsPerCanvasPx = mapper.scale
        }
    }

    // MARK: Rendering

    /// Renders strokes at `scale` pixels per point over a screenshot, white, or transparency.
    public static func renderImage(_ strokes: [Stroke], mapper: CoordinateMapper, background: CGImage?,
                                   transparent: Bool = false, scale: CGFloat = 2) throws -> CGImage {
        let w = Int(mapper.canvas.width * scale), h = Int(mapper.canvas.height * scale)
        guard w > 0, h > 0, let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw ArchiveError.renderFailed }
        let bounds = CGRect(x: 0, y: 0, width: w, height: h)
        if let background {
            ctx.draw(background, in: bounds)
        } else if !transparent {
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(bounds)
        }
        // Core Graphics bitmaps are bottom-left origin; the renderer expects top-left.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        StrokeRenderer.draw(strokes, in: ctx, mapper: mapper)
        guard let image = ctx.makeImage() else { throw ArchiveError.renderFailed }
        return image
    }

    static func writeImage(_ image: CGImage, to url: URL, type: UTType, quality: Double = 0.9) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw ArchiveError.writeFailed(url.lastPathComponent)
        }
        var props: [CFString: Any] = [:]
        if type == .jpeg {
            props[kCGImageDestinationLossyCompressionQuality] = quality
        }
        // JPEG has no alpha; flatten onto white so transparent areas don't turn black.
        let output = type == .jpeg ? (flattened(image) ?? image) : image
        CGImageDestinationAddImage(dest, output, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ArchiveError.writeFailed(url.lastPathComponent) }
    }

    private static func flattened(_ image: CGImage) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let r = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(r)
        ctx.draw(image, in: r)
        return ctx.makeImage()
    }
}
