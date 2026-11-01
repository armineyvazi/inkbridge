package app.inkbridge.android.features.settings

import android.app.AlertDialog
import android.os.Build
import android.os.Bundle
import android.view.View
import android.widget.LinearLayout
import app.inkbridge.android.BuildConfig
import app.inkbridge.android.R
import app.inkbridge.android.design.Ink
import app.inkbridge.android.design.InkActivity
import app.inkbridge.android.design.SpacedColumn
import app.inkbridge.android.features.connect.ConnectActivity
import app.inkbridge.android.features.diagnostics.DiagnosticsActivity
import app.inkbridge.android.input.StylusCapabilityProbe
import app.inkbridge.core.connection.ConnectionMode
import app.inkbridge.core.input.PressureResponse
import app.inkbridge.core.protocol.PROTOCOL_VERSION

/**
 * Settings in four sections: Connection, Drawing, Display, Application.
 * Every choice is visible at once (toggles and segmented controls, no
 * pickers to open), and applies immediately. Networking details live in
 * Diagnostics, not here.
 */
class SettingsActivity : InkActivity() {
    private var s: AppSettings
        get() = manager.settings
        set(v) = manager.update(v)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        render()
    }

    override fun onRestart() {
        super.onRestart()
        render()  // the paired Mac may have changed in Connect
    }

    private fun render() {
        setContentView(LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Ink.PAPER)
            addView(Ink.topBar(this@SettingsActivity, "Settings", onBack = ::finish))
            addView(Ink.page(this@SettingsActivity, content()), LinearLayout.LayoutParams(-1, 0, 1f))
        })
    }

    private fun content(): View {
        val c = Ink.column(this)
        connection(c)
        drawing(c)
        display(c)
        application(c)
        return c
    }

    private fun connection(c: SpacedColumn) {
        c.add(Ink.section(this, "Connection"), 0)
        c.add(Ink.setting(this, "Connect with", "Wi-Fi needs no cable. USB needs USB debugging and adb on the Mac.",
            Ink.segmented(this, listOf("Wi-Fi", "USB cable"), if (s.mode == ConnectionMode.WIFI) 0 else 1) {
                s = s.copy(mode = if (it == 0) ConnectionMode.WIFI else ConnectionMode.USB)
                manager.resume()
            }, below = true), 0)
        val paired = manager.paired.value
        if (paired != null) {
            c.add(Ink.setting(this, "Paired Mac", "${paired.name} · certificate ${paired.shortFingerprint}",
                Ink.button(this, "Forget", Ink.ButtonStyle.SECONDARY) { confirmForget(paired.name) }), 0)
        } else {
            c.add(Ink.listRow(this, R.drawable.ic_laptop, "Pair with a Mac", "Not paired yet") { open<ConnectActivity>() }, 0)
        }
        c.add(toggle("Reconnect automatically", "After Wi-Fi drops or the tablet wakes up.", s.autoReconnect) { s = s.copy(autoReconnect = it) }, 0)
        c.add(toggle("Find Macs automatically", "Uses Bonjour on the local network. Turn off only if your network blocks it.", s.discovery) {
            s = s.copy(discovery = it)
        }, 0)
    }

    private fun drawing(c: SpacedColumn) {
        c.add(Ink.section(this, "Drawing"), 0)
        val hasPressure = StylusCapabilityProbe.capabilities().pressure
        c.add(Ink.setting(this, "Pressure", if (hasPressure) "How hard you press to get a full-width line." else "This stylus does not report pressure.",
            Ink.segmented(this, listOf("Off", "Soft", "Normal", "Firm"), PressureResponse.entries.indexOf(s.pressure)) {
                s = s.copy(pressure = PressureResponse.entries[it])
            }, below = true), 0)
        c.add(toggle("Pan and zoom with fingers", "One finger moves, two fingers zoom. The pen always draws.", s.fingerNavigation) {
            s = s.copy(fingerNavigation = it)
        }, 0)
        c.add(Ink.setting(this, "Canvas opens at", null,
            Ink.segmented(this, StartView.entries.map { it.label }, StartView.entries.indexOf(s.startView)) {
                s = s.copy(startView = StartView.entries[it])
            }, below = true), 0)
        c.add(toggle("Show ink on the tablet", "Off sends strokes to the Mac without drawing them here.", s.showLocalInk) {
            s = s.copy(showLocalInk = it)
        }, 0)
    }

    private fun display(c: SpacedColumn) {
        c.add(Ink.section(this, "Display"), 0)
        c.add(Ink.setting(this, "Canvas background", "Choose it on the canvas with the background button. It is shared with the Mac: Desktop Overlay or a Studio Canvas colour, with optional paper.",
            android.widget.Space(this)), 0)
        c.add(toggle("Clean refresh after Clear and Fit", "A brief black flash that removes e-ink ghosting.", s.cleanRefresh) {
            s = s.copy(cleanRefresh = it)
        }, 0)
        c.add(Ink.setting(this, "Text size", null,
            Ink.segmented(this, TextSize.entries.map { it.label }, TextSize.entries.indexOf(s.textSize)) {
                s = s.copy(textSize = TextSize.entries[it])
                Ink.textScale = s.textSize.scale
                render()
                cleanRefresh()
            }, below = true), 0)
        c.add(Ink.listRow(this, R.drawable.ic_refresh, "Refresh screen now", "Clears leftover ghost images") { cleanRefresh() }, 0)
    }

    private fun application(c: SpacedColumn) {
        c.add(Ink.section(this, "Application"), 0)
        c.add(Ink.infoRow(this, "Version", "${BuildConfig.VERSION_NAME} · protocol v$PROTOCOL_VERSION"), Ink.dp(this, Ink.S))
        c.add(Ink.infoRow(this, "Device", "${Build.MANUFACTURER} ${Build.MODEL} · Android ${Build.VERSION.RELEASE}"), 0)
        c.add(Ink.listRow(this, R.drawable.ic_info, "Diagnostics", "Connection, latency and stylus details") { open<DiagnosticsActivity>() }, Ink.dp(this, Ink.S))
        c.add(Ink.listRow(this, R.drawable.ic_pen, "About InkBridge", null) { about() }, 0)
    }

    private fun toggle(title: String, detail: String?, value: Boolean, onChange: (Boolean) -> Unit) =
        Ink.setting(this, title, detail, Ink.Toggle(this, value, onChange))

    private fun confirmForget(name: String) {
        AlertDialog.Builder(this)
            .setTitle("Forget $name?")
            .setMessage("This tablet will stop connecting to $name. To use it again you will need a new code from Connect Device on the Mac.")
            .setPositiveButton("Forget") { _, _ -> manager.forgetMac(); render() }
            .setNegativeButton("Cancel", null)
            .show()
    }

    private fun about() {
        AlertDialog.Builder(this)
            .setTitle("InkBridge")
            .setMessage("Turns this tablet into a drawing surface for your Mac. Your strokes appear on the Mac's screen as you write.\n\n" +
                "Everything stays on your local network: no account, no cloud, no internet needed. Wi-Fi connections are encrypted (TLS) and only paired devices are accepted.")
            .setPositiveButton("OK", null)
            .show()
    }
}
