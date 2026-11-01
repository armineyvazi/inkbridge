import Foundation

/// The protocol version this build speaks. Peers with a different version are rejected.
public let inkProtocolVersion = 3

/// The tool a stroke was drawn with.
///
/// The device only ever sends `.pen` or `.eraser` (its physical tool); the host
/// substitutes its selected toolbar tool for `.pen`.
public enum Tool: String, CaseIterable, Codable, Sendable {
    case pen, highlighter, eraser, laser
}

/// One stylus sample in **canvas coordinates**.
///
/// Canvas px: 1 unit = 1 tablet pixel at zoom 1, unbounded, y down. They do
/// not depend on any viewport, so zooming or panning never changes stored
/// strokes (ADR-006). `p` is pressure in 0...1. `t` is the sample time in
/// nanoseconds on the sender's monotonic clock.
public struct InkPoint: Equatable, Codable, Sendable {
    public var x: Double
    public var y: Double
    public var p: Double
    public var t: Int64

    public init(x: Double, y: Double, p: Double, t: Int64) {
        self.x = x
        self.y = y
        self.p = p
        self.t = t
    }
}

/// Stroke appearance on the wire: color and width in canvas px.
public struct WireStyle: Equatable, Sendable {
    public var color: RGBA
    public var width: Double

    public init(color: RGBA, width: Double) {
        self.color = color
        self.width = width
    }
}

/// The visible region of the canvas: `x`,`y` is the canvas point at the
/// view's top-left corner; `zoom` is view px per canvas px.
public struct Viewport: Equatable, Codable, Sendable {
    public var x: Double
    public var y: Double
    public var zoom: Double

    public init(x: Double = 0, y: Double = 0, zoom: Double = 1) {
        self.x = x
        self.y = y
        self.zoom = zoom
    }

    public static let home = Viewport()
    public static let zoomRange: ClosedRange<Double> = 0.02...50
}

/// Document commands a device can ask the host to perform.
public enum CanvasCommand: String, CaseIterable, Sendable {
    case undo, redo, clear
}

/// Capabilities the device reported in `device.hello`.
public struct DeviceCapabilities: Equatable, Sendable {
    public var pressure: Bool
    public var tilt: Bool
    public var eraser: Bool
    public var stylusButton: Bool

    public init(pressure: Bool = false, tilt: Bool = false, eraser: Bool = false, stylusButton: Bool = false) {
        self.pressure = pressure
        self.tilt = tilt
        self.eraser = eraser
        self.stylusButton = stylusButton
    }
}

public struct DeviceHello: Equatable, Sendable {
    public var deviceID: String
    public var deviceName: String
    public var model: String
    public var androidAPI: Int
    /// Random per app-process identifier. Sequence numbers are scoped to it,
    /// which lets the host drop duplicates across reconnects.
    public var streamID: String
    public var surfaceWidthPx: Int
    public var surfaceHeightPx: Int
    public var capabilities: DeviceCapabilities
    /// How `auth` was computed (`.pair` or `.token`); nil when no proof is sent.
    public var authMode: AuthMode?
    /// Hex HMAC-SHA256 proof over the challenge (see PairingAuth).
    public var auth: String?

    public init(
        deviceID: String, deviceName: String, model: String, androidAPI: Int, streamID: String,
        surfaceWidthPx: Int, surfaceHeightPx: Int, capabilities: DeviceCapabilities,
        authMode: AuthMode? = nil, auth: String?
    ) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.model = model
        self.androidAPI = androidAPI
        self.streamID = streamID
        self.surfaceWidthPx = surfaceWidthPx
        self.surfaceHeightPx = surfaceHeightPx
        self.capabilities = capabilities
        self.authMode = authMode
        self.auth = auth
    }
}

/// Which secret a device's proof is keyed with.
public enum AuthMode: String, Sendable {
    /// First contact: the short-lived code shown in the Mac's Connect Device window.
    case pair
    /// Every later connection: the 256-bit token the Mac issued at pairing.
    case token
}

/// What the tablet shows about storage. The Mac owns the files; paths are
/// display strings only (the tablet cannot open Mac paths).
public struct StorageState: Equatable, Sendable {
    public var project: String
    public var session: String
    /// Where the project lives on the Mac, e.g. "~/Documents/InkBridge/Projects/A".
    public var location: String
    /// "saved" | "saving" | "unsaved" | "failed"
    public var status: String
    /// Unix ms of the last successful save, 0 if none.
    public var savedAtMs: Int64
    /// Human-readable reason when `status` is "failed".
    public var error: String?
    public var projects: [String]
    /// Storage roots the tablet may switch to (validated again by the Mac).
    public var locations: [String]
    public var revision: UInt64

    public init(project: String, session: String, location: String, status: String, savedAtMs: Int64, error: String?,
                projects: [String], locations: [String], revision: UInt64) {
        self.project = project; self.session = session; self.location = location; self.status = status
        self.savedAtMs = savedAtMs; self.error = error; self.projects = projects; self.locations = locations; self.revision = revision
    }
}

/// The typed body of a protocol message.
public enum Payload: Equatable, Sendable {
    /// `hostID` is the Mac's stable identity, so a device can tell which Mac it reached.
    case authChallenge(nonce: String, required: Bool, hostID: String)
    case deviceHello(DeviceHello)
    /// Host → device after a successful `.pair` proof, before `device.ready`.
    /// `proof` shows the host knew the code too; `token` is the long-lived device secret.
    case pairGranted(hostID: String, hostName: String, token: String, proof: String)
    /// `resumeSequence` is the highest sequence the host already holds for the
    /// hello's stream (0 if none): the device re-sends anything after it that
    /// was lost with the previous connection.
    case deviceReady(hostName: String, sessionID: String, hostID: String, resumeSequence: UInt64)
    case deviceDisconnect(reason: String)
    case deviceSurface(widthPx: Int, heightPx: Int)
    /// `style` is set on host→device strokes; devices omit it.
    case strokeBegin(strokeID: String, tool: Tool, point: InkPoint, style: WireStyle? = nil)
    case strokePoint(strokeID: String, points: [InkPoint])
    case strokeEnd(strokeID: String)
    case strokeCancel(strokeID: String)
    /// Host → device: how the host resolved a device stroke (tool and look).
    case strokeStyle(strokeID: String, tool: Tool, style: WireStyle)
    /// Either direction: the view moved.
    case canvasViewport(Viewport)
    /// Either direction: the background layer. Host → device carries the host's
    /// revision (apply only if newer). Device → host is a request; the host applies
    /// it, bumps the revision and echoes it back (the host is the single writer).
    case canvasBackground(CanvasBackground, revision: UInt64)
    /// Host → device: the engineering diagram, with connector paths already routed
    /// (so the tablet draws exactly what the Mac draws). Whole snapshot: diagrams are small.
    case diagramState(Diagram, revision: UInt64)
    /// Host → device: the Daily Journal (open or not, which day, its timestamped entries).
    /// `hidden`: the journal is open but put away on the Mac (optional on the wire, default false).
    case journalState(active: Bool, day: String, today: Bool, title: String, entries: [JournalEntry], revision: UInt64, hidden: Bool = false)
    /// Device → host: "open" | "close" | "today" | "prev" | "next" | "day" (name = yyyy-MM-dd) | "add_note" | "add_task"
    /// | "hide" | "show" (put the open journal away on the Mac / bring it back, without leaving it).
    case journalRequest(action: String, name: String?)
    /// Host → device: project, session, save status (sent on change and on connect).
    case storageState(StorageState)
    /// Device → host: "save_now" | "new_session" | "switch_project" | "create_project" | "use_location".
    /// The Mac validates and applies, then answers with `storage.state`.
    case storageRequest(action: String, name: String?)
    /// Device → host: undo / redo / clear the document.
    case canvasCommand(CanvasCommand)
    /// Host → device: drop every confirmed stroke before a full resync.
    case docReset
    /// Host → device: these strokes left the document.
    case docRemove(strokeIDs: [String])
    case sessionStart(sessionID: String?)
    case sessionPause(sessionID: String?)
    case sessionResume(sessionID: String?)
    case sessionSave(sessionID: String?)
    case ping(pingID: UInt64)
    case pong(pingID: UInt64, echoTimestampNs: Int64)
    case error(code: String, message: String)

    /// The wire `type` string.
    public var type: String {
        switch self {
        case .authChallenge: return "auth.challenge"
        case .deviceHello: return "device.hello"
        case .pairGranted: return "pair.granted"
        case .deviceReady: return "device.ready"
        case .deviceDisconnect: return "device.disconnect"
        case .deviceSurface: return "device.surface"
        case .strokeBegin: return "stroke.begin"
        case .strokePoint: return "stroke.point"
        case .strokeEnd: return "stroke.end"
        case .strokeCancel: return "stroke.cancel"
        case .strokeStyle: return "stroke.style"
        case .canvasViewport: return "canvas.viewport"
        case .canvasBackground: return "canvas.background"
        case .diagramState: return "diagram.state"
        case .storageState: return "storage.state"
        case .journalState: return "journal.state"
        case .journalRequest: return "journal.request"
        case .storageRequest: return "storage.request"
        case .canvasCommand: return "canvas.command"
        case .docReset: return "doc.reset"
        case .docRemove: return "doc.remove"
        case .sessionStart: return "session.start"
        case .sessionPause: return "session.pause"
        case .sessionResume: return "session.resume"
        case .sessionSave: return "session.save"
        case .ping: return "connection.ping"
        case .pong: return "connection.pong"
        case .error: return "error"
        }
    }
}

/// A complete protocol message: common envelope fields plus a payload.
public struct Message: Equatable, Sendable {
    public var version: Int
    /// Monotonic per-stream counter assigned by the sender.
    public var sequence: UInt64
    /// Send time on the sender's monotonic clock, in nanoseconds.
    public var timestampNs: Int64
    public var payload: Payload

    public init(version: Int = inkProtocolVersion, sequence: UInt64, timestampNs: Int64, payload: Payload) {
        self.version = version
        self.sequence = sequence
        self.timestampNs = timestampNs
        self.payload = payload
    }
}
