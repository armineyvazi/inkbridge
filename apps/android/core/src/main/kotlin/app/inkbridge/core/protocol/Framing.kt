package app.inkbridge.core.protocol

/**
 * Length-prefixed framing: 4-byte big-endian length, then that many bytes of
 * UTF-8 JSON. A TCP read can return part of a frame or several frames;
 * [FrameDecoder] reassembles them.
 */
object Framing {
    const val HEADER_SIZE = 4
    const val MAX_PAYLOAD_SIZE = 64 * 1024

    fun frame(payload: ByteArray): ByteArray {
        if (payload.isEmpty()) throw ProtocolException("empty frame")
        if (payload.size > MAX_PAYLOAD_SIZE) throw ProtocolException("frame of ${payload.size} bytes exceeds limit")
        val out = ByteArray(HEADER_SIZE + payload.size)
        val n = payload.size
        out[0] = (n ushr 24).toByte()
        out[1] = (n ushr 16).toByte()
        out[2] = (n ushr 8).toByte()
        out[3] = n.toByte()
        payload.copyInto(out, HEADER_SIZE)
        return out
    }

    fun frame(message: Message): ByteArray = frame(MessageCodec.encode(message))
}

/** Reassembles frames from stream chunks. Not thread-safe. */
class FrameDecoder {
    private var buf = ByteArray(8 * 1024)
    private var start = 0
    private var end = 0

    val bufferedBytes: Int get() = end - start

    fun append(chunk: ByteArray, offset: Int = 0, length: Int = chunk.size) {
        ensureCapacity(length)
        chunk.copyInto(buf, end, offset, offset + length)
        end += length
    }

    /**
     * Next complete payload, or null if more bytes are needed. Throws on an
     * invalid header, after which the stream is unrecoverable.
     */
    fun next(): ByteArray? {
        if (bufferedBytes < Framing.HEADER_SIZE) return null
        val n = (buf[start].toInt() and 0xFF shl 24) or (buf[start + 1].toInt() and 0xFF shl 16) or
            (buf[start + 2].toInt() and 0xFF shl 8) or (buf[start + 3].toInt() and 0xFF)
        if (n <= 0) throw ProtocolException(if (n == 0) "empty frame" else "frame length overflow")
        if (n > Framing.MAX_PAYLOAD_SIZE) throw ProtocolException("frame of $n bytes exceeds limit")
        if (bufferedBytes < Framing.HEADER_SIZE + n) return null
        val from = start + Framing.HEADER_SIZE
        val payload = buf.copyOfRange(from, from + n)
        start = from + n
        if (start == end) {
            start = 0
            end = 0
        }
        return payload
    }

    private fun ensureCapacity(extra: Int) {
        if (end + extra <= buf.size) return
        // Slide unread bytes to the front first; grow only if that is not enough.
        val live = bufferedBytes
        val target = if (live + extra <= buf.size) buf else ByteArray(maxOf(buf.size * 2, live + extra))
        buf.copyInto(target, 0, start, end)
        buf = target
        start = 0
        end = live
    }
}
