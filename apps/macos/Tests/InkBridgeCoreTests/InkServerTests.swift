import CryptoKit
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

    /// SHA-256 of the certificate the server presented (TLS only).
    private(set) var serverFingerprint: Data?

    /// `tls` connects like the tablet's Wi-Fi transport: any certificate is
    /// accepted, and its fingerprint recorded for the proofs.
    init(port: UInt16, tls: Bool = false) {
        var params = NWParameters.tcp
        if tls {
            let options = NWProtocolTLS.Options()
            let fingerprintBox = FingerprintBox()
            sec_protocol_options_set_verify_block(options.securityProtocolOptions, { _, trust, complete in
                let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
                if let chain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate], let leaf = chain.first {
                    fingerprintBox.value = Data(SHA256.hash(data: SecCertificateCopyData(leaf) as Data))
                }
                complete(true)
            }, DispatchQueue(label: "test.verify"))
            params = NWParameters(tls: options)
            self.fingerprintBox = fingerprintBox
        }
        connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: params)
        connection.start(queue: queue)
        receive()
    }

    private final class FingerprintBox: @unchecked Sendable { var value: Data? }
    private var fingerprintBox: FingerprintBox?
    var fingerprint: Data { fingerprintBox?.value ?? Data() }

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
              case let .authChallenge(nonce, required, _) = m.payload else { return nil }
        return (Data(hex: nonce)!, required)
    }

    func hello(auth: String?, mode: AuthMode? = nil, deviceID: String = "test-device") -> DeviceHello {
        DeviceHello(deviceID: deviceID, deviceName: "Test Tablet", model: "Sim", androidAPI: 31,
                    streamID: UUID().uuidString, surfaceWidthPx: 1404, surfaceHeightPx: 1872,
                    capabilities: DeviceCapabilities(pressure: true), authMode: mode, auth: auth)
    }

    func error(_ code: String) -> Message? {
        waitFor { if case .error(code, _) = $0.payload { return true }; return false }
    }

    var ready: Message? { waitFor { if case .deviceReady = $0.payload { return true }; return false } }

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
    var paired: [PairedDevice] = []
    var tickets: [PairingTicket?] = []

    func inkServer(_ s: InkServer, didConnect peer: PeerInfo) { locked { connected.append(peer) } }
    func inkServer(_ s: InkServer, peer: PeerInfo, didReceive message: Message, receivedAtNs: Int64) { locked { messages.append(message) } }
    func inkServer(_ s: InkServer, peer: PeerInfo, didUpdateClock clock: ClockSync) { locked { clocks += 1 } }
    func inkServer(_ s: InkServer, didDisconnect peer: PeerInfo, reason: String) { locked { disconnected.append(reason) } }
    func inkServer(_ s: InkServer, listener: TransportKind, didChangeState state: InkServer.ListenerState) {
        if case .listening(let port) = state { locked { ports[listener] = port } }
    }
    func inkServer(_ s: InkServer, didPair device: PairedDevice) { locked { paired.append(device) } }
    func inkServer(_ s: InkServer, pairingTicketChanged ticket: PairingTicket?) { locked { tickets.append(ticket) } }

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

    private var identityDir: URL!
    private var devices: PairedDevices!

    private func startServer(wifi: Bool = true, ping: TimeInterval = 2, idle: TimeInterval = 7) throws {
        identityDir = FileManager.default.temporaryDirectory.appendingPathComponent("inkbridge-test-\(UUID().uuidString)")
        devices = PairedDevices(url: nil)
        let identity = try HostIdentity.loadOrCreate(in: identityDir)
        var config = InkServer.Config(serviceName: "InkBridge Test", sessionID: "session-test", identity: identity, pairedDevices: devices)
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
        if let identityDir { try? FileManager.default.removeItem(at: identityDir) }
        super.tearDown()
    }

    func testUSBHandshakeWithoutPairingAndStrokeDelivery() throws {
        try startServer(wifi: false)
        let c = TestClient(port: recorder.ports[.usb]!)
        defer { c.close() }
        let ch = try XCTUnwrap(c.challenge())
        XCTAssertFalse(ch.required)
        c.send(.deviceHello(c.hello(auth: nil)))
        XCTAssertNotNil(c.waitFor { if case .deviceReady(_, "session-test", _, _) = $0.payload { return true }; return false })

        c.send(.strokeBegin(strokeID: "s1", tool: .pen, point: InkPoint(x: 0.1, y: 0.1, p: 0.5, t: 1)))
        c.send(.strokePoint(strokeID: "s1", points: [InkPoint(x: 0.2, y: 0.2, p: 0.6, t: 2)]))
        c.send(.strokeEnd(strokeID: "s1"))
        XCTAssertTrue(recorder.wait { recorder.messages.count == 4 })  // hello + 3 stroke messages
        let types = recorder.locked { recorder.messages.map(\.payload.type) }
        XCTAssertEqual(types, ["device.hello", "stroke.begin", "stroke.point", "stroke.end"])
        let seqs = recorder.locked { recorder.messages.map(\.sequence) }
        XCTAssertEqual(seqs, [1, 2, 3, 4], "order must be preserved")
    }

    /// Pairs `deviceID` over TLS with the open ticket and returns the issued token.
    private func pair(code: String, deviceID: String = "test-device") throws -> Data {
        let c = TestClient(port: recorder.ports[.wifi]!, tls: true)
        defer { c.close() }
        let ch = try XCTUnwrap(c.challenge())
        XCTAssertTrue(ch.required)
        XCTAssertEqual(c.fingerprint.count, 32, "Wi-Fi must be TLS")
        c.send(.deviceHello(c.hello(auth: PairingAuth.pairProof(code: code, nonce: ch.nonce, fingerprint: c.fingerprint),
                                    mode: .pair, deviceID: deviceID)))
        let granted = try XCTUnwrap(c.waitFor { if case .pairGranted = $0.payload { return true }; return false })
        guard case let .pairGranted(hostID, _, token, proof) = granted.payload else { throw XCTSkip() }
        XCTAssertEqual(hostID, server.config.hostID)
        XCTAssertEqual(PairingAuth.hostProof(code: code, nonce: ch.nonce, fingerprint: c.fingerprint), proof,
                       "the Mac proves it knows the code too")
        XCTAssertNotNil(c.ready)
        return try XCTUnwrap(Data(hex: token))
    }

    func testWifiPairingOverTLSThenTokenReconnect() throws {
        try startServer()
        let ticket = server.openPairing()
        let token = try pair(code: ticket.code.lowercased())
        XCTAssertEqual(token.count, 32)
        XCTAssertTrue(recorder.wait { recorder.paired.first?.deviceID == "test-device" })
        XCTAssertTrue(recorder.wait { recorder.tickets.last == .some(nil) }, "a code is single-use")
        XCTAssertTrue(devices.contains("test-device"))

        // Later connections prove the token; no window needs to be open.
        let again = TestClient(port: recorder.ports[.wifi]!, tls: true)
        defer { again.close() }
        let ch = try XCTUnwrap(again.challenge())
        XCTAssertEqual(again.fingerprint, server.config.identity!.fingerprint, "pinning target is stable")
        again.send(.deviceHello(again.hello(auth: PairingAuth.tokenProof(token: token, nonce: ch.nonce, fingerprint: again.fingerprint),
                                            mode: .token)))
        XCTAssertNotNil(again.ready)
        XCTAssertTrue(recorder.wait { recorder.connected.count == 2 && recorder.connected.allSatisfy { $0.kind == .wifi } })
    }

    func testWifiRejections() throws {
        try startServer()
        func attempt(_ make: (TestClient, Data) -> DeviceHello) throws -> TestClient {
            let c = TestClient(port: recorder.ports[.wifi]!, tls: true)
            let ch = try XCTUnwrap(c.challenge())
            c.send(.deviceHello(make(c, ch.nonce)))
            return c
        }
        // No window open: even the right-looking code is refused.
        let closed = try attempt { c, n in c.hello(auth: PairingAuth.pairProof(code: "K7QW-M3XP", nonce: n, fingerprint: c.fingerprint), mode: .pair) }
        XCTAssertNotNil(closed.error("pairing_closed")); closed.close()

        let ticket = server.openPairing(code: "K7QW-M3XP")
        let wrong = try attempt { c, n in c.hello(auth: PairingAuth.pairProof(code: "AAAA-AAAA", nonce: n, fingerprint: c.fingerprint), mode: .pair) }
        XCTAssertNotNil(wrong.error("auth_failed")); wrong.close()

        // A proof over a different certificate (what a MITM would get) fails.
        let mitm = try attempt { c, n in c.hello(auth: PairingAuth.pairProof(code: ticket.code, nonce: n, fingerprint: Data(repeating: 7, count: 32)), mode: .pair) }
        XCTAssertNotNil(mitm.error("auth_failed")); mitm.close()

        let none = try attempt { c, _ in c.hello(auth: nil) }
        XCTAssertNotNil(none.error("auth_required")); none.close()

        let unknown = try attempt { c, n in
            c.hello(auth: PairingAuth.tokenProof(token: Data(repeating: 9, count: 32), nonce: n, fingerprint: c.fingerprint), mode: .token, deviceID: "stranger")
        }
        XCTAssertNotNil(unknown.error("not_paired")); unknown.close()
        XCTAssertTrue(recorder.locked { recorder.connected.isEmpty })
    }

    func testTicketIsVoidAfterRepeatedWrongCodes() throws {
        try startServer()
        server.openPairing(code: "K7QW-M3XP")
        for i in 0..<PairingTicket.maxFailures {
            let c = TestClient(port: recorder.ports[.wifi]!, tls: true)
            let ch = try XCTUnwrap(c.challenge(), "attempt \(i)")
            c.send(.deviceHello(c.hello(auth: PairingAuth.pairProof(code: "WRNG-CODE", nonce: ch.nonce, fingerprint: c.fingerprint), mode: .pair,
                                        deviceID: "d\(i)")))
            XCTAssertNotNil(c.error("auth_failed"))
            c.close()
        }
        XCTAssertTrue(recorder.wait { recorder.tickets.last == .some(nil) }, "too many guesses void the code")
        XCTAssertNil(server.queue.sync { server.validPairingCode })
    }

    func testForgetDisconnectsAndRequiresPairingAgain() throws {
        try startServer()
        let token = try pair(code: server.openPairing().code)
        let c = TestClient(port: recorder.ports[.wifi]!, tls: true)
        defer { c.close() }
        let ch = try XCTUnwrap(c.challenge())
        c.send(.deviceHello(c.hello(auth: PairingAuth.tokenProof(token: token, nonce: ch.nonce, fingerprint: c.fingerprint), mode: .token)))
        XCTAssertNotNil(c.ready)
        server.forget(deviceID: "test-device")
        XCTAssertNotNil(c.waitFor { if case .deviceDisconnect = $0.payload { return true }; return false })
        XCTAssertFalse(devices.contains("test-device"))
    }

    func testReadyReportsWhatTheHostAlreadyHasForTheStream() throws {
        try startServer(wifi: false)
        let stream = UUID().uuidString
        func hello(_ c: TestClient) -> DeviceHello {
            var h = c.hello(auth: nil)
            h.streamID = stream
            return h
        }
        let first = TestClient(port: recorder.ports[.usb]!)
        _ = try XCTUnwrap(first.challenge())
        first.send(.deviceHello(hello(first)))
        XCTAssertNotNil(first.ready)
        first.send(.strokeEnd(strokeID: "a"))
        first.send(.strokeEnd(strokeID: "b"))  // sequence 3
        XCTAssertTrue(recorder.wait { recorder.messages.count == 3 })
        first.close()

        // Same tablet process reconnects: the host says it holds up to 3, so nothing is re-sent twice.
        let second = TestClient(port: recorder.ports[.usb]!)
        defer { second.close() }
        _ = try XCTUnwrap(second.challenge())
        second.send(.deviceHello(hello(second)))
        let ready = try XCTUnwrap(second.ready)
        guard case let .deviceReady(_, _, _, resume) = ready.payload else { return XCTFail() }
        XCTAssertEqual(resume, 3)
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

    func testFailedListenerIsRetriedWhenPortFrees() throws {
        // Hold a loopback port so the USB listener fails at startup.
        let blocker = NWListener.blockingLoopback()
        defer { blocker?.listener.cancel() }
        let port = try XCTUnwrap(blocker?.port)
        var config = InkServer.Config(serviceName: "Retry", sessionID: "s", identity: nil, pairedDevices: PairedDevices(url: nil))
        config.usbPort = port
        config.wifiEnabled = false
        let rec = Recorder()
        let srv = InkServer(config: config, delegateQueue: DispatchQueue(label: "retry.delegate"))
        srv.restartDelay = 0.2
        srv.delegate = rec
        srv.start()
        defer { srv.stop() }
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertNil(rec.locked { rec.ports[.usb] }, "listener should fail while the port is held")
        blocker?.listener.cancel()
        XCTAssertTrue(rec.wait(timeout: 5) { rec.ports[.usb] == port }, "listener must recover once the port frees")
    }
}

final class HostIdentityTests: XCTestCase {
    func testIdentityPersistsAndCertificateParses() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("inkbridge-id-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try HostIdentity.loadOrCreate(in: dir)
        let b = try HostIdentity.loadOrCreate(in: dir)
        XCTAssertEqual(a.fingerprint, b.fingerprint, "the pin must survive restarts")
        XCTAssertEqual(a.hostID, b.hostID)
        let perms = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("host-key.raw").path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)

        // An independent parser accepts the DER and the self-signature.
        let der = dir.appendingPathComponent("host-cert.der")
        let pem = dir.appendingPathComponent("host-cert.pem")
        XCTAssertEqual(try run("/usr/bin/openssl", "x509", "-inform", "der", "-in", der.path, "-out", pem.path), 0)
        XCTAssertEqual(try run("/usr/bin/openssl", "verify", "-CAfile", pem.path, pem.path), 0, "self-signature must verify")
    }

    private func run(_ args: String...) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: args[0])
        p.arguments = Array(args.dropFirst())
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }
}

private extension NWListener {
    /// A listener bound to an ephemeral loopback port, returned once ready.
    static func blockingLoopback() -> (listener: NWListener, port: UInt16)? {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        guard let l = try? NWListener(using: params) else { return nil }
        let ready = DispatchSemaphore(value: 0)
        l.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        l.newConnectionHandler = { $0.cancel() }
        l.start(queue: DispatchQueue(label: "blocker"))
        guard ready.wait(timeout: .now() + 3) == .success, let p = l.port?.rawValue else { return nil }
        return (l, p)
    }
}
