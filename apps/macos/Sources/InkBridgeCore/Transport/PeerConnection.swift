import Foundation
import Network

/// One device connection: framing, handshake, keep-alive.
///
/// State machine:
///
///     connecting ──ready──▶ awaitingHello ──valid hello──▶ ready ──▶ closed
///          │                     │ bad auth / timeout        │ idle / error
///          └─────────────────────┴───────────────────────────┴──▶ closed
///
/// Runs entirely on the server's serial queue.
final class PeerConnection {
    enum State {
        case connecting
        case awaitingHello(nonce: Data, authRequired: Bool)
        case ready(PeerInfo)
        case closed
    }

    let id = UUID()
    let kind: TransportKind
    let remoteHost: String
    private unowned let server: InkServer
    private let connection: NWConnection
    private var state: State = .connecting
    private var decoder = FrameDecoder()
    private var sequence: UInt64 = 0
    private var clock = ClockSync()
    private var pendingPings: [UInt64: Int64] = [:]
    private var nextPingID: UInt64 = 1
    private var lastInbound = monotonicNowNs()
    private var timers: [DispatchSourceTimer] = []
    private var badMessages = 0
    /// Set once the device has said hello; used to find its connections.
    private(set) var deviceID: String?

    init(server: InkServer, connection: NWConnection, kind: TransportKind, remoteHost: String) {
        self.server = server
        self.connection = connection
        self.kind = kind
        self.remoteHost = remoteHost
    }

    var isReady: Bool {
        if case .ready = state { return true }
        return false
    }

    private var info: PeerInfo? {
        if case .ready(let info) = state { return info }
        return nil
    }

    func start(authRequired: Bool) {
        connection.stateUpdateHandler = { [weak self] st in
            guard let self else { return }
            switch st {
            case .ready:
                self.beginHandshake(authRequired: authRequired)
            case .failed(let e):
                self.close(reason: "connection failed: \(e.localizedDescription)", notifyPeer: false)
            case .cancelled:
                self.close(reason: "connection cancelled", notifyPeer: false)
            default:
                break
            }
        }
        connection.start(queue: server.queue)
        receive()
    }

    // MARK: Handshake

    private func beginHandshake(authRequired: Bool) {
        let nonce = PairingAuth.generateNonce()
        state = .awaitingHello(nonce: nonce, authRequired: authRequired)
        // The host always speaks first so the device knows whether to authenticate.
        send(.authChallenge(nonce: nonce.hexString, required: authRequired, hostID: server.config.hostID))
        schedule(after: server.config.handshakeTimeout) { [weak self] in
            guard let self, case let .awaitingHello(_, authRequired) = self.state else { return }
            // On the LAN a stalled handshake is an attempt that never proved the
            // code; count it so idle sockets cannot be opened for free.
            if authRequired { self.server.recordAuthFailure(host: self.remoteHost) }
            self.reject(code: "handshake_timeout", "no device.hello received")
        }
    }

    private func handleHello(_ hello: DeviceHello, nonce: Data, authRequired: Bool) {
        deviceID = hello.deviceID
        var granted: PairedDevice?
        if authRequired {
            switch authenticate(hello, nonce: nonce) {
            case .success(let device): granted = device
            case .failure(let failure):
                server.log.notice("auth failed for \(hello.deviceName, privacy: .public): \(failure.code, privacy: .public)")
                reject(code: failure.code, failure.message)
                return
            }
        }
        let info = PeerInfo(id: id, kind: kind, hello: hello, remote: String(describing: connection.endpoint))
        state = .ready(info)
        if authRequired { server.recordAuthSuccess(host: remoteHost) }
        let resume = server.highWater(for: hello.streamID)
        send(.deviceReady(hostName: server.config.serviceName, sessionID: server.config.sessionID, hostID: server.config.hostID,
                          resumeSequence: resume))
        server.log.info("device ready: \(hello.deviceName, privacy: .public) via \(self.kind.rawValue, privacy: .public)")
        if let granted { server.pairingSucceeded(granted) }
        server.peerAuthenticated(self, info: info)
        startKeepAlive()
    }

    struct AuthFailure: Error {
        var code: String
        var message: String
    }

    /// Checks a LAN device's proof. On a successful `.pair` it also issues the
    /// token and sends `pair.granted` (before `device.ready`).
    private func authenticate(_ hello: DeviceHello, nonce: Data) -> Result<PairedDevice?, AuthFailure> {
        let fingerprint = server.fingerprint(for: kind)
        guard let proof = hello.auth, let mode = hello.authMode else {
            server.recordAuthFailure(host: remoteHost)
            return .failure(AuthFailure(code: "auth_required", message: "pair this tablet from Connect Device on the Mac"))
        }
        let store = server.config.pairedDevices
        switch mode {
        case .token:
            guard let token = store.token(for: hello.deviceID) else {
                // Not a guess against a secret, so not throttled: the Mac forgot this device.
                return .failure(AuthFailure(code: "not_paired", message: "this Mac no longer knows this tablet; pair again"))
            }
            guard PairingAuth.verifyToken(proof, token: token, nonce: nonce, fingerprint: fingerprint) else {
                server.recordAuthFailure(host: remoteHost)
                return .failure(AuthFailure(code: "auth_failed", message: "device token rejected"))
            }
            store.touch(hello.deviceID, name: hello.deviceName)
            return .success(nil)
        case .pair:
            guard let code = server.validPairingCode else {
                server.recordAuthFailure(host: remoteHost)
                return .failure(AuthFailure(code: "pairing_closed", message: "open Connect Device on the Mac to get a new code"))
            }
            guard PairingAuth.verifyPair(proof, code: code, nonce: nonce, fingerprint: fingerprint) else {
                server.recordAuthFailure(host: remoteHost)
                server.pairingFailed()
                return .failure(AuthFailure(code: "auth_failed", message: "wrong pairing code"))
            }
            let token = store.add(deviceID: hello.deviceID, name: hello.deviceName, model: hello.model)
            send(.pairGranted(hostID: server.config.hostID, hostName: server.config.serviceName, token: token.hexString,
                              proof: PairingAuth.hostProof(code: code, nonce: nonce, fingerprint: fingerprint)))
            let device = store.all.first { $0.deviceID == hello.deviceID }
            return .success(device)
        }
    }

    private func reject(code: String, _ message: String) {
        send(.error(code: code, message: message))
        close(reason: message, notifyPeer: false)
    }

    // MARK: Keep-alive

    private func startKeepAlive() {
        let interval = server.config.pingInterval
        repeatEvery(interval) { [weak self] in
            guard let self else { return }
            let idleNs = monotonicNowNs() - self.lastInbound
            if Double(idleNs) / 1e9 > self.server.config.idleTimeout {
                self.close(reason: "idle timeout", notifyPeer: true)
                return
            }
            let pingID = self.nextPingID
            self.nextPingID += 1
            let now = monotonicNowNs()
            self.pendingPings[pingID] = now
            // Bound the table if the peer never answers.
            if self.pendingPings.count > 8, let oldest = self.pendingPings.keys.min() {
                self.pendingPings.removeValue(forKey: oldest)
            }
            self.send(.ping(pingID: pingID), timestamp: now)
        }
    }

    // MARK: I/O

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: FrameCodec.maxPayloadSize) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.lastInbound = monotonicNowNs()
                self.decoder.append(data)
                self.drainFrames()
            }
            if case .closed = self.state { return }
            if let error {
                self.close(reason: "receive error: \(error.localizedDescription)", notifyPeer: false)
            } else if complete {
                self.close(reason: "peer closed the connection", notifyPeer: false)
            } else {
                self.receive()
            }
        }
    }

    private func drainFrames() {
        while true {
            let frame: Data
            do {
                guard let f = try decoder.nextFrame() else { return }
                frame = f
            } catch {
                // A bad length header means we have lost frame sync; nothing after it can be trusted.
                reject(code: "bad_frame", "\(error)")
                return
            }
            let receivedAt = monotonicNowNs()
            do {
                handle(try MessageCodec.decode(frame), receivedAt: receivedAt)
            } catch let error as ProtocolError where error.isRecoverable {
                continue
            } catch {
                badMessages += 1
                server.log.error("invalid message: \(String(describing: error), privacy: .public)")
                if badMessages > 50 {
                    reject(code: "too_many_errors", "too many invalid messages")
                    return
                }
                send(.error(code: "invalid_message", message: "\(error)"))
            }
            if case .closed = state { return }
        }
    }

    private func handle(_ message: Message, receivedAt: Int64) {
        switch state {
        case let .awaitingHello(nonce, authRequired):
            if case let .deviceHello(hello) = message.payload {
                handleHello(hello, nonce: nonce, authRequired: authRequired)
                if let info { server.peer(info, received: message, at: receivedAt) }
            } else {
                reject(code: "handshake_required", "expected device.hello")
            }
        case let .ready(info):
            server.noteSequence(message.sequence, stream: info.hello.streamID)
            switch message.payload {
            case let .ping(pingID):
                send(.pong(pingID: pingID, echoTimestampNs: message.timestampNs))
            case let .pong(pingID, _):
                guard let sent = pendingPings.removeValue(forKey: pingID) else { return }
                clock.addPong(hostSentNs: sent, deviceNs: message.timestampNs, hostReceivedNs: receivedAt)
                server.peer(info, clock: clock)
            case let .deviceDisconnect(reason):
                close(reason: "device disconnected: \(reason)", notifyPeer: false)
            default:
                server.peer(info, received: message, at: receivedAt)
            }
        case .connecting, .closed:
            break
        }
    }

    func send(_ payload: Payload, timestamp: Int64 = monotonicNowNs()) {
        if case .closed = state { return }
        sequence += 1
        let message = Message(sequence: sequence, timestampNs: timestamp, payload: payload)
        guard let frame = try? FrameCodec.frame(message) else { return }
        connection.send(content: frame, completion: .contentProcessed { _ in })
    }

    func close(reason: String, notifyPeer: Bool) {
        if case .closed = state { return }
        if notifyPeer { send(.deviceDisconnect(reason: reason)) }
        let closingInfo = info
        state = .closed
        timers.forEach { $0.cancel() }
        timers.removeAll()
        // Let queued sends (error / disconnect) flush before tearing down.
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [connection] _ in
            connection.cancel()
        })
        server.peerClosed(self, info: closingInfo, reason: reason)
    }

    // MARK: Timers

    private func schedule(after seconds: TimeInterval, _ body: @escaping () -> Void) {
        let t = DispatchSource.makeTimerSource(queue: server.queue)
        t.schedule(deadline: .now() + seconds)
        t.setEventHandler(handler: body)
        t.resume()
        timers.append(t)
    }

    private func repeatEvery(_ seconds: TimeInterval, _ body: @escaping () -> Void) {
        let t = DispatchSource.makeTimerSource(queue: server.queue)
        t.schedule(deadline: .now() + seconds, repeating: seconds, leeway: .milliseconds(50))
        t.setEventHandler(handler: body)
        t.resume()
        timers.append(t)
    }
}
