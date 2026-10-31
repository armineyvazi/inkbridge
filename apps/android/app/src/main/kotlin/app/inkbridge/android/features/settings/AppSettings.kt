package app.inkbridge.android.features.settings

import android.content.Context
import app.inkbridge.core.canvas.Viewport
import app.inkbridge.core.connection.ConnectionMode
import app.inkbridge.core.input.PressureResponse
import app.inkbridge.core.transport.DEFAULT_USB_PORT
import app.inkbridge.core.transport.DEFAULT_WIFI_PORT
import java.util.UUID

/** Where the canvas opens. */
enum class StartView(val label: String) { HOME("Actual size"), FIT("Fit all ink"), LAST("Where I left off") }

/** Paper texture. Drawn by the tablet only; never sent to the Mac. */
enum class CanvasBackground(val label: String) { BLANK("Blank"), DOTS("Dot grid"), LINES("Lines") }

enum class TextSize(val label: String, val scale: Float) { NORMAL("Normal", 1f), LARGE("Large", 1.15f) }

/** Every user preference, persisted in SharedPreferences. */
data class AppSettings(
    val mode: ConnectionMode = ConnectionMode.WIFI,
    val autoReconnect: Boolean = true,
    val discovery: Boolean = true,
    /** Manual fallback when discovery cannot see the Mac (e.g. client isolation on the router). */
    val manualHost: String = "",
    val manualPort: Int = DEFAULT_WIFI_PORT,
    val usbPort: Int = DEFAULT_USB_PORT,
    val pressure: PressureResponse = PressureResponse.NORMAL,
    val fingerNavigation: Boolean = true,
    val startView: StartView = StartView.LAST,
    /** Ink on the tablet. On since the renderer moved off the UI thread (pen→Mac p95 59 → 15 ms). */
    val showLocalInk: Boolean = true,
    val background: CanvasBackground = CanvasBackground.BLANK,
    /** A one-frame black flash after Clear and Fit, which removes e-ink ghosting. */
    val cleanRefresh: Boolean = true,
    val textSize: TextSize = TextSize.NORMAL,
    val lastViewport: Viewport = Viewport.HOME,
) {
    companion object {
        private const val PREFS = "inkbridge"

        fun load(ctx: Context): AppSettings {
            val p = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val d = AppSettings()
            fun <E : Enum<E>> enum(key: String, def: E, values: Array<E>) =
                values.firstOrNull { it.name == p.getString(key, null) } ?: def
            return AppSettings(
                mode = enum("connectionMode", d.mode, ConnectionMode.entries.toTypedArray()),
                autoReconnect = p.getBoolean("autoReconnect", d.autoReconnect),
                discovery = p.getBoolean("discovery", d.discovery),
                manualHost = p.getString("manualHost", null) ?: p.getString("wifiHost", "")!!,
                manualPort = p.getInt("manualPort", p.getInt("wifiPort", d.manualPort)),
                usbPort = p.getInt("usbPort", d.usbPort),
                pressure = enum("pressure", d.pressure, PressureResponse.entries.toTypedArray()),
                fingerNavigation = p.getBoolean("fingerNavigation", d.fingerNavigation),
                startView = enum("startView", d.startView, StartView.entries.toTypedArray()),
                showLocalInk = p.getBoolean("showLocalInk", d.showLocalInk),
                background = enum("background", d.background, CanvasBackground.entries.toTypedArray()),
                cleanRefresh = p.getBoolean("cleanRefresh", d.cleanRefresh),
                textSize = enum("textSize", d.textSize, TextSize.entries.toTypedArray()),
                lastViewport = Viewport(
                    p.getFloat("vpX", 0f).toDouble(), p.getFloat("vpY", 0f).toDouble(), p.getFloat("vpZoom", 1f).toDouble(),
                ),
            )
        }

        /** A random install ID, not a hardware serial: identifies the tablet without fingerprinting it. */
        fun deviceId(ctx: Context): String {
            val p = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            return p.getString("deviceId", null) ?: UUID.randomUUID().toString().also {
                p.edit().putString("deviceId", it).apply()
            }
        }
    }

    fun save(ctx: Context) {
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putString("connectionMode", mode.name)
            .putBoolean("autoReconnect", autoReconnect)
            .putBoolean("discovery", discovery)
            .putString("manualHost", manualHost)
            .putInt("manualPort", manualPort)
            .putInt("usbPort", usbPort)
            .putString("pressure", pressure.name)
            .putBoolean("fingerNavigation", fingerNavigation)
            .putString("startView", startView.name)
            .putBoolean("showLocalInk", showLocalInk)
            .putString("background", background.name)
            .putBoolean("cleanRefresh", cleanRefresh)
            .putString("textSize", textSize.name)
            .putFloat("vpX", lastViewport.x.toFloat())
            .putFloat("vpY", lastViewport.y.toFloat())
            .putFloat("vpZoom", lastViewport.zoom.toFloat())
            // v2's permanent pairing code is meaningless with v3 one-time codes.
            .remove("pairingCode")
            .apply()
    }
}
