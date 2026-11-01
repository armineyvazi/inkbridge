package app.inkbridge.core.client

import app.inkbridge.core.canvas.Viewport
import app.inkbridge.core.input.StylusEvent
import app.inkbridge.core.protocol.AuthMode
import app.inkbridge.core.protocol.CanvasCommand
import app.inkbridge.core.protocol.Capabilities
import app.inkbridge.core.protocol.DeviceHello
import app.inkbridge.core.protocol.Message
import app.inkbridge.core.protocol.MessageCodec
import app.inkbridge.core.protocol.PairingAuth
import app.inkbridge.core.protocol.Payload
import app.inkbridge.core.protocol.ProtocolException
import app.inkbridge.core.transport.PinMismatchException
import app.inkbridge.core.transport.ReconnectionPolicy
import app.inkbridge.core.transport.Transport
import app.inkbridge.core.transport.TransportKind
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.ReceiveChannel
import kotlinx.coroutines.channels.produce
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull
import java.util.UUID
import java.util.concurrent.atomic.AtomicLong

/** Static facts about this device, sent in device.hello. */
data class DeviceDescriptor(
    val deviceId: String,
    val deviceName: String,
    val model: String,
    val androidApi: Int,
    val capabilities: Capabilities,
)

/** What the client proves to a Mac that asks (Wi-Fi). Evaluated before every attempt. */
sealed interface Credentials {
    /** Not paired: only a Mac that asks for nothing (USB) will accept us. */
    data object None : Credentials

    /**
     * First contact with the code from Connect Device. [pin] is set when the
     * Mac's certificate fingerprint is already known (QR link).
     */
    data class Pair(val code: String, val pin: ByteArray? = null) : Credentials

    /** A paired Mac: its ID, the token it issued, and its pinned certificate. */
    data class Token(val hostId: String, val tokenHex: String, val pin: ByteArray) : Credentials
}

/** The result of a successful pairing; the app stores it. */
data class PairingResult(val hostId: String, val hostName: String, val tokenHex: String, val fingerprint: ByteArray)

/** Why the client stopped retrying. Each needs the user to do something different. */
enum class FailureKind {
    /** The code was wrong. */
    WRONG_CODE,
    /** No Connect Device window is open on the Mac, or its code expired. */
    PAIRING_CLOSED,
    /** The Mac no longer knows this tablet (forgotten, or its data was reset). */
    NOT_PAIRED,
    /** The Mac's certificate differs from the pinned one. Possibly an impostor. */
    IDENTITY_CHANGED,
    /** The Mac answered with something this build cannot work with. */
    PROTOCOL,
}

sealed interface ClientState {
    data object Idle : ClientState
    data class Connecting(val kind: TransportKind, val attempt: Int) : ClientState
    /** Connected; proving the code ([pairing]) or token. */
    data class Authenticating(val kind: TransportKind, val pairing: Boolean) : ClientState
    data class Ready(val kind: TransportKind, val hostName: String, val sessionId: String, val hostId: String = "") : ClientState
    data class Retrying(val kind: TransportKind, val attempt: Int, val delayMs: Long, val reason: String) : ClientState
    /** Will not retry until restarted. */
    data class Failed(val reason: String, val kind: FailureKind = FailureKind.PROTOCOL) : ClientState
}

/**
 * Owns one logical connection to the Mac: handshake, outbound queue,
 * keep-alive, latency measurement and reconnection.
 *
 * Ordering: every outbound message goes through one channel drained by one
 * coroutine, so stroke events reach the socket in submission order and get
 * consecutive sequence numbers. The queue survives reconnects, so events
 * drawn during a brief outage are delivered when the link returns.
 *
 * No loss, no duplicates across reconnects: document messages already
 * written to a link that then died may never have arrived. They stay in
 * [sentLog]; the Mac's `device.ready` says the highest sequence it holds for
 * this stream, and everything after it is sent again (with new sequence
 * numbers, so the Mac's duplicate filter accepts them). Only done when the
 * Mac and its session are the same, so a fresh session never receives
 * strokes from an old one.
 */
class InkBridgeClient(
    private val scope: CoroutineScope,
    private val transportFactory: () -> Transport,
    private val device: DeviceDescriptor,
    private val credentials: () -> Credentials = { Credentials.None },
    private val policy: ReconnectionPolicy = ReconnectionPolicy(),
    private val clock: () -> Long = System::nanoTime,
    private val pingIntervalMs: Long = 2_000,
    private val idleTimeoutMs: Long = 7_000,
    private val handshakeTimeoutMs: Long = 5_000,
    queueCapacity: Int = 4_096,
) {
    val streamId: String = UUID.randomUUID().toString()

    private val _state = MutableStateFlow<ClientState>(ClientState.Idle)
    val state: StateFlow<ClientState> = _state.asStateFlow()

    private val _rttMs = MutableStateFlow<Double?>(null)
    val rttMs: StateFlow<Double?> = _rttMs.asStateFlow()

    /** Events dropped because the outbound queue was full. */
    val droppedEvents = AtomicLong(0)

    /**
     * Host → device document and view messages (stroke.*, stroke.style,
     * doc.*, canvas.viewport). Called on a network thread.
     */
    @Volatile var onHostPayload: ((Payload) -> Unit)? = null

    /** A local stroke's end (or cancel) reached the socket. Called on a network thread. */
    @Volatile var onStrokeSent: ((String) -> Unit)? = null

    /** Pairing succeeded: store the result, then [credentials] should return a Token. */
    @Volatile var onPaired: ((PairingResult) -> Unit)? = null

    /** The Mac rejected our token as unknown: the stored pairing is void. */
    @Volatile var onUnpaired: (() -> Unit)? = null

    /** The certificate fingerprint of the current Wi-Fi link (diagnostics). */
    @Volatile var peerFingerprint: ByteArray? = null
        private set

    /** Messages re-sent after a reconnect (diagnostics). */
    val replayedMessages = AtomicLong(0)

    /** The tablet's current view; re-sent after every (re)connect so the Mac follows. */
    @Volatile var viewport: Viewport = Viewport.HOME
        private set

    private val outbox = Channel<Payload>(queueCapacity)
    private val sendLock = Mutex()
    private var sequence = 0L
    @Volatile private var surface = 1 to 1
    private var job: Job? = null
    private val kick = Channel<Unit>(Channel.CONFLATED)
    @Volatile private var current: Transport? = null

    /** Document messages written but not yet known to have arrived: (sequence, payload). Guarded by [sendLock]. */
    private val sentLog = ArrayDeque<Pair<Long, Payload>>()
    private var lastSession: Pair<String, String>? = null

    fun start() {
        if (job?.isActive == true) return
        job = scope.launch { runLoop() }
    }

    suspend fun stop() {
        job?.let {
            it.cancel()
            it.join()
        }
        job = null
        _state.value = ClientState.Idle
    }

    /**
     * Network changed: skip the current backoff and try again now. With
     * [dropCurrent], also abandon a live link (its network is gone; waiting
     * for the keep-alive timeout would take seconds).
     */
    fun reconnectNow(dropCurrent: Boolean = false) {
        if (dropCurrent) current?.let { t -> scope.launch { t.disconnect() } }
        kick.trySend(Unit)
    }

    /** Thread-safe, non-blocking; call from the UI thread. */
    fun submit(event: StylusEvent) {
        val payload = when (event) {
            is StylusEvent.Begin -> Payload.StrokeBegin(event.strokeId, event.tool, event.point)
            is StylusEvent.Move -> Payload.StrokePoints(event.strokeId, event.points)
            is StylusEvent.End -> Payload.StrokeEnd(event.strokeId)
            is StylusEvent.Cancel -> Payload.StrokeCancel(event.strokeId)
        }
        if (outbox.trySend(payload).isFailure) droppedEvents.incrementAndGet()
    }

    /** Tells the Mac the view moved. Coalescing is up to the caller (send on gesture end / throttled). */
    fun submitViewport(v: Viewport) {
        viewport = v
        if (_state.value is ClientState.Ready && outbox.trySend(Payload.CanvasViewport(v)).isFailure) {
            droppedEvents.incrementAndGet()
        }
    }

    /**
     * Asks the Mac to change the background. [knownRevision] is the last Mac
     * revision this tablet saw; the Mac answers with the applied state.
     */
    fun submitBackground(bg: app.inkbridge.core.canvas.CanvasBackground, knownRevision: Long) {
        if (outbox.trySend(Payload.Background(bg, knownRevision)).isFailure) droppedEvents.incrementAndGet()
    }

    /** Asks the Mac to act on storage (save_now, new_session, switch_project, create_project, use_location). */
    fun submitStorageRequest(action: String, name: String? = null) {
        if (outbox.trySend(Payload.StorageRequest(action, name)).isFailure) droppedEvents.incrementAndGet()
    }

    /** Asks the Mac to undo / redo / clear. The result comes back as document messages. */
    fun submitCommand(c: CanvasCommand) {
        if (outbox.trySend(Payload.Command(c)).isFailure) droppedEvents.incrementAndGet()
    }

    /**
     * Records the drawing surface size (e.g. after rotation). The size goes
     * out in the next device.hello; a live connection also gets a
     * device.surface message so the host can remap immediately.
     */
    fun updateSurface(widthPx: Int, heightPx: Int) {
        if (surface == widthPx to heightPx) return
        surface = widthPx to heightPx
        if (_state.value is ClientState.Ready && outbox.trySend(Payload.Surface(widthPx, heightPx)).isFailure) {
            droppedEvents.incrementAndGet()
        }
    }

    private suspend fun runLoop() {
        var attempt = 0
        while (scope.isActive) {
            attempt++
            val transport = transportFactory()
            current = transport
            _state.value = ClientState.Connecting(transport.kind, attempt)
            val outcome = try {
                session(transport) { attempt = 0 }
                "connection closed"
            } catch (e: CancellationException) {
                withContext(NonCancellable) { transport.disconnect() }
                throw e
            } catch (e: Rejected) {
                withContext(NonCancellable) { transport.disconnect() }
                if (e.kind == FailureKind.NOT_PAIRED) onUnpaired?.invoke()
                _state.value = ClientState.Failed(e.message ?: "rejected", e.kind)
                return
            } catch (e: PinMismatchException) {
                withContext(NonCancellable) { transport.disconnect() }
                _state.value = ClientState.Failed(e.message ?: "certificate changed", FailureKind.IDENTITY_CHANGED)
                return
            } catch (e: Exception) {
                e.message ?: e.javaClass.simpleName
            }
            withContext(NonCancellable) { transport.disconnect() }
            current = null
            _rttMs.value = null
            val wait = policy.delayFor(maxOf(attempt, 1))
            _state.value = ClientState.Retrying(transport.kind, maxOf(attempt, 1), wait, outcome)
            withTimeoutOrNull(wait) { kick.receive() }
        }
    }

    /** The Mac refused us for a reason retrying will not fix. */
    private class Rejected(message: String, val kind: FailureKind) : Exception(message)

    /** Runs one connection until it fails. [onReady] resets the backoff. */
    @OptIn(ExperimentalCoroutinesApi::class) // produce {}
    private suspend fun session(transport: Transport, onReady: () -> Unit) = coroutineScope {
        transport.connect()
        peerFingerprint = transport.peerFingerprint
        val inbox: ReceiveChannel<Message> = produce {
            transport.incomingMessages().collect { bytes ->
                try {
                    send(MessageCodec.decode(bytes))
                } catch (e: ProtocolException) {
                    if (!e.recoverable) throw e
                }
            }
        }
        val ready = handshake(transport, inbox)
        resend(transport, ready)
        // The Mac follows the tablet's view; tell it where we are before any strokes.
        send(transport, Payload.CanvasViewport(viewport))
        _state.value = ClientState.Ready(transport.kind, ready.hostName, ready.sessionId, ready.hostId)
        onReady()

        val lastInbound = AtomicLong(clock())
        val sender = launch { for (p in outbox) send(transport, p) }
        val pinger = launch { keepAlive(transport, lastInbound) }
        try {
            for (m in inbox) {
                lastInbound.set(clock())
                handle(transport, m)
            }
        } finally {
            sender.cancel()
            pinger.cancel()
        }
    }

    /** Re-sends what the previous link lost; see the class comment. */
    private suspend fun resend(transport: Transport, ready: Payload.Ready) {
        val session = ready.hostId to ready.sessionId
        val lost = sendLock.withLock {
            val same = lastSession == session
            lastSession = session
            val pending = if (same) sentLog.filter { it.first > ready.resumeSequence }.map { it.second } else emptyList()
            sentLog.clear()
            pending
        }
        for (p in lost) send(transport, p)
        replayedMessages.addAndGet(lost.size.toLong())
    }

    private suspend fun handshake(transport: Transport, inbox: ReceiveChannel<Message>): Payload.Ready =
        withTimeout(handshakeTimeoutMs) {
            val challenge = inbox.receive().payload as? Payload.AuthChallenge
                ?: throw ProtocolException("expected auth.challenge")
            val fingerprint = transport.peerFingerprint ?: ByteArray(0)
            // The expected auth level comes from our side, never from the host's `required` flag:
            // only the loopback (USB) host may skip authentication. A Wi-Fi host that claims it
            // needs nothing is either broken or an impostor fishing for strokes.
            if (!challenge.required && transport.kind != TransportKind.USB) {
                throw Rejected("this Mac did not ask this tablet to authenticate; refusing to connect", FailureKind.IDENTITY_CHANGED)
            }
            val creds = if (challenge.required) credentials() else Credentials.None
            _state.value = ClientState.Authenticating(transport.kind, creds is Credentials.Pair)
            val (mode, auth) = when (creds) {
                Credentials.None ->
                    if (challenge.required) throw Rejected("pair this tablet with the Mac first", FailureKind.NOT_PAIRED)
                    else null to null
                is Credentials.Pair -> AuthMode.PAIR to PairingAuth.pairProof(creds.code, challenge.nonce, fingerprint)
                is Credentials.Token -> {
                    // An address can be reused by another Mac (DHCP); never offer our token to it.
                    if (challenge.hostId != creds.hostId) throw ProtocolException("reached a different Mac at this address")
                    AuthMode.TOKEN to PairingAuth.tokenProof(creds.tokenHex, challenge.nonce, fingerprint)
                }
            }
            val (w, h) = surface
            send(transport, Payload.Hello(DeviceHello(
                device.deviceId, device.deviceName, device.model, device.androidApi, streamId,
                w, h, device.capabilities, auth, mode,
            )))
            var granted = false
            while (true) {
                when (val reply = inbox.receive().payload) {
                    is Payload.PairGranted -> {
                        val code = (creds as? Credentials.Pair)?.code ?: throw ProtocolException("unexpected pair.granted")
                        // The Mac must prove it saw the code too; otherwise this is an impostor that only relayed.
                        if (!PairingAuth.verifyHost(reply.proof, code, challenge.nonce, fingerprint)) {
                            throw Rejected("the Mac could not prove it showed this code", FailureKind.IDENTITY_CHANGED)
                        }
                        granted = true
                        onPaired?.invoke(PairingResult(reply.hostId, reply.hostName, reply.token, fingerprint))
                    }
                    is Payload.Ready -> {
                        // Pairing is only complete with a verified pair.granted; a host that skips it never proved the code.
                        if (creds is Credentials.Pair && !granted) {
                            throw Rejected("the Mac did not confirm the code", FailureKind.IDENTITY_CHANGED)
                        }
                        return@withTimeout reply
                    }
                    is Payload.Error -> throw rejection(reply, creds)
                    else -> throw ProtocolException("expected device.ready, got ${reply.type}")
                }
            }
            throw IllegalStateException()
        }

    private fun rejection(e: Payload.Error, creds: Credentials): Exception = when (e.code) {
        "auth_failed" ->
            if (creds is Credentials.Token) Rejected("the Mac rejected this tablet's key; pair again", FailureKind.NOT_PAIRED)
            else Rejected("wrong code", FailureKind.WRONG_CODE)
        "pairing_closed" -> Rejected("open Connect Device on the Mac for a new code", FailureKind.PAIRING_CLOSED)
        "not_paired", "auth_required" -> Rejected("this Mac doesn't know this tablet; pair again", FailureKind.NOT_PAIRED)
        else -> ProtocolException("host refused: ${e.code} ${e.message}")
    }

    private val pendingPings = HashMap<Long, Long>()
    private var nextPingId = 1L

    private suspend fun keepAlive(transport: Transport, lastInbound: AtomicLong) {
        while (true) {
            delay(pingIntervalMs)
            if ((clock() - lastInbound.get()) / 1_000_000 > idleTimeoutMs) {
                throw ProtocolException("host silent for ${idleTimeoutMs}ms")
            }
            val id = nextPingId++
            val now = clock()
            synchronized(pendingPings) {
                pendingPings[id] = now
                if (pendingPings.size > 8) pendingPings.remove(pendingPings.keys.min())
            }
            send(transport, Payload.Ping(id), now)
        }
    }

    private suspend fun handle(transport: Transport, m: Message) {
        when (val p = m.payload) {
            is Payload.Ping -> send(transport, Payload.Pong(p.pingId, m.timestampNs))
            is Payload.Pong -> {
                val sent = synchronized(pendingPings) { pendingPings.remove(p.pingId) } ?: return
                _rttMs.value = (clock() - sent) / 1e6
            }
            is Payload.Disconnect -> throw ProtocolException("host disconnected: ${p.reason}")
            is Payload.Error -> if (p.code == "bad_frame" || p.code == "too_many_errors") {
                throw ProtocolException("host error: ${p.code}")
            }
            is Payload.CanvasViewport -> {
                viewport = p.viewport
                onHostPayload?.invoke(p)
            }
            is Payload.StrokeBegin, is Payload.StrokePoints, is Payload.StrokeEnd, is Payload.StrokeStyle,
            is Payload.DocReset, is Payload.DocRemove, is Payload.Background, is Payload.Storage, is Payload.Diagram -> onHostPayload?.invoke(p)
            else -> Unit
        }
    }

    /**
     * Assigns the next sequence number and writes, atomically. The stroke
     * sender, pinger and pong replies run concurrently; if numbering and
     * writing were separate steps, a later number could hit the wire first
     * and the host would discard the earlier message as stale.
     */
    private suspend fun send(transport: Transport, payload: Payload, timestampNs: Long = clock()) {
        sendLock.withLock {
            val seq = ++sequence
            if (isDocument(payload)) {
                sentLog.addLast(seq to payload)
                if (sentLog.size > SENT_LOG_CAPACITY) sentLog.removeFirst()
            }
            transport.send(MessageCodec.encode(Message(seq, timestampNs, payload)))
        }
        when (payload) {
            is Payload.StrokeEnd -> onStrokeSent?.invoke(payload.strokeId)
            is Payload.StrokeCancel -> onStrokeSent?.invoke(payload.strokeId)
            else -> Unit
        }
    }

    private fun isDocument(p: Payload) = p is Payload.StrokeBegin || p is Payload.StrokePoints ||
        p is Payload.StrokeEnd || p is Payload.StrokeCancel || p is Payload.Command || p is Payload.Background

    private companion object {
        /** About a minute of continuous drawing at the BOOX's sample rate. */
        const val SENT_LOG_CAPACITY = 8_192
    }
}
