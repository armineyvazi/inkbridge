import XCTest
@testable import InkBridgeCore

final class AuthThrottleTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testLockoutIsPerHost() {
        var t = AuthThrottle()
        for i in 0..<5 { t.recordFailure(host: "10.0.0.66", at: t0.addingTimeInterval(Double(i))) }
        XCTAssertTrue(t.isLockedOut(host: "10.0.0.66", at: t0.addingTimeInterval(6)))
        // Regression: an attacker's failures used to lock out everyone on the LAN.
        XCTAssertFalse(t.isLockedOut(host: "10.0.0.20", at: t0.addingTimeInterval(6)))
    }

    func testLockoutExpiresAndEscalates() {
        var t = AuthThrottle()
        for _ in 0..<5 { t.recordFailure(host: "h", at: t0) }
        XCTAssertTrue(t.isLockedOut(host: "h", at: t0.addingTimeInterval(29)))
        XCTAssertFalse(t.isLockedOut(host: "h", at: t0.addingTimeInterval(31)))
        let t1 = t0.addingTimeInterval(100)
        for _ in 0..<5 { t.recordFailure(host: "h", at: t1) }
        XCTAssertTrue(t.isLockedOut(host: "h", at: t1.addingTimeInterval(59)), "second lockout is doubled")
        XCTAssertFalse(t.isLockedOut(host: "h", at: t1.addingTimeInterval(61)))
    }

    func testSuccessResetsHost() {
        var t = AuthThrottle()
        for _ in 0..<4 { t.recordFailure(host: "h", at: t0) }
        t.recordSuccess(host: "h")
        t.recordFailure(host: "h", at: t0)
        XCTAssertFalse(t.isLockedOut(host: "h", at: t0))
    }

    func testGlobalBrakeAgainstManyHosts() {
        var t = AuthThrottle()
        for i in 0..<50 { t.recordFailure(host: "h\(i)", at: t0) }
        XCTAssertTrue(t.isLockedOut(host: "fresh", at: t0.addingTimeInterval(1)))
        XCTAssertFalse(t.isLockedOut(host: "fresh", at: t0.addingTimeInterval(61)))
    }
}
