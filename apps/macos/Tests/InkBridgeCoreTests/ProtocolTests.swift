import XCTest
@testable import InkBridgeCore

final class MessageCodecTests: XCTestCase {
    func testEveryValidFixtureDecodesAndRoundTrips() throws {
        let files = try Fixtures.files("valid")
        XCTAssertEqual(files.count, 22)
        for url in files {
            let data = try Data(contentsOf: url)
            let message = try MessageCodec.decode(data)
            XCTAssertTrue(url.lastPathComponent.hasPrefix(message.payload.type + "."), url.lastPathComponent)
            let reencoded = try MessageCodec.decode(MessageCodec.encode(message))
            XCTAssertEqual(reencoded, message, url.lastPathComponent)
        }
    }

    func testEveryInvalidFixtureIsRejected() throws {
        for url in try Fixtures.files("invalid") {
            XCTAssertThrowsError(try MessageCodec.decode(Data(contentsOf: url)), url.lastPathComponent)
        }
    }

    func testSpecificRejections() throws {
        XCTAssertThrowsError(try MessageCodec.decode(Fixtures.data("invalid/unsupported-version.json"))) {
            XCTAssertEqual($0 as? ProtocolError, .unsupportedVersion(99))
        }
        XCTAssertThrowsError(try MessageCodec.decode(Fixtures.data("invalid/v1-message.json"))) {
            XCTAssertEqual($0 as? ProtocolError, .unsupportedVersion(1), "v1 peers are refused, not misread")
        }
        XCTAssertThrowsError(try MessageCodec.decode(Fixtures.data("invalid/missing-stroke-id.json"))) {
            XCTAssertEqual($0 as? ProtocolError, .missingField("stroke_id"))
        }
        XCTAssertThrowsError(try MessageCodec.decode(Fixtures.data("invalid/coordinate-out-of-range.json"))) {
            XCTAssertEqual($0 as? ProtocolError, .invalidField("point"))
        }
    }

    func testUnknownTypeIsRecoverable() {
        let data = Data(#"{"version":2,"type":"future.thing","sequence":1,"timestamp_ns":1}"#.utf8)
        XCTAssertThrowsError(try MessageCodec.decode(data)) { error in
            XCTAssertEqual(error as? ProtocolError, .unknownType("future.thing"))
            XCTAssertTrue((error as? ProtocolError)?.isRecoverable == true)
        }
    }

    func testBooleanFieldRejectsNumber() {
        let data = Data(#"{"version":2,"type":"auth.challenge","sequence":1,"timestamp_ns":1,"nonce":"00","required":1}"#.utf8)
        XCTAssertThrowsError(try MessageCodec.decode(data))
    }

    func testV2Messages() throws {
        let host = try MessageCodec.decode(Fixtures.data("valid/stroke.begin.host.json"))
        guard case let .strokeBegin(_, tool, point, style) = host.payload else { return XCTFail() }
        XCTAssertEqual(tool, .highlighter)
        XCTAssertEqual(point.x, -1250.5, "canvas coordinates may be negative")
        XCTAssertEqual(style?.width, 22)
        XCTAssertEqual(style?.color.hex, "#ffdb1a59")
        let vp = try MessageCodec.decode(Fixtures.data("valid/canvas.viewport.json"))
        XCTAssertEqual(vp.payload, .canvasViewport(Viewport(x: -2808, y: -936.5, zoom: 0.25)))
        XCTAssertEqual(try MessageCodec.decode(Fixtures.data("valid/doc.remove.json")).payload, .docRemove(strokeIDs: ["s-9f1c-1", "s-9f1c-2"]))
        XCTAssertEqual(try MessageCodec.decode(Fixtures.data("valid/canvas.command.json")).payload, .canvasCommand(.undo))
    }

    func testColorHexRoundTrip() {
        for c in [RGBA.red, .blue, .black, RGBA(1, 0.86, 0.1, 0.35)] {
            let back = RGBA(hex: c.hex)!
            XCTAssertEqual(back.r, c.r, accuracy: 1.0 / 255)
            XCTAssertEqual(back.a, c.a, accuracy: 1.0 / 255)
        }
        XCTAssertNil(RGBA(hex: "red"))
    }

    func testStrokePointDecodesBatch() throws {
        let m = try MessageCodec.decode(Fixtures.data("valid/stroke.point.json"))
        guard case let .strokePoint(id, points) = m.payload else { return XCTFail("wrong payload") }
        XCTAssertEqual(id, "s-9f1c-1")
        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points[1], InkPoint(x: 0.452, y: 0.722, p: 0.82, t: 4990))
        XCTAssertEqual(m.sequence, 5)
    }
}

final class FrameDecoderTests: XCTestCase {
    private func frame(_ s: String) throws -> Data { try FrameCodec.frame(Data(s.utf8)) }

    func testReassemblesFrameSplitAcrossReads() throws {
        let f = try frame(#"{"a":1}"#)
        var d = FrameDecoder()
        for byte in f.dropLast() {
            d.append([byte])
            XCTAssertNil(try d.nextFrame())
        }
        d.append([f.last!])
        XCTAssertEqual(try d.nextFrame(), Data(#"{"a":1}"#.utf8))
        XCTAssertEqual(d.bufferedByteCount, 0)
    }

    func testSplitsMultipleFramesInOneRead() throws {
        var d = FrameDecoder()
        d.append(try frame("one") + frame("two") + frame("three").prefix(5))
        XCTAssertEqual(try d.nextFrame(), Data("one".utf8))
        XCTAssertEqual(try d.nextFrame(), Data("two".utf8))
        XCTAssertNil(try d.nextFrame())
        d.append(try frame("three").dropFirst(5))
        XCTAssertEqual(try d.nextFrame(), Data("three".utf8))
    }

    func testRejectsOversizedHeaderBeforeBuffering() {
        var d = FrameDecoder()
        d.append([0x00, 0x10, 0x00, 0x01])  // 1 MiB + 1
        XCTAssertThrowsError(try d.nextFrame()) { XCTAssertEqual($0 as? ProtocolError, .frameTooLarge(0x100001)) }
    }

    func testRejectsZeroLength() {
        var d = FrameDecoder()
        d.append([0, 0, 0, 0])
        XCTAssertThrowsError(try d.nextFrame()) { XCTAssertEqual($0 as? ProtocolError, .emptyFrame) }
    }

    func testEncoderRefusesOversizedPayload() {
        XCTAssertThrowsError(try FrameCodec.frame(Data(count: FrameCodec.maxPayloadSize + 1)))
    }

    func testCompactionKeepsLongStreamsCorrect() throws {
        var d = FrameDecoder()
        for i in 0..<10_000 {
            d.append(try frame("message-\(i)"))
            XCTAssertEqual(try d.nextFrame(), Data("message-\(i)".utf8))
        }
    }
}

final class PairingAuthTests: XCTestCase {
    func testMatchesSharedVector() throws {
        let v = try JSONSerialization.jsonObject(with: Fixtures.data("auth-vector.json")) as! [String: String]
        let nonce = Data(hex: v["nonce_hex"]!)!
        XCTAssertEqual(PairingAuth.normalize(v["pairing_code"]!), v["normalized_key"])
        XCTAssertEqual(PairingAuth.response(code: v["pairing_code"]!, nonce: nonce), v["expected_response_hex"])
        XCTAssertTrue(PairingAuth.verify(response: v["expected_response_hex"]!, code: "k7qw m3xp", nonce: nonce))
        XCTAssertFalse(PairingAuth.verify(response: v["expected_response_hex"]!, code: "K7QW-M3XQ", nonce: nonce))
        XCTAssertFalse(PairingAuth.verify(response: "zz", code: "K7QW-M3XP", nonce: nonce))
    }

    func testGeneratedCodesAreWellFormed() {
        for _ in 0..<100 {
            let code = PairingAuth.generateCode()
            XCTAssertEqual(code.count, 9)
            XCTAssertEqual(PairingAuth.normalize(code).count, 8)
            XCTAssertFalse(code.contains("0") || code.contains("O") || code.contains("1") || code.contains("I"))
        }
    }
}
