import CryptoKit
import Foundation
import Security

// SecIdentityCreate is not always in the public SDK headers (older Xcode on
// GitHub Actions). The symbol exists in Security.framework on macOS 13+.
@_silgen_name("SecIdentityCreate")
private func inkSecIdentityCreate(
  _ allocator: CFAllocator?,
  _ certificate: SecCertificate,
  _ privateKey: SecKey
) -> SecIdentity?

/// The Mac's long-lived TLS identity: a P-256 key and a self-signed
/// certificate, plus a random host ID.
///
/// There is no certificate authority on a home LAN, so trust is by pinning:
/// a device records the certificate's SHA-256 fingerprint when it pairs and
/// refuses any other certificate afterwards. The handshake proofs also cover
/// the fingerprint (PairingAuth), which is what stops a man in the middle
/// during first contact.
///
/// Stored as files with mode 0600 in `directory` rather than the keychain:
/// the app is ad-hoc signed, and the login keychain would ask the user for
/// permission again after every rebuild. Anyone who can read the user's
/// Application Support folder can impersonate this Mac to paired tablets;
/// docs/architecture/security.md lists this.
public final class HostIdentity: @unchecked Sendable {
  public let hostID: String
  public let certificateDER: Data
  /// SHA-256 of `certificateDER`.
  public let fingerprint: Data
  public let secIdentity: SecIdentity

  public enum IdentityError: Error {
    case certificate
    case key(String)
    case identity
  }

  /// Loads the identity from `directory`, creating it on first use.
  public static func loadOrCreate(in directory: URL, commonName: String = "InkBridge") throws
    -> HostIdentity
  {
    let fm = FileManager.default
    try fm.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let keyURL = directory.appendingPathComponent("host-key.raw")
    let certURL = directory.appendingPathComponent("host-cert.der")
    let idURL = directory.appendingPathComponent("host-id")

    let hostID: String
    if let saved = try? String(contentsOf: idURL, encoding: .utf8), !saved.isEmpty {
      hostID = saved.trimmingCharacters(in: .whitespacesAndNewlines)
    } else {
      hostID = UUID().uuidString.lowercased()
      try writePrivate(Data(hostID.utf8), to: idURL)
    }

    if let raw = try? Data(contentsOf: keyURL), let cert = try? Data(contentsOf: certURL),
      let key = try? P256.Signing.PrivateKey(rawRepresentation: raw),
      let identity = try? HostIdentity(hostID: hostID, key: key, certificateDER: cert)
    {
      return identity
    }
    let key = P256.Signing.PrivateKey()
    let cert = try SelfSignedCertificate.make(
      key: key, commonName: "\(commonName) \(hostID.prefix(8))")
    try writePrivate(key.rawRepresentation, to: keyURL)
    try writePrivate(cert, to: certURL)
    return try HostIdentity(hostID: hostID, key: key, certificateDER: cert)
  }

  init(hostID: String, key: P256.Signing.PrivateKey, certificateDER: Data) throws {
    guard let cert = SecCertificateCreateWithData(nil, certificateDER as CFData) else {
      throw IdentityError.certificate
    }
    var error: Unmanaged<CFError>?
    let attributes: [CFString: Any] = [
      kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
      kSecAttrKeyClass: kSecAttrKeyClassPrivate,
      kSecAttrKeySizeInBits: 256,
    ]
    guard
      let secKey = SecKeyCreateWithData(
        key.x963Representation as CFData, attributes as CFDictionary, &error)
    else {
      throw IdentityError.key(error.map { "\($0.takeRetainedValue())" } ?? "unknown")
    }
    // Returns nil when the key does not match the certificate (e.g. a stale cert file).
    guard let identity = inkSecIdentityCreate(nil, cert, secKey) else { throw IdentityError.identity }
    self.hostID = hostID
    self.certificateDER = certificateDER
    self.fingerprint = Data(SHA256.hash(data: certificateDER))
    self.secIdentity = identity
  }

  /// `AB:CD:…` grouping of the first bytes, for showing to people.
  public var shortFingerprint: String {
    fingerprint.prefix(8).map { String(format: "%02X", $0) }.joined(separator: ":")
  }

  private static func writePrivate(_ data: Data, to url: URL) throws {
    try data.write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
}

/// Builds a minimal X.509 v3 certificate (no extensions) signed by its own key.
///
/// Security.framework can parse certificates but not create them, and a
/// one-certificate builder is far smaller than a dependency. Devices never
/// validate a chain; they compare the fingerprint, so only well-formed DER
/// matters.
enum SelfSignedCertificate {
  static let ecdsaWithSHA256: [UInt8] = [
    0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02,
  ]
  static let ecPublicKey: [UInt8] = [0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01]
  static let prime256v1: [UInt8] = [0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07]
  static let commonNameOID: [UInt8] = [0x06, 0x03, 0x55, 0x04, 0x03]

  static func make(
    key: P256.Signing.PrivateKey, commonName: String, now: Date = Date(), years: Int = 20
  ) throws -> Data {
    var serial = [UInt8](PairingAuth.randomBytes(16))
    serial[0] &= 0x7F  // positive INTEGER
    serial[0] |= 0x01  // and no leading zero byte to strip
    let name = DER.sequence([DER.set([DER.sequence([commonNameOID, DER.utf8String(commonName)])])])
    let notAfter =
      Calendar(identifier: .gregorian).date(byAdding: .year, value: years, to: now) ?? now
    let algorithm = DER.sequence([ecdsaWithSHA256])
    let spki = DER.sequence([
      DER.sequence([ecPublicKey, prime256v1]),
      DER.bitString(Array(key.publicKey.x963Representation)),
    ])
    let tbs = DER.sequence([
      DER.contextExplicit(0, DER.integer([2])),
      DER.integer(serial),
      algorithm,
      name,
      DER.sequence([DER.time(now.addingTimeInterval(-86_400)), DER.time(notAfter)]),
      name,
      spki,
    ])
    let signature = try key.signature(for: Data(tbs)).derRepresentation
    return Data(DER.sequence([tbs, algorithm, DER.bitString(Array(signature))]))
  }
}

/// Just enough ASN.1 DER encoding for one certificate.
enum DER {
  static func tlv(_ tag: UInt8, _ body: [UInt8]) -> [UInt8] {
    [tag] + length(body.count) + body
  }

  static func length(_ n: Int) -> [UInt8] {
    if n < 0x80 { return [UInt8(n)] }
    var bytes: [UInt8] = []
    var v = n
    while v > 0 {
      bytes.insert(UInt8(v & 0xFF), at: 0)
      v >>= 8
    }
    return [0x80 | UInt8(bytes.count)] + bytes
  }

  static func sequence(_ items: [[UInt8]]) -> [UInt8] { tlv(0x30, items.flatMap { $0 }) }
  static func set(_ items: [[UInt8]]) -> [UInt8] { tlv(0x31, items.flatMap { $0 }) }
  static func integer(_ bytes: [UInt8]) -> [UInt8] { tlv(0x02, bytes) }
  static func bitString(_ bytes: [UInt8]) -> [UInt8] { tlv(0x03, [0] + bytes) }
  static func utf8String(_ s: String) -> [UInt8] { tlv(0x0C, Array(s.utf8)) }
  static func contextExplicit(_ n: UInt8, _ body: [UInt8]) -> [UInt8] { tlv(0xA0 | n, body) }

  /// UTCTime before 2050, GeneralizedTime from 2050 on (RFC 5280 §4.1.2.5).
  static func time(_ date: Date) -> [UInt8] {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    let year =
      Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: date)
      .year ?? 2000
    if year < 2050 {
      f.dateFormat = "yyMMddHHmmss'Z'"
      return tlv(0x17, Array(f.string(from: date).utf8))
    }
    f.dateFormat = "yyyyMMddHHmmss'Z'"
    return tlv(0x18, Array(f.string(from: date).utf8))
  }
}
