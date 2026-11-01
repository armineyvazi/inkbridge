package app.inkbridge.core

import app.inkbridge.core.protocol.FrameDecoder
import app.inkbridge.core.protocol.Framing
import app.inkbridge.core.protocol.InkPoint
import app.inkbridge.core.protocol.Message
import app.inkbridge.core.protocol.MessageCodec
import app.inkbridge.core.protocol.PairingAuth
import app.inkbridge.core.protocol.Payload
import app.inkbridge.core.protocol.ProtocolException
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertFailsWith
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Shared with the Swift suite: both implementations must agree on these bytes. */
object Fixtures {
    val root = File(System.getProperty("inkbridge.fixtures") ?: error("inkbridge.fixtures not set"))
    fun files(dir: String) = File(root, dir).listFiles { f -> f.extension == "json" }!!.sortedBy { it.name }
    fun bytes(path: String) = File(root, path).readBytes()
}

class MessageCodecTest {
    @Test
    fun everyValidFixtureDecodesAndRoundTrips() {
        val files = Fixtures.files("valid")
        assertEquals(26, files.size)
        for (f in files) {
            val m = MessageCodec.decode(f.readBytes())
            assertTrue(f.name.startsWith(m.payload.type + "."), f.name)
            assertEquals(m, MessageCodec.decode(MessageCodec.encode(m)), f.name)
        }
    }

    @Test
    fun everyInvalidFixtureIsRejected() {
        for (f in Fixtures.files("invalid")) {
            assertFailsWith<ProtocolException>(f.name) { MessageCodec.decode(f.readBytes()) }
        }
    }

    @Test
    fun unknownTypeIsRecoverable() {
        val e = assertFailsWith<ProtocolException> {
            MessageCodec.decode("""{"version":3,"type":"future.thing","sequence":1,"timestamp_ns":1}""".encodeToByteArray())
        }
        assertTrue(e.recoverable)
    }

    @Test
    fun booleanFieldRejectsNumber() {
        assertFailsWith<ProtocolException> {
            MessageCodec.decode("""{"version":3,"type":"auth.challenge","sequence":1,"timestamp_ns":1,"nonce":"00","required":1,"host_id":"h"}""".encodeToByteArray())
        }
    }

    @Test
    fun v2Messages() {
        val host = MessageCodec.decode(Fixtures.bytes("valid/stroke.begin.host.json")).payload as Payload.StrokeBegin
        assertEquals(-1250.5, host.point.x)
        assertEquals("#ffdb1a59", app.inkbridge.core.protocol.Colors.toHex(host.style!!.argb))
        assertEquals(22.0, host.style!!.width)
        val vp = MessageCodec.decode(Fixtures.bytes("valid/canvas.viewport.json")).payload as Payload.CanvasViewport
        assertEquals(app.inkbridge.core.canvas.Viewport(-2808.0, -936.5, 0.25), vp.viewport)
        assertEquals(Payload.DocRemove(listOf("s-9f1c-1", "s-9f1c-2")), MessageCodec.decode(Fixtures.bytes("valid/doc.remove.json")).payload)
        assertEquals(Payload.DocReset, MessageCodec.decode(Fixtures.bytes("valid/doc.reset.json")).payload)
        assertFailsWith<ProtocolException>("v1 refused") { MessageCodec.decode(Fixtures.bytes("invalid/v1-message.json")) }
    }

    @Test
    fun colorHexMatchesSwift() {
        // Swift RGBA(0.92, 0.23, 0.20, 1).hex == "#eb3b33ff"
        val argb = app.inkbridge.core.protocol.Colors.fromHex("#eb3b33ff")!!
        assertEquals(0xFFEB3B33.toInt(), argb)
        assertEquals("#eb3b33ff", app.inkbridge.core.protocol.Colors.toHex(argb))
        assertEquals(null, app.inkbridge.core.protocol.Colors.fromHex("red"))
    }

    @Test
    fun strokePointBatch() {
        val m = MessageCodec.decode(Fixtures.bytes("valid/stroke.point.json"))
        val p = m.payload as Payload.StrokePoints
        assertEquals(listOf(InkPoint(0.451, 0.721, 0.81, 4495), InkPoint(0.452, 0.722, 0.82, 4990)), p.points)
        assertEquals(5, m.sequence)
    }

    @Test
    fun encodedFieldsMatchSpecNames() {
        val bytes = MessageCodec.encode(Message(7, 99, Payload.Pong(3, 42)))
        val o = Json.parseToJsonElement(bytes.decodeToString()).jsonObject
        assertEquals(setOf("version", "type", "sequence", "timestamp_ns", "ping_id", "echo_timestamp_ns"), o.keys)
        assertEquals("connection.pong", o["type"]!!.jsonPrimitive.content)
    }
}

class FramingTest {
    private fun frame(s: String) = Framing.frame(s.encodeToByteArray())

    @Test
    fun reassemblesByteByByte() {
        val f = frame("""{"a":1}""")
        val d = FrameDecoder()
        for (i in 0 until f.size - 1) {
            d.append(f, i, 1)
            assertNull(d.next())
        }
        d.append(f, f.size - 1, 1)
        assertEquals("""{"a":1}""", d.next()!!.decodeToString())
        assertEquals(0, d.bufferedBytes)
    }

    @Test
    fun splitsCoalescedFrames() {
        val d = FrameDecoder()
        val three = frame("three")
        d.append(frame("one") + frame("two") + three.copyOfRange(0, 5))
        assertEquals("one", d.next()!!.decodeToString())
        assertEquals("two", d.next()!!.decodeToString())
        assertNull(d.next())
        d.append(three.copyOfRange(5, three.size))
        assertEquals("three", d.next()!!.decodeToString())
    }

    @Test
    fun rejectsOversizedAndEmpty() {
        assertFailsWith<ProtocolException> { FrameDecoder().apply { append(byteArrayOf(0, 0x10, 0, 1)) }.next() }
        assertFailsWith<ProtocolException> { FrameDecoder().apply { append(byteArrayOf(0, 0, 0, 0)) }.next() }
        assertFailsWith<ProtocolException> { FrameDecoder().apply { append(byteArrayOf(-1, -1, -1, -1)) }.next() }
        assertFailsWith<ProtocolException> { Framing.frame(ByteArray(Framing.MAX_PAYLOAD_SIZE + 1)) }
    }

    @Test
    fun growsBufferForLargeFrames() {
        val big = "x".repeat(60_000)
        val d = FrameDecoder()
        repeat(3) { d.append(frame(big)) }
        repeat(3) { assertEquals(big, d.next()!!.decodeToString()) }
    }

    @Test
    fun swiftFramesDecode() {
        // Big-endian length header, as written by FrameCodec.swift.
        val payload = Fixtures.bytes("valid/stroke.end.json").decodeToString().trim().encodeToByteArray()
        val d = FrameDecoder()
        d.append(byteArrayOf(0, 0, (payload.size shr 8).toByte(), payload.size.toByte()) + payload)
        assertEquals("stroke.end", MessageCodec.decode(d.next()!!).payload.type)
    }
}

class PairingAuthTest {
    @Test
    fun matchesSharedVector() {
        val v = Json.parseToJsonElement(Fixtures.bytes("auth-vector.json").decodeToString()).jsonObject
        fun s(k: String) = v[k]!!.jsonPrimitive.content
        val fp = PairingAuth.hexToBytes(s("fingerprint_hex"))
        assertEquals(s("normalized_key"), PairingAuth.normalize(s("pairing_code")))
        assertEquals(s("pair_proof_hex"), PairingAuth.pairProof("k7qw m3xp", s("nonce_hex"), fp))
        assertEquals(s("host_proof_hex"), PairingAuth.hostProof(s("pairing_code"), s("nonce_hex"), fp))
        assertEquals(s("token_proof_hex"), PairingAuth.tokenProof(s("token_hex"), s("nonce_hex"), fp))
        assertTrue(PairingAuth.verifyHost(s("host_proof_hex"), s("pairing_code"), s("nonce_hex"), fp))
        assertFalse(PairingAuth.verifyHost(s("host_proof_hex"), "K7QW-M3XQ", s("nonce_hex"), fp))
        assertFalse(PairingAuth.verifyHost(s("host_proof_hex"), s("pairing_code"), s("nonce_hex"), ByteArray(32)),
            "bound to the certificate fingerprint")
    }
}
