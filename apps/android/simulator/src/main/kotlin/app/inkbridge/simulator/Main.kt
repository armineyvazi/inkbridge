package app.inkbridge.simulator

import app.inkbridge.core.client.ClientState
import app.inkbridge.core.client.DeviceDescriptor
import app.inkbridge.core.client.InkBridgeClient
import app.inkbridge.core.input.PointerAction
import app.inkbridge.core.input.RawSample
import app.inkbridge.core.input.StrokeProcessor
import app.inkbridge.core.input.ToolKind
import app.inkbridge.core.protocol.Capabilities
import app.inkbridge.core.transport.AdbReverseTransport
import app.inkbridge.core.transport.DEFAULT_USB_PORT
import app.inkbridge.core.transport.DEFAULT_WIFI_PORT
import app.inkbridge.core.transport.WifiTcpTransport
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
 *   simulator [--wifi HOST] [--port N] [--code XXXX-XXXX] [--strokes N] [--hz 200]
 *
 * Without --wifi it connects to 127.0.0.1:8765, i.e. exactly where the
 * tablet's traffic lands through `adb reverse`.
 */
fun main(args: Array<String>): Unit = runBlocking(Dispatchers.Default) {
    val opts = args.toList().windowed(2, 1, partialWindows = true).associate { it[0] to it.getOrNull(1) }
    val wifiHost = opts["--wifi"]
    val port = opts["--port"]?.toInt() ?: if (wifiHost != null) DEFAULT_WIFI_PORT else DEFAULT_USB_PORT
    val strokes = opts["--strokes"]?.toInt() ?: 5
    val hz = opts["--hz"]?.toInt() ?: 200
    val width = 1404
    val height = 1872

    val client = InkBridgeClient(
        scope = this,
        transportFactory = { if (wifiHost != null) WifiTcpTransport(wifiHost, port) else AdbReverseTransport(port) },
        device = DeviceDescriptor("simulator", "InkBridge Simulator", "JVM", 0, Capabilities(true, false, false, false)),
        pairingCode = opts["--code"],
        pingIntervalMs = 500,
    )
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
    }
    delay(1_000) // let the queue drain and a final ping land
    println("done: dropped=${client.droppedEvents.get()} rtt=${client.rttMs.value?.let { "%.2f ms".format(it) } ?: "n/a"}")
    client.stop()
    exitProcess(0)
}
