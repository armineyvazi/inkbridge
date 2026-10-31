import AppKit
import Combine
import InkBridgeCore

/// UI state shared by the toolbar, menu bar and settings window.
///
/// Persisted preferences are mirrored into UserDefaults; everything else is
/// runtime state published by `InkCoordinator`.
final class AppModel: ObservableObject {
    struct Connection: Equatable {
        var deviceName: String?
        var transport: TransportKind?
        var usbListening = false
        var wifiListening = false
        var lastError: String?

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

    // Preferences
    @Published var pairingCode: String { didSet { defaults.set(pairingCode, forKey: "pairingCode") } }
    @Published var wifiEnabled: Bool { didSet { defaults.set(wifiEnabled, forKey: "wifiEnabled") } }
    @Published var transportPreference: PeerArbiter.Preference {
        didSet { defaults.set(transportPreference.rawValue, forKey: "transportPreference") }
    }
    @Published var fit: CoordinateMapper.Fit { didSet { defaults.set(fit.rawValue, forKey: "fit") } }
    @Published var displayID: CGDirectDisplayID? {
        didSet { defaults.set(displayID.map { Int($0) }, forKey: "displayID") }
    }
    @Published var includeScreenshot: Bool { didSet { defaults.set(includeScreenshot, forKey: "includeScreenshot") } }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        pairingCode = defaults.string(forKey: "pairingCode") ?? PairingAuth.generateCode()
        wifiEnabled = defaults.object(forKey: "wifiEnabled") as? Bool ?? true
        transportPreference = PeerArbiter.Preference(rawValue: defaults.string(forKey: "transportPreference") ?? "") ?? .preferUSB
        fit = CoordinateMapper.Fit(rawValue: defaults.string(forKey: "fit") ?? "") ?? .aspectFit
        displayID = (defaults.object(forKey: "displayID") as? Int).map { CGDirectDisplayID($0) }
        includeScreenshot = defaults.bool(forKey: "includeScreenshot")
        defaults.set(pairingCode, forKey: "pairingCode")
    }

    static let palette: [RGBA] = [.red, .blue, .green, .black, .white]
    static let highlighterPalette: [RGBA] = [.yellow, RGBA(0.45, 0.95, 0.35), RGBA(1, 0.45, 0.75), RGBA(0.35, 0.8, 1)]

    /// The tool and style for a new stroke, given the device's physical tool.
    /// The device eraser always erases; otherwise the toolbar selection wins.
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
