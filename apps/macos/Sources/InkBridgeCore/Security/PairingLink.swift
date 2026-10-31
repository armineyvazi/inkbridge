import Foundation

/// The `inkbridge://pair?…` link shown as a QR code in Connect Device.
///
/// It carries everything a device needs to pair without searching: where
/// the Mac is, the short-lived code, and the certificate fingerprint to pin
/// (so even first contact is not trust-on-first-use). Nothing in it is
/// long-lived: the code expires with the window and works once.
public struct PairingLink: Equatable, Sendable {
    public var hostName: String
    public var hostID: String
    public var addresses: [String]
    public var port: UInt16
    public var code: String
    public var fingerprint: Data
    public var expiresAt: Date

    public init(hostName: String, hostID: String, addresses: [String], port: UInt16, code: String, fingerprint: Data, expiresAt: Date) {
        self.hostName = hostName
        self.hostID = hostID
        self.addresses = addresses
        self.port = port
        self.code = code
        self.fingerprint = fingerprint
        self.expiresAt = expiresAt
    }

    public var url: URL {
        var c = URLComponents()
        c.scheme = "inkbridge"
        c.host = "pair"
        c.queryItems = [
            URLQueryItem(name: "v", value: String(inkProtocolVersion)),
            URLQueryItem(name: "name", value: hostName),
            URLQueryItem(name: "id", value: hostID),
            URLQueryItem(name: "addr", value: addresses.joined(separator: ",")),
            URLQueryItem(name: "port", value: String(port)),
            URLQueryItem(name: "code", value: PairingAuth.normalize(code)),
            URLQueryItem(name: "fp", value: fingerprint.hexString),
            URLQueryItem(name: "exp", value: String(Int(expiresAt.timeIntervalSince1970))),
        ]
        return c.url!
    }

    public init?(url: URL) {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false), c.scheme == "inkbridge", c.host == "pair" else { return nil }
        let q = Dictionary((c.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        guard q["v"] == String(inkProtocolVersion), let name = q["name"], let id = q["id"], let code = q["code"],
              let port = UInt16(q["port"] ?? ""), let fp = Data(hex: q["fp"] ?? ""), fp.count == 32,
              let exp = TimeInterval(q["exp"] ?? "") else { return nil }
        self.init(hostName: name, hostID: id, addresses: (q["addr"] ?? "").split(separator: ",").map(String.init),
                  port: port, code: code, fingerprint: fp, expiresAt: Date(timeIntervalSince1970: exp))
    }
}

/// This Mac's IPv4 addresses on LAN-like interfaces (Wi-Fi, Ethernet),
/// most likely first. Used only to put a fallback address in the QR link;
/// Bonjour is the primary way devices find the Mac.
public enum LocalAddresses {
    public static func ipv4() -> [String] {
        var result: [(String, String)] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  ifa.ifa_flags & UInt32(IFF_UP) != 0, ifa.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            let name = String(cString: ifa.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                result.append((name, String(cString: host)))
            }
        }
        // en0 is the built-in Wi-Fi on laptops; keep it first.
        return result.sorted { ($0.0 == "en0" ? 0 : 1, $0.0) < ($1.0 == "en0" ? 0 : 1, $1.0) }.map(\.1)
    }
}
