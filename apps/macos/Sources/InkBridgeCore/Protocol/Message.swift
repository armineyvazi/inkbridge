import Foundation

/// The protocol version this build speaks. Peers with a different version are rejected.
public let inkProtocolVersion = 1

/// The tool a stroke was drawn with.
///
/// The device only ever sends `.pen` or `.eraser` (its physical tool); the host
/// substitutes its selected toolbar tool for `.pen`.
public enum Tool: String, CaseIterable, Codable, Sendable {
    case pen, highlighter, eraser, laser
}

/// One stylus sample in normalized device-surface coordinates.
///
/// `x` and `y` are in 0...1 with the origin at the top-left of the device's
/// drawing surface. `p` is pressure in 0...1. `t` is the sample time in
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
    /// Hex HMAC-SHA256 of the auth.challenge nonce, keyed by the pairing code.
    public var auth: String?

    public init(
        deviceID: String, deviceName: String, model: String, androidAPI: Int, streamID: String,
        surfaceWidthPx: Int, surfaceHeightPx: Int, capabilities: DeviceCapabilities, auth: String?
    ) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.model = model
        self.androidAPI = androidAPI
        self.streamID = streamID
        self.surfaceWidthPx = surfaceWidthPx
        self.surfaceHeightPx = surfaceHeightPx
        self.capabilities = capabilities
        self.auth = auth
    }
}

/// The typed body of a protocol message.
public enum Payload: Equatable, Sendable {
    case authChallenge(nonce: String, required: Bool)
    case deviceHello(DeviceHello)
    case deviceReady(hostName: String, sessionID: String)
    case deviceDisconnect(reason: String)
    case deviceSurface(widthPx: Int, heightPx: Int)
    case strokeBegin(strokeID: String, tool: Tool, point: InkPoint)
    case strokePoint(strokeID: String, points: [InkPoint])
    case strokeEnd(strokeID: String)
    case strokeCancel(strokeID: String)
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
        case .deviceReady: return "device.ready"
        case .deviceDisconnect: return "device.disconnect"
        case .deviceSurface: return "device.surface"
        case .strokeBegin: return "stroke.begin"
        case .strokePoint: return "stroke.point"
        case .strokeEnd: return "stroke.end"
        case .strokeCancel: return "stroke.cancel"
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
