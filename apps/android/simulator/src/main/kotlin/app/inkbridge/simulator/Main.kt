package app.inkbridge.simulator

import app.inkbridge.core.client.ClientState
import app.inkbridge.core.client.Credentials
import app.inkbridge.core.client.DeviceDescriptor
import app.inkbridge.core.client.InkBridgeClient
import app.inkbridge.core.client.PairingResult
import app.inkbridge.core.input.PointerAction
import app.inkbridge.core.input.RawSample
import app.inkbridge.core.input.StrokeProcessor
import app.inkbridge.core.input.ToolKind
import app.inkbridge.core.protocol.Capabilities
import app.inkbridge.core.transport.AdbReverseTransport
import app.inkbridge.core.transport.DEFAULT_USB_PORT
import app.inkbridge.core.transport.DEFAULT_WIFI_PORT
import app.inkbridge.core.transport.TlsTransport
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin
import kotlin.system.exitProcess

/**
 * A virtual tablet: drives the same StrokeProcessor and InkBridgeClient as
 * the Android app with synthetic pen input at the Note Air 3's surface size.
 *
 *   simulator [--wifi HOST] [--port N] [--code XXXX-XXXX] [--strokes N] [--hz 200] [--reconnect] [--set-background black|white|overlay]
 *
 * Without --wifi it connects to 127.0.0.1:8765, i.e. exactly where the
 * tablet's traffic lands through `adb reverse`. With --wifi it connects over
 * TLS, pairs with --code, and pins the certificate it saw; --reconnect then
 * drops the link halfway (as a Wi-Fi blip would) and must come back with
 * the device token, not the code.
 */
fun main(args: Array<String>): Unit = runBlocking(Dispatchers.Default) {
    val opts = args.toList().windowed(2, 1, partialWindows = true).associate { it[0] to it.getOrNull(1) }
    val wifiHost = opts["--wifi"]
    val port = opts["--port"]?.toInt() ?: if (wifiHost != null) DEFAULT_WIFI_PORT else DEFAULT_USB_PORT
    val strokes = opts["--strokes"]?.toInt() ?: 5
    val hz = opts["--hz"]?.toInt() ?: 200
    val width = 1404
    val height = 1872

    val reconnect = "--reconnect" in opts
    var pairing: PairingResult? = null
    val client = InkBridgeClient(
        scope = this,
        transportFactory = { if (wifiHost != null) TlsTransport(wifiHost, port, pin = pairing?.fingerprint) else AdbReverseTransport(port) },
        device = DeviceDescriptor("simulator", "InkBridge Simulator", "JVM", 0, Capabilities(true, false, false, false)),
        credentials = {
            pairing?.let { Credentials.Token(it.hostId, it.tokenHex, it.fingerprint) }
                ?: opts["--code"]?.let { Credentials.Pair(it) } ?: Credentials.None
        },
        pingIntervalMs = 500,
    )
    val doc = app.inkbridge.core.canvas.CanvasDocument()
    client.onHostPayload = { p ->
        doc.applyHost(p)
        if (p is app.inkbridge.core.protocol.Payload.Storage) {
            val st = p.state
            println("storage from host: project=${st.project} session=${st.session} status=${st.status} location=${st.location} projects=${st.projects} revision=${st.revision}${st.error?.let { " error=$it" } ?: ""}")
        }
        if (p is app.inkbridge.core.protocol.Payload.Background) {
            println("background from host: ${p.background.mode.wire} ${app.inkbridge.core.protocol.Colors.toHex(p.background.argb)} ${p.background.pattern.wire} revision ${p.revision}")
        }
    }
    client.onPaired = {
        pairing = it
        println("paired with ${it.hostName}; pinned certificate ${it.fingerprint.take(8).joinToString(":") { b -> "%02X".format(b) }}")
    }
    client.updateSurface(width, height)
    client.start()
    val ready = try {
        withTimeout(10_000) { client.state.first { it is ClientState.Ready || it is ClientState.Failed } }
    } catch (e: Exception) {
        println("could not connect: ${client.state.value}")
        exitProcess(1)
    }
    if (ready is ClientState.Failed) {
        println("failed: ${ready.reason}")
        exitProcess(1)
    }
    println("connected: $ready")
    opts["--storage-request"]?.let { spec ->
        val (action, name) = spec.split(":", limit = 2).let { it[0] to it.getOrNull(1) }
        delay(500)
        client.submitStorageRequest(action, name)
        println("storage requested: $action ${name ?: ""}")
        delay(1_500)
    }
    opts["--set-background"]?.let { spec ->
        val bg = when (spec) {
            "black" -> app.inkbridge.core.canvas.CanvasBackground.studio(app.inkbridge.core.canvas.CanvasBackground.BLACK)
            "white" -> app.inkbridge.core.canvas.CanvasBackground.studio(app.inkbridge.core.canvas.CanvasBackground.WHITE)
            else -> app.inkbridge.core.canvas.CanvasBackground.OVERLAY
        }
        delay(300)
        client.submitBackground(bg, doc.backgroundRevision)
        println("background requested: $spec")
    }

    val processor = StrokeProcessor(streamTag = client.streamId.take(8))
    val periodMs = 1000L / hz
    repeat(strokes) { i ->
        val cx = width * (0.2f + 0.6f * ((i % 3) / 2f))
        val cy = height * (0.2f + 0.6f * ((i / 3 % 3) / 2f))
        val samples = 120
        for (k in 0..samples) {
            val a = 2 * PI * k / samples
            val r = 120f * (1 + 0.3f * sin(3 * a).toFloat())
            val sample = RawSample(cx + r * cos(a).toFloat(), cy + r * sin(a).toFloat(), (0.4 + 0.5 * sin(a)).toFloat().coerceIn(0f, 1f), System.nanoTime())
            val action = when (k) {
                0 -> PointerAction.DOWN
                samples -> PointerAction.UP
                else -> PointerAction.MOVE
            }
            processor.process(action, ToolKind.STYLUS, false, listOf(sample)).forEach(client::submit)
            delay(periodMs)
        }
        println("drew stroke ${i + 1}/$strokes, rtt=${client.rttMs.value?.let { "%.2f ms".format(it) } ?: "n/a"}")
        if (reconnect && i == strokes / 2) {
            val t0 = System.nanoTime()
            client.reconnectNow(dropCurrent = true)
            withTimeout(3_000) { client.state.first { it !is ClientState.Ready } }
            val back = withTimeout(5_000) { client.state.first { it is ClientState.Ready || it is ClientState.Failed } }
            if (back is ClientState.Failed) {
                println("FAIL: reconnect: ${back.reason}")
                exitProcess(1)
            }
            println("reconnected with ${if (pairing != null) "device token" else "no auth"} in %.0f ms".format((System.nanoTime() - t0) / 1e6))
        }
    }
    delay(1_000) // let the queue drain and a final ping land
    println("done: dropped=${client.droppedEvents.get()} rtt=${client.rttMs.value?.let { "%.2f ms".format(it) } ?: "n/a"}")
    client.stop()
    exitProcess(0)
}
