package app.inkbridge.core.client

import app.inkbridge.core.input.StylusEvent
import app.inkbridge.core.protocol.Capabilities
import app.inkbridge.core.protocol.DeviceHello
import app.inkbridge.core.protocol.Message
import app.inkbridge.core.protocol.MessageCodec
import app.inkbridge.core.protocol.PairingAuth
import app.inkbridge.core.protocol.Payload
import app.inkbridge.core.protocol.ProtocolException
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

sealed interface ClientState {
    data object Idle : ClientState
    data class Connecting(val kind: TransportKind, val attempt: Int) : ClientState
    data class Ready(val kind: TransportKind, val hostName: String, val sessionId: String) : ClientState
    data class Retrying(val kind: TransportKind, val attempt: Int, val delayMs: Long, val reason: String) : ClientState
    /** Will not retry until restarted, e.g. the pairing code was rejected. */
    data class Failed(val reason: String) : ClientState
}

/**
 * Owns one logical connection to the Mac: handshake, outbound queue,
 * keep-alive, latency measurement and reconnection.
 *
 * Ordering: every outbound message goes through one channel drained by one
 * coroutine, so stroke events reach the socket in submission order and get
 * consecutive sequence numbers. The queue survives reconnects, so events
 * drawn during a brief outage are delivered when the link returns.
 */
class InkBridgeClient(
    private val scope: CoroutineScope,
    private val transportFactory: () -> Transport,
    private val device: DeviceDescriptor,
    private val pairingCode: String?,
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

    private val outbox = Channel<Payload>(queueCapacity)
    private val sendLock = Mutex()
    private var sequence = 0L
    @Volatile private var surface = 1 to 1
    private var job: Job? = null

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
            _state.value = ClientState.Connecting(transport.kind, attempt)
            val outcome = try {
                session(transport) { attempt = 0 }
                "connection closed"
            } catch (e: CancellationException) {
                withContext(NonCancellable) { transport.disconnect() }
                throw e
            } catch (e: AuthRejected) {
                withContext(NonCancellable) { transport.disconnect() }
                _state.value = ClientState.Failed(e.message ?: "pairing rejected")
                return
            } catch (e: Exception) {
                e.message ?: e.javaClass.simpleName
            }
            withContext(NonCancellable) { transport.disconnect() }
            _rttMs.value = null
            val wait = policy.delayFor(maxOf(attempt, 1))
            _state.value = ClientState.Retrying(transport.kind, maxOf(attempt, 1), wait, outcome)
            delay(wait)
        }
    }

    private class AuthRejected(message: String) : Exception(message)

    /** Runs one connection until it fails. [onReady] resets the backoff. */
    @OptIn(ExperimentalCoroutinesApi::class) // produce {}
    private suspend fun session(transport: Transport, onReady: () -> Unit) = coroutineScope {
        transport.connect()
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
        _state.value = ClientState.Ready(transport.kind, ready.hostName, ready.sessionId)
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

    private suspend fun handshake(transport: Transport, inbox: ReceiveChannel<Message>): Payload.Ready =
        withTimeout(handshakeTimeoutMs) {
            val challenge = inbox.receive().payload as? Payload.AuthChallenge
                ?: throw ProtocolException("expected auth.challenge")
            val auth = when {
                !challenge.required -> null
                pairingCode.isNullOrBlank() -> throw AuthRejected("this Mac requires a pairing code")
                else -> PairingAuth.response(pairingCode, challenge.nonce)
            }
            val (w, h) = surface
            send(transport, Payload.Hello(DeviceHello(
                device.deviceId, device.deviceName, device.model, device.androidApi, streamId,
                w, h, device.capabilities, auth,
            )))
            when (val reply = inbox.receive().payload) {
                is Payload.Ready -> reply
                is Payload.Error ->
                    if (reply.code == "auth_failed") throw AuthRejected("pairing code rejected by the Mac")
                    else throw ProtocolException("host refused: ${reply.code} ${reply.message}")
                else -> throw ProtocolException("expected device.ready, got ${reply.type}")
            }
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
            transport.send(MessageCodec.encode(Message(++sequence, timestampNs, payload)))
        }
    }
}
