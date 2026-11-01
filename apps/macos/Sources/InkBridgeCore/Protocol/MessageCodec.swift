import CoreGraphics
import Foundation

/// Errors raised while decoding or validating a message.
public enum ProtocolError: Error, Equatable, CustomStringConvertible {
    case malformedJSON
    case notAnObject
    case missingField(String)
    case invalidField(String)
    case unsupportedVersion(Int)
    /// A well-formed message of a type this build does not know.
    /// Receivers should ignore it rather than drop the connection.
    case unknownType(String)
    case frameTooLarge(Int)
    case emptyFrame

    public var description: String {
        switch self {
        case .malformedJSON: return "malformed JSON"
        case .notAnObject: return "message is not a JSON object"
        case .missingField(let f): return "missing field \(f)"
        case .invalidField(let f): return "invalid field \(f)"
        case .unsupportedVersion(let v): return "unsupported protocol version \(v)"
        case .unknownType(let t): return "unknown message type \(t)"
        case .frameTooLarge(let n): return "frame of \(n) bytes exceeds limit"
        case .emptyFrame: return "empty frame"
        }
    }

    /// Whether the connection can continue after this error.
    public var isRecoverable: Bool {
        if case .unknownType = self { return true }
        return false
    }
}

/// Encodes and decodes protocol messages as JSON objects.
///
/// Decoding validates every field against the limits in
/// docs/protocol/protocol-specification.md, so a hostile or buggy peer
/// cannot hand the drawing engine NaN coordinates or unbounded strings.
public enum MessageCodec {
    public static let maxStringLength = 128
    public static let maxPointsPerMessage = 256
    public static let maxIDsPerMessage = 256
    /// Canvas coordinates are unbounded in principle; this cap keeps a hostile
    /// peer from producing values that overflow rendering math.
    public static let coordinateRange: ClosedRange<Double> = -1e7...1e7
    public static let widthRange: ClosedRange<Double> = 0.01...10_000

    // MARK: Encoding

    public static func encode(_ message: Message) throws -> Data {
        var object: [String: Any] = [
            "version": message.version,
            "type": message.payload.type,
            "sequence": message.sequence,
            "timestamp_ns": message.timestampNs,
        ]
        for (key, value) in fields(of: message.payload) {
            object[key] = value
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private static func fields(of payload: Payload) -> [String: Any] {
        switch payload {
        case let .authChallenge(nonce, required, hostID):
            return ["nonce": nonce, "required": required, "host_id": hostID]
        case let .deviceHello(h):
            var f: [String: Any] = [
                "device_id": h.deviceID, "device_name": h.deviceName, "model": h.model,
                "android_api": h.androidAPI, "stream_id": h.streamID,
                "surface_width_px": h.surfaceWidthPx, "surface_height_px": h.surfaceHeightPx,
                "capabilities": [
                    "pressure": h.capabilities.pressure, "tilt": h.capabilities.tilt,
                    "eraser": h.capabilities.eraser, "stylus_button": h.capabilities.stylusButton,
                ],
            ]
            if let auth = h.auth { f["auth"] = auth }
            if let mode = h.authMode { f["auth_mode"] = mode.rawValue }
            return f
        case let .pairGranted(hostID, hostName, token, proof):
            return ["host_id": hostID, "host_name": hostName, "token": token, "proof": proof]
        case let .deviceReady(hostName, sessionID, hostID, resume):
            return ["host_name": hostName, "session_id": sessionID, "host_id": hostID, "resume_sequence": resume]
        case let .deviceDisconnect(reason):
            return ["reason": reason]
        case let .deviceSurface(w, h):
            return ["surface_width_px": w, "surface_height_px": h]
        case let .strokeBegin(id, tool, point, style):
            var f: [String: Any] = ["stroke_id": id, "tool": tool.rawValue, "point": encode(point)]
            if let style { f["style"] = encode(style) }
            return f
        case let .strokeStyle(id, tool, style):
            return ["stroke_id": id, "tool": tool.rawValue, "style": encode(style)]
        case let .canvasViewport(v):
            return ["x": v.x, "y": v.y, "zoom": v.zoom]
        case let .canvasBackground(bg, revision):
            return ["mode": bg.mode.rawValue, "color": bg.color.hex, "pattern": bg.pattern.rawValue, "revision": revision]
        case let .diagramState(d, revision):
            func r(_ v: CGFloat) -> Double { (Double(v) * 10).rounded() / 10 }
            return [
                "revision": revision,
                "nodes": d.nodes.map { n in
                    ["id": n.id, "kind": n.kind, "label": n.label, "shape": n.component.shape.rawValue,
                     "x": r(n.frame.minX), "y": r(n.frame.minY), "w": r(n.frame.width), "h": r(n.frame.height)] as [String: Any]
                },
                "edges": d.edges.map { e in
                    ["id": e.id, "from": e.from, "to": e.to, "kind": e.kind.rawValue, "style": e.style.rawValue, "label": e.label,
                     "dashed": !e.kind.dash.isEmpty,
                     "points": d.path(of: e).flatMap { [r($0.x), r($0.y)] }] as [String: Any]
                },
            ]
        case let .journalState(active, day, today, title, entries, revision):
            return ["active": active, "day": day, "today": today, "title": title, "revision": revision,
                    "entries": entries.suffix(100).map { e in
                        ["id": e.id, "kind": e.kind.rawValue, "text": String(e.text.prefix(120)), "done": e.done,
                         "created_ms": Int64(e.createdAt.timeIntervalSince1970 * 1000)] as [String: Any]
                    }]
        case let .journalRequest(action, name):
            var f: [String: Any] = ["action": action]
            if let name { f["name"] = name }
            return f
        case let .storageState(st):
            var f: [String: Any] = ["project": st.project, "session": st.session, "location": st.location, "status": st.status,
                                    "saved_at_ms": st.savedAtMs, "projects": st.projects, "locations": st.locations, "revision": st.revision]
            if let e = st.error { f["error"] = e }
            return f
        case let .storageRequest(action, name):
            var f: [String: Any] = ["action": action]
            if let name { f["name"] = name }
            return f
        case let .canvasCommand(c):
            return ["command": c.rawValue]
        case .docReset:
            return [:]
        case let .docRemove(ids):
            return ["stroke_ids": ids]
        case let .strokePoint(id, points):
            return ["stroke_id": id, "points": points.map(encode)]
        case let .strokeEnd(id), let .strokeCancel(id):
            return ["stroke_id": id]
        case let .sessionStart(id), let .sessionPause(id), let .sessionResume(id), let .sessionSave(id):
            return id.map { ["session_id": $0] } ?? [:]
        case let .ping(id):
            return ["ping_id": id]
        case let .pong(id, echo):
            return ["ping_id": id, "echo_timestamp_ns": echo]
        case let .error(code, message):
            return ["code": code, "message": message]
        }
    }

    private static func encode(_ p: InkPoint) -> [String: Any] {
        ["x": p.x, "y": p.y, "p": p.p, "t": p.t]
    }

    private static func encode(_ s: WireStyle) -> [String: Any] {
        ["color": s.color.hex, "width": s.width]
    }

    // MARK: Decoding

    public static func decode(_ data: Data) throws -> Message {
        guard let raw = try? JSONSerialization.jsonObject(with: data) else {
            throw ProtocolError.malformedJSON
        }
        guard let obj = raw as? [String: Any] else { throw ProtocolError.notAnObject }
        let f = Fields(obj)

        let version: Int = try f.int("version")
        guard version == inkProtocolVersion else { throw ProtocolError.unsupportedVersion(version) }
        let type = try f.string("type")
        let sequence = try f.uint64("sequence")
        let timestamp = try f.int64("timestamp_ns")
        let payload = try decodePayload(type: type, f)
        return Message(version: version, sequence: sequence, timestampNs: timestamp, payload: payload)
    }

    private static func decodePayload(type: String, _ f: Fields) throws -> Payload {
        switch type {
        case "auth.challenge":
            return .authChallenge(nonce: try f.hex("nonce"), required: try f.bool("required"), hostID: try f.string("host_id"))
        case "device.hello":
            return .deviceHello(try decodeHello(f))
        case "device.ready":
            return .deviceReady(hostName: try f.string("host_name"), sessionID: try f.string("session_id"),
                                hostID: try f.string("host_id"), resumeSequence: try f.uint64("resume_sequence"))
        case "pair.granted":
            return .pairGranted(hostID: try f.string("host_id"), hostName: try f.string("host_name"),
                                token: try f.hex("token"), proof: try f.hex("proof"))
        case "device.disconnect":
            return .deviceDisconnect(reason: try f.string("reason"))
        case "device.surface":
            return .deviceSurface(widthPx: try f.dimension("surface_width_px"), heightPx: try f.dimension("surface_height_px"))
        case "stroke.begin":
            let style = try f.optionalObject("style").map { try decodeStyle($0) }
            return .strokeBegin(strokeID: try f.string("stroke_id"), tool: try f.tool("tool"),
                                point: try decodePoint(f.object("point"), field: "point"), style: style)
        case "stroke.style":
            return .strokeStyle(strokeID: try f.string("stroke_id"), tool: try f.tool("tool"), style: try decodeStyle(f.object("style")))
        case "canvas.viewport":
            guard let x = f.double("x"), let y = f.double("y"), let zoom = f.double("zoom"),
                  coordinateRange.contains(x), coordinateRange.contains(y), Viewport.zoomRange.contains(zoom)
            else { throw ProtocolError.invalidField("viewport") }
            return .canvasViewport(Viewport(x: x, y: y, zoom: zoom))
        case "canvas.background":
            guard let mode = CanvasBackground.Mode(rawValue: try f.string("mode")) else { throw ProtocolError.invalidField("mode") }
            guard let pattern = CanvasBackground.Pattern(rawValue: try f.string("pattern")) else { throw ProtocolError.invalidField("pattern") }
            guard let color = RGBA(hex: try f.string("color")) else { throw ProtocolError.invalidField("color") }
            return .canvasBackground(CanvasBackground(mode: mode, color: color, pattern: pattern), revision: try f.uint64("revision"))
        case "diagram.state":
            var d = Diagram()
            for raw in try f.array("nodes").prefix(maxIDsPerMessage) {
                guard let o = raw as? [String: Any] else { throw ProtocolError.invalidField("nodes") }
                let n = Fields(o)
                guard let x = n.double("x"), let y = n.double("y"), let w = n.double("w"), let h = n.double("h"),
                      w > 0, h > 0, coordinateRange.contains(x), coordinateRange.contains(y) else { throw ProtocolError.invalidField("nodes") }
                d.nodes.append(DiagramNode(id: try n.string("id"), kind: try n.string("kind"), label: try n.labelString("label"),
                                           frame: CGRect(x: x, y: y, width: w, height: h)))
            }
            for raw in try f.array("edges").prefix(maxIDsPerMessage) {
                guard let o = raw as? [String: Any] else { throw ProtocolError.invalidField("edges") }
                let e = Fields(o)
                guard let kind = DiagramEdge.Kind(rawValue: try e.string("kind")),
                      let style = DiagramEdge.Style(rawValue: try e.string("style")) else { throw ProtocolError.invalidField("edges") }
                d.edges.append(DiagramEdge(id: try e.string("id"), from: try e.string("from"), to: try e.string("to"),
                                           kind: kind, style: style, label: try e.labelString("label")))
            }
            return .diagramState(d, revision: try f.uint64("revision"))
        case "journal.state":
            var entries: [JournalEntry] = []
            for raw in try f.array("entries").prefix(100) {
                guard let o = raw as? [String: Any] else { throw ProtocolError.invalidField("entries") }
                let e = Fields(o)
                guard let kind = JournalEntry.Kind(rawValue: try e.string("kind")) else { throw ProtocolError.invalidField("entries") }
                let created = Date(timeIntervalSince1970: Double(try e.int64("created_ms")) / 1000)
                entries.append(JournalEntry(id: try e.string("id"), kind: kind, text: try e.labelString("text"),
                                            done: try e.bool("done"), createdAt: created))
            }
            return .journalState(active: try f.bool("active"), day: try f.labelString("day"), today: try f.bool("today"),
                                 title: try f.labelString("title"), entries: entries, revision: try f.uint64("revision"))
        case "journal.request":
            let action = try f.string("action")
            guard ["open", "close", "today", "prev", "next", "day", "add_note", "add_task"].contains(action) else {
                throw ProtocolError.invalidField("action")
            }
            return .journalRequest(action: action, name: try f.optionalString("name"))
        case "storage.state":
            let status = try f.string("status")
            guard ["empty", "saved", "saving", "unsaved", "failed"].contains(status) else { throw ProtocolError.invalidField("status") }
            return .storageState(StorageState(
                project: try f.string("project"), session: try f.string("session"), location: try f.string("location"),
                status: status, savedAtMs: try f.int64("saved_at_ms"),
                error: try f.optionalString("error"),
                projects: try f.stringArray("projects"), locations: try f.stringArray("locations"),
                revision: try f.uint64("revision")))
        case "storage.request":
            let action = try f.string("action")
            guard ["save_now", "new_session", "switch_project", "create_project", "use_location"].contains(action) else {
                throw ProtocolError.invalidField("action")
            }
            return .storageRequest(action: action, name: try f.optionalString("name"))
        case "canvas.command":
            guard let c = CanvasCommand(rawValue: try f.string("command")) else { throw ProtocolError.invalidField("command") }
            return .canvasCommand(c)
        case "doc.reset":
            return .docReset
        case "doc.remove":
            let list = try f.array("stroke_ids")
            guard !list.isEmpty, list.count <= maxIDsPerMessage else { throw ProtocolError.invalidField("stroke_ids") }
            let ids = try list.map { item -> String in
                guard let s = item as? String, !s.isEmpty, s.utf8.count <= maxStringLength else {
                    throw ProtocolError.invalidField("stroke_ids")
                }
                return s
            }
            return .docRemove(strokeIDs: ids)
        case "stroke.point":
            let list = try f.array("points")
            guard !list.isEmpty, list.count <= maxPointsPerMessage else { throw ProtocolError.invalidField("points") }
            let points = try list.map { item -> InkPoint in
                guard let o = item as? [String: Any] else { throw ProtocolError.invalidField("points") }
                return try decodePoint(o, field: "points")
            }
            return .strokePoint(strokeID: try f.string("stroke_id"), points: points)
        case "stroke.end":
            return .strokeEnd(strokeID: try f.string("stroke_id"))
        case "stroke.cancel":
            return .strokeCancel(strokeID: try f.string("stroke_id"))
        case "session.start": return .sessionStart(sessionID: try f.optionalString("session_id"))
        case "session.pause": return .sessionPause(sessionID: try f.optionalString("session_id"))
        case "session.resume": return .sessionResume(sessionID: try f.optionalString("session_id"))
        case "session.save": return .sessionSave(sessionID: try f.optionalString("session_id"))
        case "connection.ping":
            return .ping(pingID: try f.uint64("ping_id"))
        case "connection.pong":
            return .pong(pingID: try f.uint64("ping_id"), echoTimestampNs: try f.int64("echo_timestamp_ns"))
        case "error":
            return .error(code: try f.string("code"), message: try f.string("message", maxLength: 512))
        default:
            throw ProtocolError.unknownType(String(type.prefix(maxStringLength)))
        }
    }

    private static func decodeHello(_ f: Fields) throws -> DeviceHello {
        let caps = Fields(try f.object("capabilities"))
        return DeviceHello(
            deviceID: try f.string("device_id"),
            deviceName: try f.string("device_name"),
            model: try f.string("model"),
            androidAPI: try f.int("android_api"),
            streamID: try f.string("stream_id"),
            surfaceWidthPx: try f.dimension("surface_width_px"),
            surfaceHeightPx: try f.dimension("surface_height_px"),
            capabilities: DeviceCapabilities(
                pressure: try caps.bool("pressure"),
                tilt: try caps.bool("tilt"),
                eraser: try caps.bool("eraser"),
                stylusButton: try caps.bool("stylus_button")
            ),
            authMode: try f.optionalString("auth_mode").map { raw in
                guard let mode = AuthMode(rawValue: raw) else { throw ProtocolError.invalidField("auth_mode") }
                return mode
            },
            auth: try f.optionalHex("auth")
        )
    }

    private static func decodeStyle(_ obj: [String: Any]) throws -> WireStyle {
        let f = Fields(obj)
        guard let color = RGBA(hex: try f.string("color")), let width = f.double("width"), widthRange.contains(width) else {
            throw ProtocolError.invalidField("style")
        }
        return WireStyle(color: color, width: width)
    }

    private static func decodePoint(_ obj: [String: Any], field: String) throws -> InkPoint {
        let f = Fields(obj)
        guard let x = f.double("x"), let y = f.double("y"), let p = f.double("p"),
              coordinateRange.contains(x), coordinateRange.contains(y), (0...1).contains(p),
              let t = obj["t"] as? Int64
        else { throw ProtocolError.invalidField(field) }
        return InkPoint(x: x, y: y, p: p, t: t)
    }
}

/// Typed, validating accessors over a decoded JSON object.
private struct Fields {
    let obj: [String: Any]
    init(_ obj: [String: Any]) { self.obj = obj }

    private func value(_ key: String) throws -> Any {
        guard let v = obj[key], !(v is NSNull) else { throw ProtocolError.missingField(key) }
        return v
    }

    func string(_ key: String, maxLength: Int = MessageCodec.maxStringLength) throws -> String {
        guard let s = try value(key) as? String else { throw ProtocolError.invalidField(key) }
        guard !s.isEmpty, s.utf8.count <= maxLength else { throw ProtocolError.invalidField(key) }
        return s
    }

    func optionalString(_ key: String) throws -> String? {
        guard obj[key] != nil, !(obj[key] is NSNull) else { return nil }
        return try string(key)
    }

    func hex(_ key: String) throws -> String {
        let s = try string(key)
        guard s.count % 2 == 0, s.allSatisfy(\.isHexDigit) else { throw ProtocolError.invalidField(key) }
        return s.lowercased()
    }

    func optionalHex(_ key: String) throws -> String? {
        guard obj[key] != nil, !(obj[key] is NSNull) else { return nil }
        return try hex(key)
    }

    func bool(_ key: String) throws -> Bool {
        // JSONSerialization yields NSNumber for both numbers and booleans;
        // only accept the boolean kind so `"pressure": 1` is rejected.
        guard let n = try value(key) as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else {
            throw ProtocolError.invalidField(key)
        }
        return n.boolValue
    }

    func int(_ key: String) throws -> Int {
        guard let n = try value(key) as? Int else { throw ProtocolError.invalidField(key) }
        return n
    }

    func int64(_ key: String) throws -> Int64 {
        guard let n = try value(key) as? Int64 else { throw ProtocolError.invalidField(key) }
        return n
    }

    func uint64(_ key: String) throws -> UInt64 {
        guard let n = try value(key) as? UInt64 else { throw ProtocolError.invalidField(key) }
        return n
    }

    func dimension(_ key: String) throws -> Int {
        let n = try int(key)
        guard (1...32_768).contains(n) else { throw ProtocolError.invalidField(key) }
        return n
    }

    func double(_ key: String) -> Double? {
        guard let n = obj[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        return d.isFinite ? d : nil
    }

    func object(_ key: String) throws -> [String: Any] {
        guard let o = try value(key) as? [String: Any] else { throw ProtocolError.invalidField(key) }
        return o
    }

    func optionalObject(_ key: String) throws -> [String: Any]? {
        guard obj[key] != nil, !(obj[key] is NSNull) else { return nil }
        return try object(key)
    }

    func tool(_ key: String) throws -> Tool {
        guard let t = Tool(rawValue: try string(key)) else { throw ProtocolError.invalidField(key) }
        return t
    }

    /// Like `string` but allows "" (diagram labels are often empty).
    func labelString(_ key: String) throws -> String {
        guard let v = obj[key] else { throw ProtocolError.missingField(key) }
        // 512 bytes: 120 characters of any script (Persian, CJK… take 2–4 bytes each).
        guard let s = v as? String, s.utf8.count <= 512 else { throw ProtocolError.invalidField(key) }
        return s
    }

    func stringArray(_ key: String) throws -> [String] {
        let raw = try array(key)
        guard raw.count <= MessageCodec.maxIDsPerMessage else { throw ProtocolError.invalidField(key) }
        return try raw.map { v in
            guard let s = v as? String, s.count <= MessageCodec.maxStringLength else { throw ProtocolError.invalidField(key) }
            return s
        }
    }

    func array(_ key: String) throws -> [Any] {
        guard let a = try value(key) as? [Any] else { throw ProtocolError.invalidField(key) }
        return a
    }
}
