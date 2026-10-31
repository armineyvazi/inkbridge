import Foundation
import Network
import os

/// A connected, authenticated device as seen by the delegate.
public struct PeerInfo: Equatable, Sendable {
    public var id: UUID
    public var kind: TransportKind
    public var hello: DeviceHello
    public var remote: String
}

/// Receives server events on the delegate queue (main by default).
public protocol InkServerDelegate: AnyObject {
    func inkServer(_ server: InkServer, didConnect peer: PeerInfo)
    func inkServer(_ server: InkServer, peer: PeerInfo, didReceive message: Message, receivedAtNs: Int64)
    func inkServer(_ server: InkServer, peer: PeerInfo, didUpdateClock clock: ClockSync)
    func inkServer(_ server: InkServer, didDisconnect peer: PeerInfo, reason: String)
    func inkServer(_ server: InkServer, listener: TransportKind, didChangeState state: InkServer.ListenerState)
}

/// Accepts device connections over USB (loopback) and Wi-Fi (LAN).
///
/// Both listeners speak the same framed protocol; the only difference is
/// trust. The loopback listener is reachable only from this Mac (which is
/// where `adb reverse` delivers the tablet's traffic), so it does not ask for
/// the pairing code. The LAN listener is reachable by anything on the network,
/// so every connection must answer a pairing challenge before it can draw.
///
/// All socket work happens on one private serial queue.
public final class InkServer {
    public struct Config: Sendable {
        public var usbPort: UInt16 = 8765
        public var wifiPort: UInt16 = 8766
        public var wifiEnabled = true
        public var serviceName: String
        public var pairingCode: String
        public var sessionID: String
        public var handshakeTimeout: TimeInterval = 5
        public var pingInterval: TimeInterval = 2
        /// A peer that sends nothing for this long is presumed gone.
        public var idleTimeout: TimeInterval = 7
        /// Authenticated devices at once.
        public var maxPeers = 4
        /// Connections still in the handshake, per transport. Separate caps mean
        /// idle LAN sockets can never block the USB tablet from connecting.
        public var maxPendingPerTransport = 4

        public init(serviceName: String, pairingCode: String, sessionID: String) {
            self.serviceName = serviceName
            self.pairingCode = pairingCode
            self.sessionID = sessionID
        }
    }

    public enum ListenerState: Equatable, Sendable {
        case stopped, starting, listening(port: UInt16), failed(String)
    }

    public static let bonjourType = "_inkbridge._tcp"

    public weak var delegate: InkServerDelegate?
    public let delegateQueue: DispatchQueue

    let queue = DispatchQueue(label: "inkbridge.server")
    private(set) var config: Config
    private var listeners: [TransportKind: NWListener] = [:]
    private var running = false
    private var restartAttempts: [TransportKind: Int] = [:]
    /// Delay before retrying a listener that failed (e.g. port still held by a
    /// process that is exiting). Doubles per attempt up to `maxRestartDelay`.
    var restartDelay: TimeInterval = 1
    var maxRestartDelay: TimeInterval = 10
    private var peers: [UUID: PeerConnection] = [:]
    private var throttle = AuthThrottle()
    let log = Logger(subsystem: "app.inkbridge", category: "server")

    public init(config: Config, delegateQueue: DispatchQueue = .main) {
        self.config = config
        self.delegateQueue = delegateQueue
    }

    // MARK: Lifecycle

    public func start() {
        queue.async { [self] in
            running = true
            startListener(.usb)
            if config.wifiEnabled { startListener(.wifi) }
        }
    }

    public func stop() {
        queue.async { [self] in
            running = false
            listeners.values.forEach { $0.cancel() }
            listeners.removeAll()
            peers.values.forEach { $0.close(reason: "server stopped", notifyPeer: true) }
        }
    }

    /// Changing the pairing code disconnects Wi-Fi peers that used the old one.
    public func setPairingCode(_ code: String) {
        queue.async { [self] in
            config.pairingCode = code
            peers.values.filter { $0.kind == .wifi }.forEach { $0.close(reason: "pairing code changed", notifyPeer: true) }
        }
    }

    public func setWifiEnabled(_ enabled: Bool) {
        queue.async { [self] in
            guard enabled != config.wifiEnabled else { return }
            config.wifiEnabled = enabled
            if enabled {
                startListener(.wifi)
            } else {
                listeners.removeValue(forKey: .wifi)?.cancel()
                peers.values.filter { $0.kind == .wifi }.forEach { $0.close(reason: "Wi-Fi disabled", notifyPeer: true) }
                notify { $0.inkServer(self, listener: .wifi, didChangeState: .stopped) }
            }
        }
    }

    public func setSessionID(_ id: String) {
        queue.async { [self] in config.sessionID = id }
    }

    /// Sends a message to one peer. Sequence and timestamp are filled in.
    public func send(_ payload: Payload, to peerID: UUID) {
        queue.async { [self] in peers[peerID]?.send(payload) }
    }

    // MARK: Listeners

    private func startListener(_ kind: TransportKind) {
        let params = NWParameters.tcp
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            // Stroke messages are tiny and latency-critical; never wait to coalesce.
            tcp.noDelay = true
        }
        params.allowLocalEndpointReuse = true
        let port = kind == .usb ? config.usbPort : config.wifiPort

        let listener: NWListener
        do {
            if kind == .usb {
                params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
                listener = try NWListener(using: params)
            } else {
                listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
                listener.service = NWListener.Service(name: config.serviceName, type: Self.bonjourType)
            }
        } catch {
            notify { $0.inkServer(self, listener: kind, didChangeState: .failed(error.localizedDescription)) }
            scheduleRestart(kind)
            return
        }

        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            let mapped: ListenerState
            switch state {
            case .ready:
                mapped = .listening(port: listener.port?.rawValue ?? port)
                self.restartAttempts[kind] = 0
            case .failed(let e):
                mapped = .failed(e.localizedDescription)
                listener.cancel()
                if self.listeners[kind] === listener { self.listeners[kind] = nil }
                self.scheduleRestart(kind)
            case .cancelled: mapped = .stopped
            default: mapped = .starting
            }
            self.log.info("\(kind.rawValue, privacy: .public) listener: \(String(describing: state), privacy: .public)")
            self.notify { $0.inkServer(self, listener: kind, didChangeState: mapped) }
        }
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn, kind: kind) }
        listener.start(queue: queue)
        listeners[kind] = listener
    }

    /// A failed listener would otherwise leave that transport dead until the
    /// app restarts; retry with backoff while the server should be running.
    private func scheduleRestart(_ kind: TransportKind) {
        let attempt = restartAttempts[kind, default: 0]
        restartAttempts[kind] = attempt + 1
        let delay = min(restartDelay * pow(2, Double(attempt)), maxRestartDelay)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.running, self.listeners[kind] == nil else { return }
            if kind == .wifi && !self.config.wifiEnabled { return }
            self.startListener(kind)
        }
    }

    private func accept(_ connection: NWConnection, kind: TransportKind) {
        let pending = peers.values.filter { $0.kind == kind && !$0.isReady }.count
        let ready = peers.values.filter(\.isReady).count
        let host = Self.remoteHost(connection.endpoint)
        if pending >= config.maxPendingPerTransport || ready >= config.maxPeers
            || (kind == .wifi && throttle.isLockedOut(host: host)) {
            log.notice("rejecting \(host, privacy: .public): limit or lockout")
            connection.cancel()
            return
        }
        let peer = PeerConnection(server: self, connection: connection, kind: kind, remoteHost: host)
        peers[peer.id] = peer
        peer.start(authRequired: kind == .wifi)
    }

    // MARK: Peer callbacks (on `queue`)

    var pairingCode: String { config.pairingCode }

    func peerAuthenticated(_ peer: PeerConnection, info: PeerInfo) {
        notify { $0.inkServer(self, didConnect: info) }
    }

    func peer(_ info: PeerInfo, received message: Message, at ns: Int64) {
        notify { $0.inkServer(self, peer: info, didReceive: message, receivedAtNs: ns) }
    }

    func peer(_ info: PeerInfo, clock: ClockSync) {
        notify { $0.inkServer(self, peer: info, didUpdateClock: clock) }
    }

    func peerClosed(_ peer: PeerConnection, info: PeerInfo?, reason: String) {
        peers.removeValue(forKey: peer.id)
        if let info { notify { $0.inkServer(self, didDisconnect: info, reason: reason) } }
    }

    func recordAuthFailure(host: String) {
        throttle.recordFailure(host: host)
    }

    func recordAuthSuccess(host: String) {
        throttle.recordSuccess(host: host)
    }

    /// The remote IP without the port, used as the throttling key.
    static func remoteHost(_ endpoint: NWEndpoint) -> String {
        if case let .hostPort(host, _) = endpoint { return "\(host)" }
        return String(describing: endpoint)
    }

    private func notify(_ body: @escaping (InkServerDelegate) -> Void) {
        delegateQueue.async { [weak self] in
            guard let delegate = self?.delegate else { return }
            body(delegate)
        }
    }
}
