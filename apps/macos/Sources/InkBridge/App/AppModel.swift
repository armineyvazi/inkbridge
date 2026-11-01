import AppKit
import Combine
import InkBridgeCore

/// UI state shared by the toolbar, menu bar and settings window.
///
/// Persisted preferences are mirrored into UserDefaults; everything else is
/// runtime state published by `InkCoordinator`.
/// Toolbar density. Every size keeps the essentials (tool, undo, menu).
enum ToolbarSize: String, CaseIterable, Identifiable {
    case expanded, compact, minimal
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

/// Where the toolbar sits. Left/right dock vertically.
enum ToolbarDock: String, CaseIterable, Identifiable {
    case bottom, top, left, right, floating
    var id: String { rawValue }
    var title: String { self == .floating ? "Where I drag it" : rawValue.capitalized }
    var isVertical: Bool { self == .left || self == .right }
}

final class AppModel: ObservableObject {
    struct Connection: Equatable {
        var deviceName: String?
        var transport: TransportKind?
        var usbListening = false
        var wifiListening = false
        var lastError: String?
        /// When a tablet last became active (shown as "last connected").
        var lastConnectedAt: Date?
        /// Remote address of the active tablet ("Wi-Fi 192.168.1.20").
        var remote: String?

        var isConnected: Bool { deviceName != nil }
    }

    // Drawing tools
    @Published var tool: Tool = .pen
    @Published var penColor: RGBA = .red
    @Published var penWidth: Double = 3
    @Published var highlighterColor: RGBA = .yellow
    @Published var highlighterWidth: Double = 22
    @Published var highlighterOpacity: Double = 0.35
    @Published var eraserRadius: Double = 0.015
    @Published var overlayVisible = true

    // Runtime status
    @Published var connection = Connection()
    @Published var rttMs: Double?
    @Published var inputLatencyMs: Double?
    @Published var renderLatencyMs: Double?
    @Published var canUndo = false
    @Published var canRedo = false
    @Published var statusMessage: String?

    // Pairing
    /// The open Connect Device code, if any.
    @Published var pairingTicket: PairingTicket?
    @Published var pairedDevices: [PairedDevice] = []
    /// Shown so people can compare it with the tablet's diagnostics screen.
    @Published var hostFingerprint = ""
    var hostFingerprintHex = ""
    @Published var hostID = ""
    /// Set when a pairing completes while the window is open.
    @Published var justPaired: PairedDevice?

    // Preferences
    @Published var wifiEnabled: Bool { didSet { defaults.set(wifiEnabled, forKey: "wifiEnabled") } }
    @Published var transportPreference: PeerArbiter.Preference {
        didSet { defaults.set(transportPreference.rawValue, forKey: "transportPreference") }
    }
    @Published var fit: CoordinateMapper.Fit { didSet { defaults.set(fit.rawValue, forKey: "fit") } }
    /// Ink, Studio Canvas and toolbar move to the display you last clicked on.
    /// Off: they stay on `displayID` (or the primary display).
    @Published var followMouse: Bool { didSet { defaults.set(followMouse, forKey: "followMouse") } }
    @Published var displayID: CGDirectDisplayID? {
        didSet { defaults.set(displayID.map { Int($0) }, forKey: "displayID") }
    }
    @Published var includeScreenshot: Bool { didSet { defaults.set(includeScreenshot, forKey: "includeScreenshot") } }
    @Published var fullPageFormat: ExportOptions.ImageFormat {
        didSet { defaults.set(fullPageFormat.rawValue, forKey: "fullPageFormat") }
    }
    @Published var toolbarSize: ToolbarSize { didSet { defaults.set(toolbarSize.rawValue, forKey: "toolbarSize") } }
    @Published var toolbarDock: ToolbarDock { didSet { defaults.set(toolbarDock.rawValue, forKey: "toolbarDock") } }
    @Published var toolbarVisible: Bool { didSet { defaults.set(toolbarVisible, forKey: "toolbarVisible") } }
    /// The view of the infinite canvas currently shown (mirrors the tablet).
    @Published var viewport: Viewport = .home
    /// What the Mac's mouse does over the drawing surface (the pen always draws).
    @Published var pointerMode: PointerMode = .pointer
    /// Mirror of the Engineering workspace switch, for the toolbar.
    @Published var engineeringActive = false
    @Published var journalActive = false
    /// Mirror of the document's background layer (the store is the source of truth).
    @Published var background: CanvasBackground = .overlay
    /// Colour Studio Canvas returns to when toggled on from the overlay.
    var lastStudioColor: RGBA {
        get { defaults.string(forKey: "lastStudioColor").flatMap(RGBA.init(hex:)) ?? CanvasBackground.white }
        set { defaults.set(newValue.hex, forKey: "lastStudioColor") }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        wifiEnabled = defaults.object(forKey: "wifiEnabled") as? Bool ?? true
        transportPreference = PeerArbiter.Preference(rawValue: defaults.string(forKey: "transportPreference") ?? "") ?? .preferUSB
        fit = CoordinateMapper.Fit(rawValue: defaults.string(forKey: "fit") ?? "") ?? .aspectFit
        displayID = (defaults.object(forKey: "displayID") as? Int).map { CGDirectDisplayID($0) }
        followMouse = defaults.object(forKey: "followMouse") as? Bool ?? true
        includeScreenshot = defaults.bool(forKey: "includeScreenshot")
        fullPageFormat = ExportOptions.ImageFormat(rawValue: defaults.string(forKey: "fullPageFormat") ?? "") ?? .png
        toolbarSize = ToolbarSize(rawValue: defaults.string(forKey: "toolbarSize") ?? "") ?? .expanded
        toolbarDock = ToolbarDock(rawValue: defaults.string(forKey: "toolbarDock") ?? "") ?? .bottom
        toolbarVisible = defaults.object(forKey: "toolbarVisible") as? Bool ?? true
        // v2 kept a permanent code; v3 issues short-lived ones on demand.
        defaults.removeObject(forKey: "pairingCode")
    }

    static let palette: [RGBA] = [.red, .blue, .green, .black, .white]
    static let highlighterPalette: [RGBA] = [.yellow, RGBA(0.45, 0.95, 0.35), RGBA(1, 0.45, 0.75), RGBA(0.35, 0.8, 1)]

    /// The tool and style for a new stroke, given the device's physical tool.
    /// The device eraser always erases; otherwise the toolbar selection wins.
    /// Widths here are display points at the current zoom; the coordinator
    /// converts them to canvas px.
    func resolve(_ deviceTool: Tool, devicePressure: Bool) -> (Tool, StrokeStyle) {
        let tool = deviceTool == .eraser ? .eraser : self.tool
        switch tool {
        case .pen:
            return (tool, StrokeStyle(color: penColor, width: penWidth, pressureSensitive: devicePressure))
        case .highlighter:
            var c = highlighterColor
            c.a = highlighterOpacity
            return (tool, StrokeStyle(color: c, width: highlighterWidth, pressureSensitive: false))
        case .laser:
            return (tool, StrokeStyle(color: RGBA(1, 0.15, 0.1), width: 5, pressureSensitive: false))
        case .eraser:
            return (tool, StrokeStyle(color: .white, width: 0, pressureSensitive: false))
        }
    }

    var activeColor: RGBA {
        tool == .highlighter ? highlighterColor : penColor
    }

    func setColor(_ c: RGBA) {
        if tool == .highlighter { highlighterColor = c } else { penColor = c }
    }
}

extension RGBA {
    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
}
