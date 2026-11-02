import Foundation

/// A tablet this Mac has paired with.
public struct PairedDevice: Codable, Equatable, Sendable, Identifiable {
  public var id: String { deviceID }
  public var deviceID: String
  public var name: String
  public var model: String
  /// Hex of the 256-bit device token. Secret: never logged or shown.
  var token: String
  public var pairedAt: Date
  public var lastSeen: Date?
}

/// The list of paired tablets and their tokens, persisted as JSON (mode 0600).
///
/// Thread-safe: the server reads it on its queue while the UI lists and
/// removes devices on the main thread.
public final class PairedDevices: @unchecked Sendable {
  private let url: URL?
  private let lock = NSLock()
  private var devices: [String: PairedDevice] = [:]

  /// `url` nil keeps the list in memory only (tests, probe).
  public init(url: URL?) {
    self.url = url
    if let url, let data = try? Data(contentsOf: url),
      let list = try? JSONDecoder.iso.decode([PairedDevice].self, from: data)
    {
      devices = Dictionary(list.map { ($0.deviceID, $0) }, uniquingKeysWith: { _, b in b })
    }
  }

  public var all: [PairedDevice] {
    lock.withLock { devices.values.sorted { $0.pairedAt > $1.pairedAt } }
  }

  func token(for deviceID: String) -> Data? {
    lock.withLock { devices[deviceID].flatMap { Data(hex: $0.token) } }
  }

  /// Pairs (or re-pairs) a device and returns its new token. Re-pairing
  /// replaces the old token, so a lost tablet can be cut off by pairing anew.
  func add(deviceID: String, name: String, model: String, now: Date = Date()) -> Data {
    let token = PairingAuth.generateToken()
    lock.withLock {
      devices[deviceID] = PairedDevice(
        deviceID: deviceID, name: name, model: model, token: token.hexString,
        pairedAt: now, lastSeen: now)
      save()
    }
    return token
  }

  func touch(_ deviceID: String, name: String, now: Date = Date()) {
    lock.withLock {
      devices[deviceID]?.lastSeen = now
      devices[deviceID]?.name = name
      save()
    }
  }

  public func remove(_ deviceID: String) {
    lock.withLock {
      devices.removeValue(forKey: deviceID)
      save()
    }
  }

  public func contains(_ deviceID: String) -> Bool {
    lock.withLock { devices[deviceID] != nil }
  }

  /// Caller holds `lock`.
  private func save() {
    guard let url else { return }
    do {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      let data = try JSONEncoder.iso.encode(Array(devices.values))
      try data.write(to: url, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    } catch {
      NSLog("InkBridge: could not save paired devices: \(error.localizedDescription)")
    }
  }
}

/// A Connect Device window's code: short-lived and single-use.
public struct PairingTicket: Equatable, Sendable {
  public var code: String
  public var expiresAt: Date
  /// Wrong codes tried against this ticket. Past `maxFailures` it is void,
  /// which caps online guessing no matter how many addresses an attacker uses.
  var failures = 0
  static let maxFailures = 5

  public init(code: String = PairingAuth.generateCode(), expiresAt: Date) {
    self.code = code
    self.expiresAt = expiresAt
  }

  public func isValid(at now: Date = Date()) -> Bool {
    now < expiresAt && failures < Self.maxFailures
  }
}

extension JSONEncoder {
  static var iso: JSONEncoder {
    let e = JSONEncoder()
    e.dateEncodingStrategy = .iso8601
    e.outputFormatting = [.prettyPrinted, .sortedKeys]
    return e
  }
}

extension JSONDecoder {
  static var iso: JSONDecoder {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .iso8601
    return d
  }
}
