import Foundation

/// How a peer reached us.
public enum TransportKind: String, Codable, Sendable {
  /// Loopback, i.e. USB through `adb reverse`.
  case usb
  /// LAN TCP, authenticated with the pairing code.
  case wifi
}

/// Chooses which connected peer's strokes are drawn.
///
/// Only one peer is "active" at a time; strokes from the others are ignored.
/// That is what prevents double rendering if the tablet is reachable over
/// both USB and Wi-Fi. USB wins by default because it has lower and more
/// stable latency; the user can pin a transport instead.
public struct PeerArbiter: Sendable {
  public struct Peer: Equatable, Sendable {
    public var id: UUID
    public var kind: TransportKind
    public var connectedAt: Date

    public init(id: UUID, kind: TransportKind, connectedAt: Date) {
      self.id = id
      self.kind = kind
      self.connectedAt = connectedAt
    }
  }

  public enum Preference: String, Codable, CaseIterable, Sendable {
    case preferUSB, usbOnly, wifiOnly
  }

  public var preference: Preference
  public private(set) var peers: [Peer] = []
  public private(set) var activeID: UUID?

  public init(preference: Preference = .preferUSB) {
    self.preference = preference
  }

  /// Adds a peer and returns the new active peer ID (which may be unchanged).
  @discardableResult
  public mutating func add(_ peer: Peer) -> UUID? {
    peers.append(peer)
    return reelect()
  }

  @discardableResult
  public mutating func remove(_ id: UUID) -> UUID? {
    peers.removeAll { $0.id == id }
    return reelect()
  }

  public mutating func setPreference(_ p: Preference) -> UUID? {
    preference = p
    return reelect()
  }

  public func isActive(_ id: UUID) -> Bool { activeID == id }

  public var active: Peer? { peers.first { $0.id == activeID } }

  private mutating func reelect() -> UUID? {
    let eligible = peers.filter { peer in
      switch preference {
      case .preferUSB: return true
      case .usbOnly: return peer.kind == .usb
      case .wifiOnly: return peer.kind == .wifi
      }
    }
    // Prefer USB, then the most recent connection: a reconnecting tablet
    // replaces its own stale socket rather than waiting for it to time out.
    activeID =
      eligible.max { a, b in
        if a.kind != b.kind { return a.kind == .wifi }
        return a.connectedAt < b.connectedAt
      }?.id
    return activeID
  }
}
