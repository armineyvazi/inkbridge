import CryptoKit
import Foundation

/// Proofs exchanged in the LAN handshake (protocol v3).
///
/// Every proof is `HMAC-SHA256(key, label ‖ 0x00 ‖ nonce ‖ fingerprint)`:
///
/// - `nonce` is the 32 random bytes from this connection's `auth.challenge`,
///   so a captured proof cannot be replayed on another connection.
/// - `fingerprint` is the SHA-256 of the Mac's TLS certificate *as the device
///   saw it*. A man in the middle has to present its own certificate, so the
///   device would prove over the wrong fingerprint and the Mac rejects it.
///   (Empty on the loopback/USB listener, which has no TLS and no auth.)
/// - `label` separates the three uses, so no proof can stand in for another.
///
/// Keys: the short-lived pairing code for first contact (device proves
/// `pair`, the Mac answers with `host`, so both sides know the other saw the
/// code); afterwards the 256-bit token the Mac issued in `pair.granted`.
/// Mirrors PairingAuth.kt; both are checked against
/// protocol/fixtures/auth-vector.json. See docs/architecture/security.md.
public enum PairingAuth {
    /// Alphabet without look-alike characters (no 0/O, 1/I/L).
    static let alphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")

    public static let pairLabel = "inkbridge-v3-pair"
    public static let hostLabel = "inkbridge-v3-host"
    public static let tokenLabel = "inkbridge-v3-token"

    /// A new random code formatted as `XXXX-XXXX` (~40 bits of entropy).
    public static func generateCode() -> String {
        var rng = SystemRandomNumberGenerator()
        let chars = (0..<8).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &rng)] }
        return String(chars[0..<4]) + "-" + String(chars[4..<8])
    }

    /// Uppercases and strips separators so `k7qw m3xp` matches `K7QW-M3XP`.
    public static func normalize(_ code: String) -> String {
        code.uppercased().filter { $0.isLetter || $0.isNumber }
    }

    public static func generateNonce() -> Data { randomBytes(32) }

    /// A new device token (256 bits).
    public static func generateToken() -> Data { randomBytes(32) }

    static func randomBytes(_ n: Int) -> Data {
        Data(SymmetricKey(size: SymmetricKeySize(bitCount: n * 8)).withUnsafeBytes { Array($0) })
    }

    // MARK: Proofs

    public static func pairProof(code: String, nonce: Data, fingerprint: Data) -> String {
        proof(key: codeKey(code), label: pairLabel, nonce: nonce, fingerprint: fingerprint)
    }

    public static func hostProof(code: String, nonce: Data, fingerprint: Data) -> String {
        proof(key: codeKey(code), label: hostLabel, nonce: nonce, fingerprint: fingerprint)
    }

    public static func tokenProof(token: Data, nonce: Data, fingerprint: Data) -> String {
        proof(key: SymmetricKey(data: token), label: tokenLabel, nonce: nonce, fingerprint: fingerprint)
    }

    /// Constant-time check of a device's `.pair` proof.
    public static func verifyPair(_ hex: String, code: String, nonce: Data, fingerprint: Data) -> Bool {
        verify(hex, key: codeKey(code), label: pairLabel, nonce: nonce, fingerprint: fingerprint)
    }

    /// Constant-time check of a device's `.token` proof.
    public static func verifyToken(_ hex: String, token: Data, nonce: Data, fingerprint: Data) -> Bool {
        verify(hex, key: SymmetricKey(data: token), label: tokenLabel, nonce: nonce, fingerprint: fingerprint)
    }

    private static func codeKey(_ code: String) -> SymmetricKey {
        SymmetricKey(data: Data(normalize(code).utf8))
    }

    private static func message(_ label: String, _ nonce: Data, _ fingerprint: Data) -> Data {
        Data(label.utf8) + Data([0]) + nonce + fingerprint
    }

    private static func proof(key: SymmetricKey, label: String, nonce: Data, fingerprint: Data) -> String {
        HMAC<SHA256>.authenticationCode(for: message(label, nonce, fingerprint), using: key).hexString
    }

    private static func verify(_ hex: String, key: SymmetricKey, label: String, nonce: Data, fingerprint: Data) -> Bool {
        guard let mac = Data(hex: hex) else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: message(label, nonce, fingerprint), using: key)
    }
}

extension Sequence where Element == UInt8 {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

extension Data {
    public var hexString: String { [UInt8](self).hexString }

    public init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        var it = hex.makeIterator()
        while let hi = it.next(), let lo = it.next() {
            guard let b = UInt8(String([hi, lo]), radix: 16) else { return nil }
            bytes.append(b)
        }
        self.init(bytes)
    }
}
