import Foundation

/// Length-prefixed framing: a 4-byte big-endian payload length followed by
/// that many bytes of UTF-8 JSON.
///
/// TCP is a byte stream, so one `receive` can hold half a message or several.
/// A length prefix lets the reader know exactly where each message ends
/// without scanning for delimiters, and lets it reject oversized frames
/// before buffering them.
public enum FrameCodec {
    public static let headerSize = 4
    public static let maxPayloadSize = 64 * 1024

    public static func frame(_ payload: Data) throws -> Data {
        guard !payload.isEmpty else { throw ProtocolError.emptyFrame }
        guard payload.count <= maxPayloadSize else { throw ProtocolError.frameTooLarge(payload.count) }
        var out = Data(capacity: headerSize + payload.count)
        let n = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: n) { out.append(contentsOf: $0) }
        out.append(payload)
        return out
    }

    /// Encodes and frames a message in one step.
    public static func frame(_ message: Message) throws -> Data {
        try frame(MessageCodec.encode(message))
    }
}

/// Reassembles frames from arbitrary chunks of a byte stream.
///
/// Not thread-safe; feed it from the connection's serial queue.
public struct FrameDecoder {
    private var buffer: [UInt8] = []
    private var head = 0

    public init() {}

    /// Bytes received but not yet returned as a frame.
    public var bufferedByteCount: Int { buffer.count - head }

    public mutating func append<D: DataProtocol>(_ chunk: D) {
        buffer.append(contentsOf: chunk)
    }

    /// Returns the next complete frame payload, or nil if more bytes are needed.
    ///
    /// Throws on an invalid length header; the stream cannot be resynchronised
    /// after that, so the caller must close the connection.
    public mutating func nextFrame() throws -> Data? {
        guard bufferedByteCount >= FrameCodec.headerSize else { return nil }
        let length = Int(buffer[head]) << 24 | Int(buffer[head + 1]) << 16
            | Int(buffer[head + 2]) << 8 | Int(buffer[head + 3])
        guard length > 0 else { throw ProtocolError.emptyFrame }
        guard length <= FrameCodec.maxPayloadSize else { throw ProtocolError.frameTooLarge(length) }
        guard bufferedByteCount >= FrameCodec.headerSize + length else { return nil }

        let start = head + FrameCodec.headerSize
        let frame = Data(buffer[start..<start + length])
        head = start + length
        compactIfNeeded()
        return frame
    }

    // Dropping consumed bytes on every frame would make each read O(n);
    // compacting only once the dead prefix dominates keeps it amortised O(1).
    private mutating func compactIfNeeded() {
        if head == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            head = 0
        } else if head > 4096 && head > buffer.count / 2 {
            buffer.removeSubrange(0..<head)
            head = 0
        }
    }
}
