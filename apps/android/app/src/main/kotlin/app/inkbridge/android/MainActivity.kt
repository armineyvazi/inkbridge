package app.inkbridge.android

import android.app.AlertDialog
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.util.Log
import android.view.View
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.WindowManager
import android.widget.Button
import android.widget.PopupMenu
import android.widget.TextView
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.lifecycle.lifecycleScope
import app.inkbridge.android.features.canvas.CanvasRenderer
import app.inkbridge.android.features.canvas.CanvasView
import app.inkbridge.android.features.connection.ConnectionSettings
import app.inkbridge.android.features.settings.SettingsDialog
import app.inkbridge.android.input.AndroidMotionEventSource
import app.inkbridge.android.input.StylusCapabilityProbe
import app.inkbridge.core.canvas.CanvasDocument
import app.inkbridge.core.canvas.Viewport
import app.inkbridge.core.client.ClientState
import app.inkbridge.core.client.DeviceDescriptor
import app.inkbridge.core.client.InkBridgeClient
import app.inkbridge.core.input.StrokeProcessor
import app.inkbridge.core.protocol.CanvasCommand
import app.inkbridge.core.protocol.Payload
import app.inkbridge.core.protocol.WireStyle
import app.inkbridge.core.transport.AdbReverseTransport
import app.inkbridge.core.transport.TransportKind
import app.inkbridge.core.transport.WifiTcpTransport
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.launch

/**
 * One screen: controls, live stylus diagnostics, and the infinite canvas.
 *
 * Event order for a pen sample (latency first): MotionEvent →
 * StrokeProcessor → client.submit (network) → CanvasDocument (mirror) →
 * renderer request (drawn on its own thread).
 */
class MainActivity : ComponentActivity() {
    private lateinit var canvas: CanvasView
    private lateinit var status: TextView
    private lateinit var diagnostics: TextView
    private lateinit var settings: ConnectionSettings
    private val document = CanvasDocument()
    private val renderer = CanvasRenderer(document)
    private val processor = StrokeProcessor(streamTag = randomTag())
    private val source = AndroidMotionEventSource(processor)
    private var client: InkBridgeClient? = null
    private var statusJob: Job? = null
    private var lastViewportSentAt = 0L

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        setContentView(R.layout.activity_main)
        hideSystemBars()

        settings = ConnectionSettings.load(this)
        status = findViewById(R.id.status)
        diagnostics = findViewById(R.id.diagnostics)
        canvas = findViewById(R.id.canvas)
        canvas.source = source
        canvas.renderer = renderer
        renderer.inkVisible = settings.showLocalInk
        canvas.onDiagnostics = { diagnostics.text = it }
        canvas.onSurfaceChanged = { w, h -> client?.updateSurface(w, h) }
        canvas.onViewport = { v, final -> applyViewport(v, final, fromHost = false) }
        source.onEvents = { events ->
            val c = client
            for (e in events) {
                c?.submit(e)  // network first: the Mac is where the user looks
                document.applyLocal(e, LOCAL_STYLE)
            }
        }
        wireButtons()
        updateInkButton()
        Log.i(TAG, StylusCapabilityProbe.report())
    }

    override fun onStart() {
        super.onStart()
        startClient()
    }

    override fun onStop() {
        stopClient()
        super.onStop()
    }

    override fun onDestroy() {
        renderer.quit()
        super.onDestroy()
    }

    // MARK: Controls

    private fun wireButtons() {
        findViewById<Button>(R.id.undo).setOnClickListener { command(CanvasCommand.UNDO) }
        findViewById<Button>(R.id.redo).setOnClickListener { command(CanvasCommand.REDO) }
        findViewById<Button>(R.id.clear).setOnClickListener { clearCanvas() }
        findViewById<Button>(R.id.zoom_in).setOnClickListener { zoomBy(1.5) }
        findViewById<Button>(R.id.zoom_out).setOnClickListener { zoomBy(1 / 1.5) }
        findViewById<Button>(R.id.fit).setOnClickListener {
            applyViewport(Viewport.fitting(document.contentBounds(), canvas.width, canvas.height), final = true, fromHost = false)
        }
        findViewById<Button>(R.id.home).setOnClickListener { applyViewport(Viewport.HOME, final = true, fromHost = false) }
        findViewById<Button>(R.id.ink).setOnClickListener {
            settings = settings.copy(showLocalInk = !settings.showLocalInk).also { it.save(this) }
            renderer.inkVisible = settings.showLocalInk
            updateInkButton()
        }
        findViewById<Button>(R.id.more).setOnClickListener { showMoreMenu(it) }
    }

    private fun showMoreMenu(anchor: View) {
        PopupMenu(this, anchor).apply {
            menu.add("Reconnect").setOnMenuItemClickListener { restartClient(); true }
            menu.add("Connection settings…").setOnMenuItemClickListener { openSettings(); true }
            menu.add("Device & digitizer").setOnMenuItemClickListener { showDeviceReport(); true }
            show()
        }
    }

    private fun updateInkButton() {
        findViewById<Button>(R.id.ink).text = if (settings.showLocalInk) "Ink ✓" else "Ink ✗"
    }

    private fun command(c: CanvasCommand) {
        if (client?.state?.value is ClientState.Ready) client?.submitCommand(c)
        else Toast.makeText(this, "Connect to the Mac to ${c.wire}", Toast.LENGTH_SHORT).show()
    }

    /** Connected: the Mac clears (undoable there). Offline: only this screen; the Mac's copy returns on reconnect. */
    private fun clearCanvas() {
        if (client?.state?.value is ClientState.Ready) {
            client?.submitCommand(CanvasCommand.CLEAR)
        } else {
            document.clearLocal()
            Toast.makeText(this, "Cleared on this tablet only. The Mac keeps its copy.", Toast.LENGTH_LONG).show()
        }
    }

    private fun zoomBy(f: Double) {
        applyViewport(canvas.viewport.zoomedBy(f, canvas.width / 2f, canvas.height / 2f), final = true, fromHost = false)
    }

    /**
     * Single place the view changes. Gesture moves only preview (and are sent at
     * most every 100 ms); the final viewport is committed, drawn and sent.
     */
    private fun applyViewport(v: Viewport, final: Boolean, fromHost: Boolean) {
        if (!final) {
            val now = System.nanoTime()
            if (now - lastViewportSentAt > 100_000_000) {
                lastViewportSentAt = now
                client?.submitViewport(v)
            }
            return
        }
        canvas.viewport = v
        processor.viewport = v
        renderer.setViewport(v)
        if (!fromHost) client?.submitViewport(v)
        updateStatusZoom()
    }

    private var lastStatus = ""

    private fun updateStatusZoom() {
        status.text = lastStatus + zoomSuffix()
    }

    private fun zoomSuffix(): String {
        val z = canvas.viewport.zoom
        return if (kotlin.math.abs(z - 1) < 0.01) "" else "  ·  ${(z * 100).toInt()} %"
    }

    // MARK: Connection

    private fun startClient() {
        val s = settings
        if (s.mode == TransportKind.WIFI && s.wifiHost.isBlank()) {
            status.text = "Wi-Fi: set the Mac's address in ⋮ → Connection settings"
            return
        }
        val c = InkBridgeClient(
            scope = lifecycleScope,
            transportFactory = {
                if (s.mode == TransportKind.USB) AdbReverseTransport(s.usbPort) else WifiTcpTransport(s.wifiHost, s.wifiPort)
            },
            device = descriptor(),
            pairingCode = s.pairingCode.ifBlank { null },
        )
        if (canvas.width > 0) c.updateSurface(canvas.width, canvas.height)
        c.submitViewport(canvas.viewport)
        c.onStrokeSent = document::markSent
        c.onHostPayload = { p ->
            if (p is Payload.CanvasViewport) runOnUiThread { applyViewport(p.viewport, final = true, fromHost = true) }
            else document.applyHost(p)
        }
        client = c
        c.start()
        statusJob = lifecycleScope.launch {
            c.state.combine(c.rttMs) { st, rtt -> describe(st, rtt) }.collect {
                lastStatus = it
                updateStatusZoom()
            }
        }
    }

    private fun stopClient() {
        val c = client ?: return
        client = null
        statusJob?.cancel()
        lifecycleScope.launch { c.stop() }
    }

    private fun restartClient() {
        stopClient()
        startClient()
    }

    private fun openSettings() {
        SettingsDialog.show(this, settings) { updated ->
            settings = updated
            updated.save(this)
            renderer.inkVisible = updated.showLocalInk
            updateInkButton()
            restartClient()
        }
    }

    private fun describe(state: ClientState, rtt: Double?): String = when (state) {
        ClientState.Idle -> "Idle"
        is ClientState.Connecting -> "Connecting via ${label(state.kind)}…"
        is ClientState.Ready -> "● ${state.hostName} · ${label(state.kind)}" + (rtt?.let { " · %.0f ms".format(it) } ?: "")
        is ClientState.Retrying -> "○ ${label(state.kind)}: ${state.reason} — retry in ${state.delayMs} ms"
        is ClientState.Failed -> "✕ ${state.reason}"
    }

    private fun label(kind: TransportKind) = if (kind == TransportKind.USB) "USB" else "Wi-Fi"

    private fun descriptor() = DeviceDescriptor(
        deviceId = ConnectionSettings.deviceId(this),
        deviceName = (Settings.Global.getString(contentResolver, Settings.Global.DEVICE_NAME)
            ?: "${Build.MANUFACTURER} ${Build.MODEL}").take(64),
        model = Build.MODEL.take(64),
        androidApi = Build.VERSION.SDK_INT,
        capabilities = StylusCapabilityProbe.capabilities(),
    )

    private fun showDeviceReport() {
        val report = StylusCapabilityProbe.report()
        Log.i(TAG, report)
        AlertDialog.Builder(this)
            .setTitle("Device & digitizer")
            .setMessage(report + "\n\nAlso written to logcat (tag $TAG).")
            .setPositiveButton("OK", null)
            .show()
    }

    private fun hideSystemBars() {
        if (Build.VERSION.SDK_INT >= 30) {
            window.insetsController?.let {
                it.hide(WindowInsets.Type.systemBars())
                it.systemBarsBehavior = WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            }
        }
    }

    companion object {
        const val TAG = "InkBridge"
        /** Until the Mac styles a stroke (a few ms later), draw it black at 2.5 canvas px. */
        private val LOCAL_STYLE = WireStyle(0xFF000000.toInt(), 2.5)
        private fun randomTag() = java.util.UUID.randomUUID().toString().take(8)
    }
}
