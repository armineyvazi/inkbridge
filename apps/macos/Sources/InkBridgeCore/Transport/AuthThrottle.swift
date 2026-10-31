import Foundation

/// Rate-limits failed LAN pairing attempts.
///
/// Failures are tracked **per remote host**, so one misbehaving machine on
/// the network cannot lock out the user's own tablet. A much higher global
/// limit is a secondary brake against many hosts guessing at once. Each
/// lockout for a host doubles in length, up to `maxLockout`.
///
/// This slows online guessing; it does not stop *offline* guessing of a
/// code from a captured challenge/response. That needs TLS or a PAKE
/// (see docs/architecture/security.md).
public struct AuthThrottle: Sendable {
    public var window: TimeInterval = 60
    public var perHostLimit = 5
    public var globalLimit = 50
    public var baseLockout: TimeInterval = 30
    public var maxLockout: TimeInterval = 15 * 60

    private var failures: [String: [Date]] = [:]
    private var lockedUntil: [String: Date] = [:]
    private var strikes: [String: Int] = [:]
    private var global: [Date] = []

    public init() {}

    public mutating func recordFailure(host: String, at now: Date = Date()) {
        prune(now)
        failures[host, default: []].append(now)
        global.append(now)
        if failures[host]!.count >= perHostLimit {
            let n = strikes[host, default: 0]
            strikes[host] = n + 1
            lockedUntil[host] = now.addingTimeInterval(min(baseLockout * pow(2, Double(n)), maxLockout))
            failures[host] = []
        }
    }

    /// Clears a host's history after it authenticates successfully.
    public mutating func recordSuccess(host: String) {
        failures[host] = nil
        lockedUntil[host] = nil
        strikes[host] = nil
    }

    public mutating func isLockedOut(host: String, at now: Date = Date()) -> Bool {
        prune(now)
        if let until = lockedUntil[host], until > now { return true }
        return global.count >= globalLimit
    }

    private mutating func prune(_ now: Date) {
        let cutoff = now.addingTimeInterval(-window)
        global.removeAll { $0 < cutoff }
        for (h, list) in failures { failures[h] = list.filter { $0 >= cutoff } }
        lockedUntil = lockedUntil.filter { $0.value > now }
    }
}
