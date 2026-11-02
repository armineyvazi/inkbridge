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
  func inkServer(
    _ server: InkServer, peer: PeerInfo, didReceive message: Message, receivedAtNs: Int64)
  func inkServer(_ server: InkServer, peer: PeerInfo, didUpdateClock clock: ClockSync)
  func inkServer(_ server: InkServer, didDisconnect peer: PeerInfo, reason: String)
  func inkServer(
    _ server: InkServer, listener: TransportKind, didChangeState state: InkServer.ListenerState)
  /// A device proved the Connect Device code and now has a token.
  func inkServer(_ server: InkServer, didPair device: PairedDevice)
  /// The Connect Device ticket was used up, expired or voided; nil means none is open.
  func inkServer(_ server: InkServer, pairingTicketChanged ticket: PairingTicket?)
}

extension InkServerDelegate {
  public func inkServer(_ server: InkServer, didPair device: PairedDevice) {}
  public func inkServer(_ server: InkServer, pairingTicketChanged ticket: PairingTicket?) {}
}

/// Accepts device connections over USB (loopback) and Wi-Fi (LAN).
///
/// Both listeners speak the same framed protocol; the only difference is
/// trust. The loopback listener is reachable only from this Mac (which is
/// where `adb reverse` delivers the tablet's traffic), so it is plain TCP and
/// asks for no proof. The LAN listener is reachable by anything on the
/// network: it is TLS with the Mac's pinned self-signed certificate
/// (HostIdentity), and every connection must prove either its device token
/// or, while a Connect Device window is open, the short-lived pairing code
/// (protocol v3, docs/architecture/wireless-connection.md).
///
/// All socket work happens on one private serial queue.
public final class InkServer {
  public struct Config: Sendable {
    public var usbPort: UInt16 = 8765
    public var wifiPort: UInt16 = 8766
    public var wifiEnabled = true
    public var serviceName: String
    public var sessionID: String
    /// Stable ID sent in `auth.challenge` so devices know which Mac they reached.
    public var hostID: String
    /// TLS identity for the LAN listener. Without one Wi-Fi stays off.
    public var identity: HostIdentity?
    public var pairedDevices: PairedDevices
    /// How long a Connect Device code stays valid.
    public var pairingDuration: TimeInterval = 300
    public var handshakeTimeout: TimeInterval = 5
    public var pingInterval: TimeInterval = 2
    /// A peer that sends nothing for this long is presumed gone.
    public var idleTimeout: TimeInterval = 7
    /// Authenticated devices at once.
    public var maxPeers = 4
    /// Connections still in the handshake, per transport. Separate caps mean
    /// idle LAN sockets can never block the USB tablet from connecting.
    public var maxPendingPerTransport = 4

    public init(
      serviceName: String, sessionID: String, identity: HostIdentity?,
      pairedDevices: PairedDevices, hostID: String? = nil
    ) {
      self.serviceName = serviceName
      self.sessionID = sessionID
      self.identity = identity
      self.pairedDevices = pairedDevices
      self.hostID = hostID ?? identity?.hostID ?? "local-host"
    }
  }

  public enum ListenerState: Equatable, Sendable {
    case stopped, starting
    case listening(port: UInt16)
    case failed(String)
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
  /// Highest sequence received per device stream, across connections.
  private var streamHighWater: [String: UInt64] = [:]
  private var ticket: PairingTicket?
  private var ticketTimer: DispatchSourceTimer?
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

  // MARK: Pairing

  /// Opens (or renews) the Connect Device window: a fresh single-use code,
  /// valid for `pairingDuration`. Already-paired devices are unaffected.
  @discardableResult
  public func openPairing(code: String = PairingAuth.generateCode()) -> PairingTicket {
    queue.sync {
      let t = PairingTicket(
        code: code, expiresAt: Date().addingTimeInterval(config.pairingDuration))
      setTicket(t)
      ticketTimer?.cancel()
      let timer = DispatchSource.makeTimerSource(queue: queue)
      timer.schedule(deadline: .now() + config.pairingDuration)
      timer.setEventHandler { [weak self] in
        guard let self, self.ticket?.code == t.code else { return }
        self.setTicket(nil)
      }
      timer.resume()
      ticketTimer = timer
      return t
    }
  }

  public func closePairing() {
    queue.async { [self] in
      ticketTimer?.cancel()
      setTicket(nil)
    }
  }

  /// Removes a device's token and drops its Wi-Fi connection; it must pair again.
  public func forget(deviceID: String) {
    queue.async { [self] in
      config.pairedDevices.remove(deviceID)
      peers.values.filter { $0.kind == .wifi && $0.deviceID == deviceID }
        .forEach { $0.close(reason: "device forgotten on the Mac", notifyPeer: true) }
    }
  }

  private func setTicket(_ t: PairingTicket?) {
    ticket = t
    notify { $0.inkServer(self, pairingTicketChanged: t) }
  }

  /// The open ticket's code, or nil if none is open or it has expired.
  var validPairingCode: String? {
    guard let t = ticket, t.isValid() else { return nil }
    return t.code
  }

  func pairingFailed() {
    guard var t = ticket else { return }
    t.failures += 1
    setTicket(t.isValid() ? t : nil)
  }

  func pairingSucceeded(_ device: PairedDevice) {
    ticketTimer?.cancel()
    setTicket(nil)  // single use
    notify { $0.inkServer(self, didPair: device) }
  }

  /// Restarts the LAN listener, e.g. after wake or a network change, so the
  /// Bonjour advertisement is re-registered on the current interfaces.
  public func restartWifiListener() {
    queue.async { [self] in
      guard running, config.wifiEnabled else { return }
      listeners.removeValue(forKey: .wifi)?.cancel()
      restartAttempts[.wifi] = 0
      startListener(.wifi)
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
        peers.values.filter { $0.kind == .wifi }.forEach {
          $0.close(reason: "Wi-Fi disabled", notifyPeer: true)
        }
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
    let tcp = NWProtocolTCP.Options()
    // Stroke messages are tiny and latency-critical; never wait to coalesce.
    tcp.noDelay = true
    let params: NWParameters
    if kind == .wifi {
      guard let identity = config.identity else {
        notify { $0.inkServer(self, listener: kind, didChangeState: .failed("no TLS identity")) }
        return
      }
      let tls = NWProtocolTLS.Options()
      let sec = tls.securityProtocolOptions
      sec_protocol_options_set_local_identity(sec, sec_identity_create(identity.secIdentity)!)
      sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv12)
      params = NWParameters(tls: tls, tcp: tcp)
    } else {
      params = NWParameters(tls: nil, tcp: tcp)
    }
    params.allowLocalEndpointReuse = true
    let port = kind == .usb ? config.usbPort : config.wifiPort

    let listener: NWListener
    do {
      if kind == .usb {
        params.requiredLocalEndpoint = .hostPort(
          host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        listener = try NWListener(using: params)
      } else {
        listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        // TXT lets a tablet recognise its paired Mac after the IP changes.
        var txt = NWTXTRecord()
        txt["id"] = config.hostID
        txt["v"] = String(inkProtocolVersion)
        listener.service = NWListener.Service(
          name: config.serviceName, type: Self.bonjourType, domain: nil, txtRecord: txt)
      }
    } catch {
      notify {
        $0.inkServer(self, listener: kind, didChangeState: .failed(error.localizedDescription))
      }
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
      self.log.info(
        "\(kind.rawValue, privacy: .public) listener: \(String(describing: state), privacy: .public)"
      )
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
      || (kind == .wifi && throttle.isLockedOut(host: host))
    {
      log.notice("rejecting \(host, privacy: .public): limit or lockout")
      connection.cancel()
      return
    }
    let peer = PeerConnection(server: self, connection: connection, kind: kind, remoteHost: host)
    peers[peer.id] = peer
    peer.start(authRequired: kind == .wifi)
  }

  // MARK: Peer callbacks (on `queue`)

  func highWater(for stream: String) -> UInt64 { streamHighWater[stream] ?? 0 }

  func noteSequence(_ sequence: UInt64, stream: String) {
    if streamHighWater[stream] == nil && streamHighWater.count >= 64 {
      // Streams are per app process; old ones never come back. Keep the table small.
      streamHighWater.removeAll()
    }
    streamHighWater[stream] = max(streamHighWater[stream] ?? 0, sequence)
  }

  /// What a device on `kind` must prove over: the certificate it was shown.
  func fingerprint(for kind: TransportKind) -> Data {
    kind == .wifi ? (config.identity?.fingerprint ?? Data()) : Data()
  }

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
    if case .hostPort(let host, _) = endpoint { return "\(host)" }
    return String(describing: endpoint)
  }

  private func notify(_ body: @escaping (InkServerDelegate) -> Void) {
    delegateQueue.async { [weak self] in
      guard let delegate = self?.delegate else { return }
      body(delegate)
    }
  }
}
