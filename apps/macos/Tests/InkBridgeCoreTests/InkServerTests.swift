import Network
import XCTest
@testable import InkBridgeCore

/// A minimal protocol client over Network.framework, standing in for the tablet.
private final class TestClient {
    let connection: NWConnection
    private let queue = DispatchQueue(label: "test.client")
    private var decoder = FrameDecoder()
    private var sequence: UInt64 = 0
    private var waiting: [(Message) -> Bool] = []
    private(set) var received: [Message] = []
    private let lock = NSLock()

    init(port: UInt16) {
        connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        connection.start(queue: queue)
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data { self.decoder.append(data) }
            while let frame = try? self.decoder.nextFrame(), let m = try? MessageCodec.decode(frame) {
                self.lock.lock(); self.received.append(m); self.lock.unlock()
            }
            if !complete && error == nil { self.receive() }
        }
    }

    func send(_ payload: Payload, timestamp: Int64 = 0) {
        sequence += 1
        let frame = try! FrameCodec.frame(Message(sequence: sequence, timestampNs: timestamp, payload: payload))
        connection.send(content: frame, completion: .idempotent)
    }

    func sendRaw(_ data: Data) { connection.send(content: data, completion: .idempotent) }

    /// Waits until a received message satisfies `match`.
    func waitFor(timeout: TimeInterval = 3, _ match: (Message) -> Bool) -> Message? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            lock.lock(); let hit = received.first(where: match); lock.unlock()
            if let hit { return hit }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return nil
    }

    func challenge() -> (nonce: Data, required: Bool)? {
        guard let m = waitFor({ if case .authChallenge = $0.payload { return true }; return false }),
              case let .authChallenge(nonce, required) = m.payload else { return nil }
        return (Data(hex: nonce)!, required)
    }

    func hello(auth: String?) -> DeviceHello {
        DeviceHello(deviceID: "test-device", deviceName: "Test Tablet", model: "Sim", androidAPI: 31,
                    streamID: UUID().uuidString, surfaceWidthPx: 1404, surfaceHeightPx: 1872,
                    capabilities: DeviceCapabilities(pressure: true), auth: auth)
    }

    func close() { connection.cancel() }
}

/// Collects delegate callbacks on a private queue for assertions.
private final class Recorder: InkServerDelegate {
    let lock = NSLock()
    var connected: [PeerInfo] = []
    var messages: [Message] = []
    var disconnected: [String] = []
    var clocks = 0
    var ports: [TransportKind: UInt16] = [:]

    func inkServer(_ s: InkServer, didConnect peer: PeerInfo) { locked { connected.append(peer) } }
    func inkServer(_ s: InkServer, peer: PeerInfo, didReceive message: Message, receivedAtNs: Int64) { locked { messages.append(message) } }
    func inkServer(_ s: InkServer, peer: PeerInfo, didUpdateClock clock: ClockSync) { locked { clocks += 1 } }
    func inkServer(_ s: InkServer, didDisconnect peer: PeerInfo, reason: String) { locked { disconnected.append(reason) } }
    func inkServer(_ s: InkServer, listener: TransportKind, didChangeState state: InkServer.ListenerState) {
        if case .listening(let port) = state { locked { ports[listener] = port } }
    }

    func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }

    func wait(timeout: TimeInterval = 3, _ cond: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if locked(cond) { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return false
    }
}

final class InkServerTests: XCTestCase {
    private var server: InkServer!
    private var recorder: Recorder!

    private func startServer(wifi: Bool = true, ping: TimeInterval = 2, idle: TimeInterval = 7) throws {
        var config = InkServer.Config(serviceName: "InkBridge Test", pairingCode: "K7QW-M3XP", sessionID: "session-test")
        config.usbPort = 0
        config.wifiPort = 0
        config.wifiEnabled = wifi
        config.pingInterval = ping
        config.idleTimeout = idle
        config.handshakeTimeout = 1
        recorder = Recorder()
        server = InkServer(config: config, delegateQueue: DispatchQueue(label: "test.delegate"))
        server.delegate = recorder
        server.start()
        XCTAssertTrue(recorder.wait { recorder.ports[.usb] != nil && (!wifi || recorder.ports[.wifi] != nil) }, "listeners did not start")
    }

    override func tearDown() {
        server?.stop()
        super.tearDown()
    }

    func testUSBHandshakeWithoutPairingAndStrokeDelivery() throws {
        try startServer(wifi: false)
        let c = TestClient(port: recorder.ports[.usb]!)
        defer { c.close() }
        let ch = try XCTUnwrap(c.challenge())
        XCTAssertFalse(ch.required)
        c.send(.deviceHello(c.hello(auth: nil)))
        XCTAssertNotNil(c.waitFor { if case .deviceReady(_, "session-test") = $0.payload { return true }; return false })

        c.send(.strokeBegin(strokeID: "s1", tool: .pen, point: InkPoint(x: 0.1, y: 0.1, p: 0.5, t: 1)))
        c.send(.strokePoint(strokeID: "s1", points: [InkPoint(x: 0.2, y: 0.2, p: 0.6, t: 2)]))
        c.send(.strokeEnd(strokeID: "s1"))
        XCTAssertTrue(recorder.wait { recorder.messages.count == 4 })  // hello + 3 stroke messages
        let types = recorder.locked { recorder.messages.map(\.payload.type) }
        XCTAssertEqual(types, ["device.hello", "stroke.begin", "stroke.point", "stroke.end"])
        let seqs = recorder.locked { recorder.messages.map(\.sequence) }
        XCTAssertEqual(seqs, [1, 2, 3, 4], "order must be preserved")
    }

    func testWifiRequiresCorrectPairingCode() throws {
        try startServer()
        let good = TestClient(port: recorder.ports[.wifi]!)
        defer { good.close() }
        let ch = try XCTUnwrap(good.challenge())
        XCTAssertTrue(ch.required)
        good.send(.deviceHello(good.hello(auth: PairingAuth.response(code: "k7qw-m3xp", nonce: ch.nonce))))
        XCTAssertNotNil(good.waitFor { if case .deviceReady = $0.payload { return true }; return false })
        XCTAssertTrue(recorder.wait { recorder.connected.first?.kind == .wifi })
    }

    func testWifiRejectsWrongCodeAndMissingAuth() throws {
        try startServer()
        let bad = TestClient(port: recorder.ports[.wifi]!)
        defer { bad.close() }
        let ch = try XCTUnwrap(bad.challenge())
        bad.send(.deviceHello(bad.hello(auth: PairingAuth.response(code: "AAAA-AAAA", nonce: ch.nonce))))
        XCTAssertNotNil(bad.waitFor { if case .error("auth_failed", _) = $0.payload { return true }; return false })

        let none = TestClient(port: recorder.ports[.wifi]!)
        defer { none.close() }
        _ = try XCTUnwrap(none.challenge())
        none.send(.deviceHello(none.hello(auth: nil)))
        XCTAssertNotNil(none.waitFor { if case .error("auth_failed", _) = $0.payload { return true }; return false })
        XCTAssertTrue(recorder.locked { recorder.connected.isEmpty })
    }

    func testStrokesBeforeHelloAreRejected() throws {
        try startServer(wifi: false)
        let c = TestClient(port: recorder.ports[.usb]!)
        defer { c.close() }
        _ = try XCTUnwrap(c.challenge())
        c.send(.strokeBegin(strokeID: "s", tool: .pen, point: InkPoint(x: 0, y: 0, p: 0, t: 0)))
        XCTAssertNotNil(c.waitFor { if case .error("handshake_required", _) = $0.payload { return true }; return false })
        XCTAssertTrue(recorder.locked { recorder.messages.isEmpty })
    }

    func testHandshakeTimeout() throws {
        try startServer(wifi: false)
        let c = TestClient(port: recorder.ports[.usb]!)
        defer { c.close() }
        XCTAssertNotNil(c.waitFor { if case .error("handshake_timeout", _) = $0.payload { return true }; return false })
    }

    func testOversizedFrameClosesConnectionWithoutCrash() throws {
        try startServer(wifi: false)
        let c = TestClient(port: recorder.ports[.usb]!)
        defer { c.close() }
        _ = try XCTUnwrap(c.challenge())
        c.sendRaw(Data([0x7F, 0xFF, 0xFF, 0xFF]))
        XCTAssertNotNil(c.waitFor { if case .error("bad_frame", _) = $0.payload { return true }; return false })
    }

    func testInvalidMessageIsReportedButConnectionSurvives() throws {
        try startServer(wifi: false)
        let c = TestClient(port: recorder.ports[.usb]!)
        defer { c.close() }
        _ = try XCTUnwrap(c.challenge())
        c.send(.deviceHello(c.hello(auth: nil)))
        _ = c.waitFor { if case .deviceReady = $0.payload { return true }; return false }
        c.sendRaw(try FrameCodec.frame(Fixtures.data("invalid/coordinate-out-of-range.json")))
        XCTAssertNotNil(c.waitFor { if case .error("invalid_message", _) = $0.payload { return true }; return false })
        c.send(.strokeEnd(strokeID: "x"))
        XCTAssertTrue(recorder.wait { recorder.messages.contains { $0.payload.type == "stroke.end" } })
    }

    func testPingPongUpdatesClockAndPeerAnswersPings() throws {
        try startServer(wifi: false, ping: 0.1)
        let c = TestClient(port: recorder.ports[.usb]!)
        defer { c.close() }
        _ = try XCTUnwrap(c.challenge())
        c.send(.deviceHello(c.hello(auth: nil)))
        // Server-initiated ping: answer it like the tablet does.
        let ping = try XCTUnwrap(c.waitFor { if case .ping = $0.payload { return true }; return false })
        guard case let .ping(id) = ping.payload else { return XCTFail() }
        c.send(.pong(pingID: id, echoTimestampNs: ping.timestampNs), timestamp: monotonicNowNs())
        XCTAssertTrue(recorder.wait { recorder.clocks >= 1 })
        // Device-initiated ping gets a pong echoing our timestamp.
        c.send(.ping(pingID: 777), timestamp: 123_456)
        XCTAssertNotNil(c.waitFor { if case .pong(777, 123_456) = $0.payload { return true }; return false })
    }

    func testIdlePeerIsDisconnected() throws {
        try startServer(wifi: false, ping: 0.1, idle: 0.4)
        let c = TestClient(port: recorder.ports[.usb]!)
        defer { c.close() }
        _ = try XCTUnwrap(c.challenge())
        c.send(.deviceHello(c.hello(auth: nil)))
        XCTAssertTrue(recorder.wait { recorder.disconnected.contains("idle timeout") })
    }

    func testStalledWifiHandshakesCannotStarveUSB() throws {
        try startServer()
        // Regression: pending LAN sockets used to count against the shared peer cap.
        let squatters = (0..<6).map { _ in TestClient(port: recorder.ports[.wifi]!) }
        defer { squatters.forEach { $0.close() } }
        Thread.sleep(forTimeInterval: 0.3)
        let usb = TestClient(port: recorder.ports[.usb]!)
        defer { usb.close() }
        _ = try XCTUnwrap(usb.challenge(), "USB must still be accepted")
        usb.send(.deviceHello(usb.hello(auth: nil)))
        XCTAssertNotNil(usb.waitFor { if case .deviceReady = $0.payload { return true }; return false })
    }
}
