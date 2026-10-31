package app.inkbridge.android

import android.app.AlertDialog
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.util.Log
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.WindowManager
import android.widget.Button
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.lifecycle.lifecycleScope
import app.inkbridge.android.features.connection.ConnectionSettings
import app.inkbridge.android.features.drawing.DrawingSurfaceView
import app.inkbridge.android.features.settings.SettingsDialog
import app.inkbridge.android.input.AndroidMotionEventSource
import app.inkbridge.android.input.StylusCapabilityProbe
import app.inkbridge.core.client.ClientState
import app.inkbridge.core.client.DeviceDescriptor
import app.inkbridge.core.client.InkBridgeClient
import app.inkbridge.core.input.CoordinateNormalizer
import app.inkbridge.core.input.StrokeProcessor
import app.inkbridge.core.transport.AdbReverseTransport
import app.inkbridge.core.transport.TransportKind
import app.inkbridge.core.transport.WifiTcpTransport
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.launch

/**
 * Single screen: status line, live stylus diagnostics, drawing surface.
 *
 * The client lives while the activity is started; drawing happens in the
 * foreground, and dropping the socket in onStop avoids a background
 * connection the user cannot see.
 */
class MainActivity : ComponentActivity() {
    private lateinit var surface: DrawingSurfaceView
    private lateinit var status: TextView
    private lateinit var diagnostics: TextView
    private lateinit var settings: ConnectionSettings
    private val processor = StrokeProcessor(CoordinateNormalizer(1, 1), streamTag = randomTag())
    private val source = AndroidMotionEventSource(processor)
    private var client: InkBridgeClient? = null
    private var statusJob: Job? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        setContentView(R.layout.activity_main)
        hideSystemBars()

        settings = ConnectionSettings.load(this)
        status = findViewById(R.id.status)
        diagnostics = findViewById(R.id.diagnostics)
        surface = findViewById(R.id.surface)
        surface.source = source
        surface.showLocalInk = settings.showLocalInk
        surface.onDiagnostics = { diagnostics.text = it }
        surface.onSurfaceChanged = { w, h ->
            processor.normalizer.resize(w, h)
            client?.updateSurface(w, h)
        }
        source.onEvents = { events -> client?.let { c -> events.forEach(c::submit) } }

        findViewById<Button>(R.id.reconnect).setOnClickListener { restartClient() }
        findViewById<Button>(R.id.clear).setOnClickListener { surface.clear() }
        findViewById<Button>(R.id.info).setOnClickListener { showDeviceReport() }
        findViewById<Button>(R.id.settings).setOnClickListener {
            SettingsDialog.show(this, settings) { updated ->
                settings = updated
                updated.save(this)
                surface.showLocalInk = updated.showLocalInk
                restartClient()
            }
        }
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

    private fun startClient() {
        val s = settings
        if (s.mode == TransportKind.WIFI && s.wifiHost.isBlank()) {
            status.text = "Wi-Fi: set the Mac's address in Settings"
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
        if (surface.width > 0) c.updateSurface(surface.width, surface.height)
        client = c
        c.start()
        statusJob = lifecycleScope.launch {
            c.state.combine(c.rttMs) { st, rtt -> describe(st, rtt) }.collect { status.text = it }
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

    private fun describe(state: ClientState, rtt: Double?): String = when (state) {
        ClientState.Idle -> "Idle"
        is ClientState.Connecting -> "Connecting via ${label(state.kind)}…"
        is ClientState.Ready -> "● ${state.hostName} via ${label(state.kind)}" + (rtt?.let { "  rtt %.1f ms".format(it) } ?: "")
        is ClientState.Retrying -> "○ ${label(state.kind)}: ${state.reason} — retry ${state.attempt} in ${state.delayMs} ms" +
            if (state.kind == TransportKind.USB) "  (is adb reverse set up and InkBridge running on the Mac?)" else ""
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
        private fun randomTag() = java.util.UUID.randomUUID().toString().take(8)
    }
}
