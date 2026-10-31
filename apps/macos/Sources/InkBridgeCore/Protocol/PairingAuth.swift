import CryptoKit
import Foundation

/// Challenge-response authentication for LAN connections.
///
/// The host shows a short pairing code; the user types it on the tablet.
/// On connect the host sends a random nonce, and the device answers with
/// HMAC-SHA256(key: normalized code, message: nonce). The code itself never
/// crosses the network, and a captured response cannot be replayed because
/// every connection gets a fresh nonce.
///
/// This authenticates the device; it does not encrypt the stroke stream.
/// See docs/architecture/security.md for the threat model and the TLS plan.
public enum PairingAuth {
    /// Alphabet without look-alike characters (no 0/O, 1/I/L).
    static let alphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")

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

    public static func generateNonce() -> Data {
        Data(SymmetricKey(size: .bits256).withUnsafeBytes { Array($0) })
    }

    public static func response(code: String, nonce: Data) -> String {
        let key = SymmetricKey(data: Data(normalize(code).utf8))
        return HMAC<SHA256>.authenticationCode(for: nonce, using: key).hexString
    }

    /// Constant-time verification of a device's response.
    public static func verify(response hex: String, code: String, nonce: Data) -> Bool {
        guard let mac = Data(hex: hex) else { return false }
        let key = SymmetricKey(data: Data(normalize(code).utf8))
        return HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: nonce, using: key)
    }
}

extension Sequence where Element == UInt8 {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

extension Data {
    init?(hex: String) {
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
