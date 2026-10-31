package app.inkbridge.core

import app.inkbridge.core.client.ClientState
import app.inkbridge.core.client.Credentials
import app.inkbridge.core.client.DeviceDescriptor
import app.inkbridge.core.client.FailureKind
import app.inkbridge.core.client.InkBridgeClient
import app.inkbridge.core.client.PairingResult
import app.inkbridge.core.protocol.AuthMode
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
 * the Mac side (challenge, pair/token proofs, pair.granted, ready with
 * resume_sequence, ping/pong) to exercise the client and TcpTransport
 * together. Plain TCP, so proofs use an empty fingerprint, as over USB.
 */
private class FakeHost(
    private val code: String?,
    private val required: Boolean = code != null,
    val hostId: String = "fake-host",
    @Volatile var session: String = "session-1",
    /** Answers pair.granted with a wrong proof, like an impostor that does not know the code. */
    private val forgeHostProof: Boolean = false,
) : AutoCloseable {
    val server = ServerSocket(0)
    val port get() = server.localPort
    val received = LinkedBlockingQueue<Message>()
    @Volatile var current: Socket? = null
    /** While set, messages are read but dropped, like a link dying with data in flight. */
    @Volatile var blackhole = false
    val tokens = java.util.concurrent.ConcurrentHashMap<String, String>()
    private val highWater = java.util.concurrent.ConcurrentHashMap<String, Long>()
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
        val nonce = PairingAuth.randomHex(32)
        val none = ByteArray(0)
        var stream = ""
        try {
            write(s, Payload.AuthChallenge(nonce, required, hostId))
            val input = DataInputStream(s.getInputStream())
            val decoder = FrameDecoder()
            val buf = ByteArray(4096)
            while (true) {
                val n = input.read(buf)
                if (n < 0) return
                decoder.append(buf, 0, n)
                while (true) {
                    val m = MessageCodec.decode(decoder.next() ?: break)
                    if (blackhole) continue
                    if (m.payload is Payload.Hello) stream = (m.payload as Payload.Hello).hello.streamId
                    val resume = highWater[stream] ?: 0
                    highWater[stream] = maxOf(resume, m.sequence)
                    received.put(m)
                    when (val p = m.payload) {
                        is Payload.Hello -> hello(s, p.hello, nonce, none, resume)
                        is Payload.Ping -> write(s, Payload.Pong(p.pingId, m.timestampNs))
                        else -> Unit
                    }
                }
            }
        } catch (_: Exception) {
        }
    }

    private fun hello(s: Socket, h: app.inkbridge.core.protocol.DeviceHello, nonce: String, fp: ByteArray, resume: Long) {
        if (required) {
            when (h.authMode) {
                AuthMode.PAIR -> {
                    if (code == null || h.auth != PairingAuth.pairProof(code, nonce, fp)) return write(s, Payload.Error("auth_failed", "wrong pairing code"))
                    val token = PairingAuth.randomHex(32)
                    tokens[h.deviceId] = token
                    val proof = if (forgeHostProof) PairingAuth.randomHex(32) else PairingAuth.hostProof(code, nonce, fp)
                    write(s, Payload.PairGranted(hostId, "Fake Mac", token, proof))
                }
                AuthMode.TOKEN -> {
                    val token = tokens[h.deviceId] ?: return write(s, Payload.Error("not_paired", "unknown device"))
                    if (h.auth != PairingAuth.tokenProof(token, nonce, fp)) return write(s, Payload.Error("auth_failed", "bad token"))
                }
                null -> return write(s, Payload.Error("auth_required", "pair first"))
            }
        }
        write(s, Payload.Ready("Fake Mac", session, hostId, resume))
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

    private fun client(
        host: FakeHost,
        code: String? = null,
        pingMs: Long = 2_000,
        policy: ReconnectionPolicy = ReconnectionPolicy(initialMs = 50, maxMs = 200),
        credentials: (() -> Credentials)? = null,
    ) = InkBridgeClient(
        scope, { TcpTransport("127.0.0.1", host.port, TransportKind.USB) }, device,
        credentials ?: { code?.let { Credentials.Pair(it) } ?: Credentials.None },
        policy = policy, pingIntervalMs = pingMs,
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
    fun pairingIssuesTokenAndLaterConnectionsUseIt() {
        FakeHost(code = "K7QW-M3XP").use { host ->
            var stored: PairingResult? = null
            val c = client(host, credentials = {
                stored?.let { Credentials.Token(it.hostId, it.tokenHex, it.fingerprint) } ?: Credentials.Pair("k7qw m3xp")
            })
            c.onPaired = { stored = it }
            c.start()
            assertEquals(AuthMode.PAIR, assertIs<Payload.Hello>(host.next().payload).hello.authMode)
            awaitState(c) { it is ClientState.Ready }
            assertEquals("fake-host", stored?.hostId)
            assertEquals(host.tokens["dev-1"], stored?.tokenHex)

            host.dropConnection()
            awaitState(c) { it !is ClientState.Ready }
            val again = generateSequence { host.received.poll(3, TimeUnit.SECONDS) }.first { it.payload is Payload.Hello }
            assertEquals(AuthMode.TOKEN, (again.payload as Payload.Hello).hello.authMode, "no code needed after pairing")
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
            assertEquals(FailureKind.WRONG_CODE, (s as ClientState.Failed).kind)
            Thread.sleep(300)
            assertEquals(1, host.received.size, "must not hammer the host with retries")
        }
    }

    @Test
    fun forgottenTabletIsToldToPairAgain() {
        FakeHost(code = "K7QW-M3XP").use { host ->
            var unpaired = false
            val c = client(host, credentials = { Credentials.Token("fake-host", "ab".repeat(32), ByteArray(0)) })
            c.onUnpaired = { unpaired = true }
            c.start()
            val s = awaitState(c) { it is ClientState.Failed }
            assertEquals(FailureKind.NOT_PAIRED, (s as ClientState.Failed).kind)
            assertTrue(unpaired, "the stored pairing must be dropped")
        }
    }

    @Test
    fun tokenIsNeverOfferedToADifferentMac() {
        FakeHost(code = "K7QW-M3XP", hostId = "someone-else").use { host ->
            val c = client(host, credentials = { Credentials.Token("fake-host", "ab".repeat(32), ByteArray(0)) })
            c.start()
            val s = awaitState(c) { it is ClientState.Retrying }
            assertTrue((s as ClientState.Retrying).reason.contains("different Mac"))
            Thread.sleep(100)
            assertTrue(host.received.none { it.payload is Payload.Hello }, "no proof may reach the wrong Mac")
            runBlocking { c.stop() }
        }
    }

    @Test
    fun impostorWithoutTheCodeIsDetected() {
        FakeHost(code = "K7QW-M3XP", forgeHostProof = true).use { host ->
            var paired = false
            val c = client(host, code = "K7QW-M3XP")
            c.onPaired = { paired = true }
            c.start()
            val s = awaitState(c) { it is ClientState.Failed }
            assertEquals(FailureKind.IDENTITY_CHANGED, (s as ClientState.Failed).kind)
            assertTrue(!paired, "a token from an unproven Mac must not be stored")
        }
    }

    @Test
    fun messagesLostWithADeadLinkAreResentExactlyOnce() {
        FakeHost(code = null).use { host ->
            val c = client(host)
            c.start()
            awaitState(c) { it is ClientState.Ready }
            host.next(); host.next() // hello, viewport
            val pt = InkPoint(1.0, 1.0, 0.5, 1)
            c.submit(StylusEvent.Begin("s1", Tool.PEN, pt))
            assertIs<Payload.StrokeBegin>(host.next().payload)
            // The link dies with these in flight: written by the tablet, never processed by the Mac.
            host.blackhole = true
            repeat(5) { c.submit(StylusEvent.Move("s1", listOf(pt.copy(x = it.toDouble())))) }
            Thread.sleep(200)
            host.blackhole = false
            host.dropConnection()
            awaitState(c) { it !is ClientState.Ready }
            c.submit(StylusEvent.End("s1"))
            awaitState(c) { it is ClientState.Ready }
            val after = generateSequence { host.received.poll(2, TimeUnit.SECONDS) }.toList()
            val strokeMsgs = after.map { it.payload }.filter { it is Payload.StrokePoints || it is Payload.StrokeEnd }
            assertEquals((0 until 5).map { it.toDouble() }, strokeMsgs.filterIsInstance<Payload.StrokePoints>().map { it.points[0].x },
                "every lost point arrives once, in order")
            assertEquals(Payload.StrokeEnd("s1"), strokeMsgs.last())
            assertEquals(5L, c.replayedMessages.get())
            val seqs = after.map { it.sequence }
            assertEquals(seqs.sorted(), seqs)
            runBlocking { c.stop() }
        }
    }

    @Test
    fun nothingIsResentIntoADifferentSession() {
        FakeHost(code = null).use { host ->
            val c = client(host)
            c.start()
            awaitState(c) { it is ClientState.Ready }
            host.blackhole = true
            c.submit(StylusEvent.End("old"))
            Thread.sleep(200)
            host.blackhole = false
            host.session = "session-2"  // the Mac restarted with a new session
            host.dropConnection()
            awaitState(c) { it !is ClientState.Ready }
            awaitState(c) { it is ClientState.Ready }
            val after = generateSequence { host.received.poll(1, TimeUnit.SECONDS) }.toList()
            assertTrue(after.none { it.payload == Payload.StrokeEnd("old") })
            runBlocking { c.stop() }
        }
    }

    @Test
    fun reconnectNowSkipsTheBackoff() {
        FakeHost(code = null).use { host ->
            val c = client(host, policy = ReconnectionPolicy(initialMs = 10_000, maxMs = 10_000, jitter = 0.0))
            c.start()
            awaitState(c) { it is ClientState.Ready }
            host.dropConnection()
            awaitState(c) { it is ClientState.Retrying }
            val t0 = System.nanoTime()
            c.reconnectNow()
            awaitState(c) { it is ClientState.Ready }
            val ms = (System.nanoTime() - t0) / 1e6
            assertTrue(ms < 2_000, "network-change kick reconnected in $ms ms instead of waiting 10 s")
            runBlocking { c.stop() }
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
        val c = InkBridgeClient(scope, { TcpTransport("127.0.0.1", port, TransportKind.WIFI) }, device,
            policy = ReconnectionPolicy(initialMs = 20, maxMs = 50))
        c.start()
        val s = awaitState(c) { it is ClientState.Retrying && it.attempt >= 3 }
        assertIs<ClientState.Retrying>(s)
        runBlocking { c.stop() }
    }
}
