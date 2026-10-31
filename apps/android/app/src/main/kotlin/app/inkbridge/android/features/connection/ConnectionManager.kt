package app.inkbridge.android.features.connection

import android.content.Context
import android.os.Build
import android.provider.Settings
import android.util.Log
import app.inkbridge.android.core.NetworkMonitor
import app.inkbridge.android.features.settings.AppSettings
import app.inkbridge.android.input.StylusCapabilityProbe
import app.inkbridge.core.canvas.CanvasDocument
import app.inkbridge.core.client.ClientState
import app.inkbridge.core.client.Credentials
import app.inkbridge.core.client.DeviceDescriptor
import app.inkbridge.core.client.InkBridgeClient
import app.inkbridge.core.client.PairingResult
import app.inkbridge.core.connection.ConnectionFacts
import app.inkbridge.core.connection.ConnectionMode
import app.inkbridge.core.connection.ConnectionStatus
import app.inkbridge.core.connection.StatusView
import app.inkbridge.core.protocol.PairingAuth
import app.inkbridge.core.transport.AdbReverseTransport
import app.inkbridge.core.transport.TlsTransport
import app.inkbridge.core.transport.Transport
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.launch

/** A pairing attempt the user started: where to, and with which code. */
data class PairingRequest(val name: String, val address: String, val port: Int, val code: String, val pin: ByteArray? = null)

/**
 * The connection layer for the whole app, independent of any screen.
 *
 * Owns the single [InkBridgeClient] (one stream ID for the app process, so
 * lost messages can be re-sent after any reconnect), the canvas document
 * mirror, discovery and network monitoring. Screens observe [status] and
 * call the verbs; none of them touch sockets.
 *
 * Runs while any InkBridge screen is visible ([foreground]) and stops a few
 * seconds after the last one goes away (screen off, home button), so a
 * sleeping tablet does not keep Wi-Fi busy. Waking it reconnects.
 */
class ConnectionManager(private val ctx: Context) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    val document = CanvasDocument()
    private val pairingStore = PairingStore(ctx)
    val discovery = BonjourDiscovery(ctx)

    @Volatile var settings: AppSettings = AppSettings.load(ctx)
        private set

    private val _paired = MutableStateFlow(pairingStore.load())
    val paired: StateFlow<PairedMac?> = _paired.asStateFlow()

    private val _pairing = MutableStateFlow<PairingRequest?>(null)
    val pairing: StateFlow<PairingRequest?> = _pairing.asStateFlow()

    private val _mode = MutableStateFlow(settings.mode)

    private val _paused = MutableStateFlow(false)
    /** The user pressed Disconnect; nothing reconnects until they press Connect. */
    val paused: StateFlow<Boolean> = _paused.asStateFlow()
    private var wasConnected = false
    @Volatile var lastAddress: String? = null
        private set

    val network = NetworkMonitor(ctx,
        onAvailable = { Log.i(TAG, "network: wifi available"); scope.launch { if (settings.mode == ConnectionMode.WIFI && running) { discovery.restart(); client.reconnectNow() } } },
        onLost = { Log.i(TAG, "network: wifi lost"); scope.launch { if (settings.mode == ConnectionMode.WIFI) client.reconnectNow(dropCurrent = true) } },
    )

    val client = InkBridgeClient(
        scope = scope,
        transportFactory = ::makeTransport,
        device = descriptor(),
        credentials = ::credentials,
    )

    /** The worded connection state for every screen. */
    val status: StateFlow<StatusView> = combine(
        client.state, client.rttMs, _paired, _pairing, combine(discovery.macs, _mode, _paused) { m, mode, paused -> Triple(m, mode, paused) },
    ) { st, rtt, paired, pairing, (macs, mode, paused) ->
        if (st is ClientState.Ready) wasConnected = true
        ConnectionStatus.describe(ConnectionFacts(mode, paired?.name, pairing != null, macs.size, st, rtt, wasConnected, paused))
    }.stateIn(scope, SharingStarted.Eagerly, ConnectionStatus.describe(
        ConnectionFacts(settings.mode, _paired.value?.name, false, 0, null, null, false, false)))

    init {
        client.onPaired = { r -> scope.launch { onPaired(r) } }
        // Keep the client's Failed(NOT_PAIRED) state so the screen says why; only drop the stale secret.
        client.onUnpaired = { scope.launch { pairingStore.clear(); _paired.value = null } }
        scope.launch {
            client.state.collect { st ->
                // States only: never codes, tokens or stroke content.
                Log.i(TAG, "state: " + when (st) {
                    is ClientState.Retrying -> "retrying ${st.delayMs}ms (${st.reason})"
                    is ClientState.Ready -> "ready ${st.kind}"
                    else -> st.javaClass.simpleName.lowercase()
                })
                if (st is ClientState.Ready) {
                    _paired.value?.takeIf { settings.mode == ConnectionMode.WIFI }?.let {
                        val updated = it.copy(lastConnectedAt = System.currentTimeMillis(), lastAddress = lastAddress ?: it.lastAddress)
                        pairingStore.save(updated)
                        _paired.value = updated
                    }
                }
                if (st is ClientState.Failed) _pairing.value = null
                // "Reconnect automatically" off: a dropped link stays down until the user asks.
                if (st is ClientState.Retrying && wasConnected && !settings.autoReconnect) disconnect()
            }
        }
        // A paired Mac that moved to a new IP is recognised by its TXT id.
        scope.launch {
            discovery.macs.collect { macs ->
                val p = _paired.value ?: return@collect
                val hit = macs.firstOrNull { it.hostId == p.hostId } ?: return@collect
                if (hit.address != p.lastAddress || hit.port != p.lastPort) {
                    val updated = p.copy(lastAddress = hit.address, lastPort = hit.port)
                    pairingStore.save(updated)
                    _paired.value = updated
                    client.reconnectNow()
                }
            }
        }
    }

    // MARK: Lifecycle

    private var visible = 0
    private var stopJob: Job? = null
    @Volatile private var running = false

    /** Called by every screen's onStart/onStop. */
    fun foreground(visibleNow: Boolean) {
        visible += if (visibleNow) 1 else -1
        if (visible > 0) {
            stopJob?.cancel()
            if (!running) startAll()
        } else {
            stopJob = scope.launch {
                delay(4_000) // survive screen-to-screen navigation without dropping
                stopAll()
            }
        }
    }

    private fun startAll() {
        running = true
        network.start()
        if (settings.mode == ConnectionMode.WIFI && settings.discovery) discovery.start()
        if (shouldConnect()) client.start()
    }

    private suspend fun stopAll() {
        running = false
        discovery.stop()
        network.stop()
        client.stop()
    }

    private fun shouldConnect() = when (settings.mode) {
        ConnectionMode.USB -> true
        ConnectionMode.WIFI -> _paired.value != null || _pairing.value != null
    } && !paused.value


    fun disconnect() {
        _paused.value = true
        scope.launch { client.stop() }
    }

    fun resume() {
        _paused.value = false
        restart()
    }

    // MARK: Verbs

    /** Starts pairing with a Mac from the list, the manual form or a QR link. */
    fun pair(request: PairingRequest) {
        Log.i(TAG, "pairing with ${request.name} at ${request.address}:${request.port}")  // never the code
        _paused.value = false
        _pairing.value = request
        if (settings.mode != ConnectionMode.WIFI) update(settings.copy(mode = ConnectionMode.WIFI))
        restart()
    }

    fun cancelPairing() {
        _pairing.value = null
        if (_paired.value == null) scope.launch { client.stop() }
    }

    private fun onPaired(r: PairingResult) {
        val req = _pairing.value
        val mac = PairedMac(
            r.hostId, r.hostName, PairingAuth.toHex(r.fingerprint), r.tokenHex,
            req?.address ?: lastAddress.orEmpty(), req?.port ?: settings.manualPort,
            System.currentTimeMillis(), System.currentTimeMillis(),
        )
        pairingStore.save(mac)
        _paired.value = mac
        _pairing.value = null
        Log.i(TAG, "paired with ${mac.name}, certificate ${mac.shortFingerprint}")
    }

    /** Removes this tablet's pairing. The Mac keeps its record until someone presses Forget there. */
    fun forgetMac() {
        pairingStore.clear()
        _paired.value = null
        _pairing.value = null
        wasConnected = false
        scope.launch { client.stop() }
    }

    /** Reconnect from scratch (Retry button). */
    fun restart() {
        scope.launch {
            client.stop()
            if (running && shouldConnect()) client.start()
        }
    }

    fun update(s: AppSettings) {
        val old = settings
        settings = s
        s.save(ctx)
        _mode.value = s.mode
        if (old.mode != s.mode || old.usbPort != s.usbPort || old.discovery != s.discovery) {
            if (s.mode == ConnectionMode.WIFI && s.discovery && running) discovery.start() else discovery.stop()
            restart()
        }
    }

    fun saveViewport(v: app.inkbridge.core.canvas.Viewport) {
        settings = settings.copy(lastViewport = v)
        settings.save(ctx)
    }

    // MARK: Client plumbing

    private fun credentials(): Credentials {
        _pairing.value?.let { return Credentials.Pair(it.code, it.pin) }
        return _paired.value?.credentials ?: Credentials.None
    }

    private fun makeTransport(): Transport {
        val s = settings
        if (s.mode == ConnectionMode.USB) {
            lastAddress = "127.0.0.1 (adb reverse)"
            return AdbReverseTransport(s.usbPort)
        }
        val req = _pairing.value
        val p = _paired.value
        val (host, port, pin) = when {
            req != null -> Triple(req.address, req.port, req.pin)
            p != null -> {
                // Prefer what discovery sees now; fall back to the last address that worked.
                val seen = discovery.macs.value.firstOrNull { it.hostId == p.hostId }
                Triple(seen?.address ?: p.lastAddress.ifBlank { s.manualHost }, seen?.port ?: p.lastPort.takeIf { it > 0 } ?: s.manualPort,
                    PairingAuth.hexToBytes(p.fingerprintHex))
            }
            else -> Triple(s.manualHost, s.manualPort, null)
        }
        lastAddress = host
        return TlsTransport(host, port, pin)
    }

    private fun descriptor() = DeviceDescriptor(
        deviceId = AppSettings.deviceId(ctx),
        deviceName = (Settings.Global.getString(ctx.contentResolver, Settings.Global.DEVICE_NAME)
            ?: "${Build.MANUFACTURER} ${Build.MODEL}").take(64),
        model = Build.MODEL.take(64),
        androidApi = Build.VERSION.SDK_INT,
        capabilities = StylusCapabilityProbe.capabilities(),
    )

    companion object {
        const val TAG = "InkBridge"
    }
}
