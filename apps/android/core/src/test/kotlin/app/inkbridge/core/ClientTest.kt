package app.inkbridge.core

import app.inkbridge.core.client.ClientState
import app.inkbridge.core.client.DeviceDescriptor
import app.inkbridge.core.client.InkBridgeClient
import app.inkbridge.core.input.StylusEvent
import app.inkbridge.core.protocol.Capabilities
import app.inkbridge.core.protocol.FrameDecoder
import app.inkbridge.core.protocol.Framing
import app.inkbridge.core.protocol.InkPoint
import app.inkbridge.core.protocol.Message
import app.inkbridge.core.protocol.MessageCodec
import app.inkbridge.core.protocol.PairingAuth
import app.inkbridge.core.protocol.Payload
import app.inkbridge.core.protocol.Tool
import app.inkbridge.core.transport.ReconnectionPolicy
import app.inkbridge.core.transport.TcpTransport
import app.inkbridge.core.transport.TransportKind
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import java.io.DataInputStream
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/**
 * A scripted host on a real loopback socket. It implements just enough of
 * the Mac side (challenge, hello check, ready, ping/pong) to exercise the
 * client and TcpTransport together.
 */
private class FakeHost(private val code: String?) : AutoCloseable {
    val server = ServerSocket(0)
    val port get() = server.localPort
    val received = LinkedBlockingQueue<Message>()
    @Volatile var current: Socket? = null
    private var seq = 0L

    init {
        thread(isDaemon = true) {
            while (!server.isClosed) {
                val s = try { server.accept() } catch (_: Exception) { break }
                current = s
                thread(isDaemon = true) { serve(s) }
            }
        }
    }

    private fun write(s: Socket, p: Payload) = synchronized(this) {
        s.getOutputStream().write(Framing.frame(Message(++seq, System.nanoTime(), p)))
        s.getOutputStream().flush()
    }

    private fun serve(s: Socket) {
        val nonce = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"
        try {
            write(s, Payload.AuthChallenge(nonce, required = code != null))
            val input = DataInputStream(s.getInputStream())
            val decoder = FrameDecoder()
            val buf = ByteArray(4096)
            while (true) {
                val n = input.read(buf)
                if (n < 0) return
                decoder.append(buf, 0, n)
                while (true) {
                    val m = MessageCodec.decode(decoder.next() ?: break)
                    received.put(m)
                    when (val p = m.payload) {
                        is Payload.Hello ->
                            if (code == null || p.hello.auth == PairingAuth.response(code, nonce)) write(s, Payload.Ready("Fake Mac", "session-1"))
                            else write(s, Payload.Error("auth_failed", "pairing code mismatch"))
                        is Payload.Ping -> write(s, Payload.Pong(p.pingId, m.timestampNs))
                        else -> Unit
                    }
                }
            }
        } catch (_: Exception) {
        }
    }

    fun next(): Message = assertNotNull(received.poll(3, TimeUnit.SECONDS), "host received nothing")

    fun dropConnection() = current?.close()

    fun push(p: Payload) = current?.let { write(it, p) }

    override fun close() = server.close()
}

class InkBridgeClientTest {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val device = DeviceDescriptor("dev-1", "Test BOOX", "NoteAir3", 31, Capabilities(true, false, false, false))

    @AfterTest
    fun tearDown() = scope.cancel()

    private fun client(host: FakeHost, code: String? = null, pingMs: Long = 2_000) = InkBridgeClient(
        scope, { TcpTransport("127.0.0.1", host.port, TransportKind.USB) }, device, code,
        policy = ReconnectionPolicy(initialMs = 50, maxMs = 200), pingIntervalMs = pingMs,
    )

    private fun awaitState(c: InkBridgeClient, pred: (ClientState) -> Boolean) = runBlocking {
        withTimeout(5_000) { c.state.first(pred) }
    }

    @Test
    fun handshakeThenOrderedStrokes() {
        FakeHost(code = null).use { host ->
            val c = client(host)
            c.updateSurface(1404, 1872)
            c.start()
            val hello = assertIs<Payload.Hello>(host.next().payload).hello
            assertEquals(1404, hello.surfaceWidthPx)
            assertEquals(null, hello.auth)
            awaitState(c) { it is ClientState.Ready }
            assertIs<Payload.CanvasViewport>(host.next().payload, "the tablet's view is sent right after the handshake")

            val pt = InkPoint(0.5, 0.5, 0.5, 1)
            c.submit(StylusEvent.Begin("s1", Tool.PEN, pt))
            repeat(100) { c.submit(StylusEvent.Move("s1", listOf(pt.copy(t = it.toLong())))) }
            c.submit(StylusEvent.End("s1"))
            val msgs = List(102) { host.next() }
            assertIs<Payload.StrokeBegin>(msgs.first().payload)
            assertIs<Payload.StrokeEnd>(msgs.last().payload)
            val seqs = msgs.map { it.sequence }
            assertEquals(seqs.sorted(), seqs, "sequence numbers must be increasing in arrival order")
            assertEquals(seqs.toSet().size, seqs.size)
            runBlocking { c.stop() }
        }
    }

    @Test
    fun pairingCodeAuthenticates() {
        FakeHost(code = "K7QW-M3XP").use { host ->
            val c = client(host, code = "k7qw m3xp")
            c.start()
            assertNotNull(assertIs<Payload.Hello>(host.next().payload).hello.auth)
            awaitState(c) { it is ClientState.Ready }
            runBlocking { c.stop() }
        }
    }

    @Test
    fun wrongCodeFailsWithoutRetryLoop() {
        FakeHost(code = "K7QW-M3XP").use { host ->
            val c = client(host, code = "AAAA-AAAA")
            c.start()
            val s = awaitState(c) { it is ClientState.Failed }
            assertTrue((s as ClientState.Failed).reason.contains("pairing"))
            Thread.sleep(300)
            assertEquals(1, host.received.size, "must not hammer the host with retries")
        }
    }

    @Test
    fun reconnectsAndDeliversQueuedEventsAfterDrop() {
        FakeHost(code = null).use { host ->
            val c = client(host)
            c.start()
            host.next() // hello
            awaitState(c) { it is ClientState.Ready }
            host.next() // viewport
            host.dropConnection()
            awaitState(c) { it !is ClientState.Ready }
            val started = System.nanoTime()
            // Drawn while disconnected: queued, not lost.
            c.submit(StylusEvent.End("during-outage"))
            awaitState(c) { it is ClientState.Ready }
            val reconnectMs = (System.nanoTime() - started) / 1e6
            val after = generateSequence { host.received.poll(3, TimeUnit.SECONDS) }.take(3).toList()
            assertIs<Payload.Hello>(after[0].payload)
            assertIs<Payload.CanvasViewport>(after[1].payload)
            assertEquals(Payload.StrokeEnd("during-outage"), after[2].payload)
            assertTrue(reconnectMs < 3_000, "reconnected in $reconnectMs ms")
            runBlocking { c.stop() }
        }
    }

    @Test
    fun hostDocumentMessagesReachTheMirrorAndSentStrokesAreReported() {
        FakeHost(code = null).use { host ->
            val c = client(host)
            val got = java.util.concurrent.LinkedBlockingQueue<Payload>()
            val sent = java.util.concurrent.LinkedBlockingQueue<String>()
            c.onHostPayload = { got.put(it) }
            c.onStrokeSent = { sent.put(it) }
            c.start()
            awaitState(c) { it is ClientState.Ready }
            host.push(Payload.DocRemove(listOf("x")))
            host.push(Payload.CanvasViewport(app.inkbridge.core.canvas.Viewport(1.0, 2.0, 0.5)))
            assertEquals(Payload.DocRemove(listOf("x")), got.poll(3, TimeUnit.SECONDS))
            assertIs<Payload.CanvasViewport>(got.poll(3, TimeUnit.SECONDS))
            assertEquals(app.inkbridge.core.canvas.Viewport(1.0, 2.0, 0.5), c.viewport, "host view adopted")
            c.submit(StylusEvent.Begin("s9", Tool.PEN, InkPoint(0.0, 0.0, 1.0, 0)))
            c.submit(StylusEvent.End("s9"))
            assertEquals("s9", sent.poll(3, TimeUnit.SECONDS))
            runBlocking { c.stop() }
        }
    }

    @Test
    fun answersHostPingsAndMeasuresRtt() {
        FakeHost(code = null).use { host ->
            val c = client(host, pingMs = 100)
            c.start()
            awaitState(c) { it is ClientState.Ready }
            val rtt = runBlocking { withTimeout(3_000) { c.rttMs.first { it != null } } }
            assertTrue(rtt!! >= 0 && rtt < 1_000)
            runBlocking { c.stop() }
        }
    }

    @Test
    fun connectionRefusedRetries() {
        val port = ServerSocket(0).use { it.localPort } // closed: nothing listens
        val c = InkBridgeClient(scope, { TcpTransport("127.0.0.1", port, TransportKind.WIFI) }, device, null,
            policy = ReconnectionPolicy(initialMs = 20, maxMs = 50))
        c.start()
        val s = awaitState(c) { it is ClientState.Retrying && it.attempt >= 3 }
        assertIs<ClientState.Retrying>(s)
        runBlocking { c.stop() }
    }
}
