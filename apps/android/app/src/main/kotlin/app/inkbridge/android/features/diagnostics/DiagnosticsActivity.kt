package app.inkbridge.android.features.diagnostics

import android.os.Build
import android.os.Bundle
import android.util.Log
import android.widget.LinearLayout
import android.widget.TextView
import app.inkbridge.android.R
import app.inkbridge.android.design.Ink
import app.inkbridge.android.design.InkActivity
import app.inkbridge.android.features.connection.ConnectionManager
import app.inkbridge.android.features.drawing.StylusDiagnostics
import app.inkbridge.android.input.StylusCapabilityProbe
import app.inkbridge.core.client.ClientState
import app.inkbridge.core.protocol.PROTOCOL_VERSION
import app.inkbridge.core.protocol.PairingAuth
import kotlinx.coroutines.flow.combine

/**
 * Everything technical in one place, for troubleshooting: raw connection
 * state, addresses, certificate fingerprints, latency, queue counters, and
 * what the digitizer reports. Never shows the device token or a code.
 */
class DiagnosticsActivity : InkActivity() {
    private lateinit var report: TextView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        report = Ink.text(this, "", Ink.CAPTION).apply {
            typeface = android.graphics.Typeface.MONOSPACE
            setTextIsSelectable(true)
        }
        val c = Ink.column(this)
        c.add(Ink.body(this, "Share this with whoever is helping you. It contains no codes or keys.").apply { setTextColor(Ink.GREY) })
        c.add(report, Ink.dp(this, Ink.M))
        c.add(Ink.button(this, "Write to system log", Ink.ButtonStyle.SECONDARY) { Log.i(ConnectionManager.TAG, report.text.toString()) }, Ink.dp(this, Ink.L))
        setContentView(LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Ink.PAPER)
            addView(Ink.topBar(this@DiagnosticsActivity, "Diagnostics", onBack = ::finish,
                Ink.iconButton(this@DiagnosticsActivity, R.drawable.ic_refresh, "Refresh") { update() }))
            addView(Ink.page(this@DiagnosticsActivity, c), LinearLayout.LayoutParams(-1, 0, 1f))
        })
        // Refresh on state changes only; latency is read when the screen updates, not streamed.
        observe(combine(manager.client.state, manager.discovery.macs, manager.network.state) { a, b, n -> Triple(a, b, n) }) { update() }
    }

    private fun update() {
        val m = manager
        val st = m.client.state.value
        val paired = m.paired.value
        val seen = m.client.peerFingerprint?.let { PairingAuth.toHex(it) }
        val pinOk = paired?.fingerprintHex?.let { seen == null || it == seen }
        val text = buildString {
            line("connection", describe(st))
            line("mode", m.settings.mode.name.lowercase())
            line("address", m.lastAddress ?: "–")
            line("rtt", m.client.rttMs.value?.let { "%.1f ms".format(it) } ?: "–")
            line("paired mac", paired?.name ?: "none")
            line("mac id", paired?.hostId ?: "–")
            line("pinned cert", paired?.shortFingerprint ?: "–")
            line("seen cert", seen?.let { it.take(16).uppercase().chunked(2).joinToString(":") } ?: "–")
            if (pinOk == false) line("WARNING", "certificate does not match the pin")
            line("stream", m.client.streamId.take(8))
            line("dropped", m.client.droppedEvents.get().toString())
            line("re-sent", m.client.replayedMessages.get().toString())
            line("protocol", "v$PROTOCOL_VERSION")
            append('\n')
            line("wifi", m.network.state.value.let { if (it.connected) "connected · ${it.address ?: "?"}" else if (m.network.wifiEnabled) "not connected" else "off" })
            line("discovery", if (m.discovery.running) "searching" else "stopped")
            m.discovery.macs.value.forEach { line("  found", "${it.name} ${it.address}:${it.port} id=${it.hostId?.take(8) ?: "?"}") }
            m.discovery.error.value?.let { line("  error", it) }
            append('\n')
            line("device", "${Build.MANUFACTURER} ${Build.MODEL} · Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})")
            line("canvas", "${m.document.read { it.size }} strokes")
            append('\n')
            append("stylus (last seen on the canvas):\n")
            append(StylusDiagnostics.shared.text()).append("\n\n")
            append(StylusCapabilityProbe.report())
        }
        Ink.setText(report, text)
    }

    private fun StringBuilder.line(k: String, v: String) {
        append(k.padEnd(13)).append(v).append('\n')
    }

    private fun describe(s: ClientState) = when (s) {
        ClientState.Idle -> "idle"
        is ClientState.Connecting -> "connecting (attempt ${s.attempt})"
        is ClientState.Authenticating -> if (s.pairing) "pairing" else "authenticating"
        is ClientState.Ready -> "ready · ${s.hostName} · ${s.kind.name.lowercase()}"
        is ClientState.Retrying -> "retrying in ${s.delayMs} ms: ${s.reason}"
        is ClientState.Failed -> "failed (${s.kind.name.lowercase()}): ${s.reason}"
    }
}
