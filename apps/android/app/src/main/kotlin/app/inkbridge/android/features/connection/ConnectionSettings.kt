package app.inkbridge.android.features.connection

import android.content.Context
import app.inkbridge.core.transport.DEFAULT_USB_PORT
import app.inkbridge.core.transport.DEFAULT_WIFI_PORT
import app.inkbridge.core.transport.TransportKind
import java.util.UUID

/** Persisted connection preferences. */
data class ConnectionSettings(
    val mode: TransportKind = TransportKind.USB,
    val wifiHost: String = "",
    val wifiPort: Int = DEFAULT_WIFI_PORT,
    val usbPort: Int = DEFAULT_USB_PORT,
    val pairingCode: String = "",
    /**
     * Ink on the tablet. On by default since the renderer moved off the UI
     * thread; the old UI-thread renderer raised pen→Mac p95 from 16 to 59 ms.
     */
    val showLocalInk: Boolean = true,
) {
    companion object {
        private const val PREFS = "inkbridge"

        fun load(context: Context): ConnectionSettings {
            val p = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            return ConnectionSettings(
                mode = runCatching { TransportKind.valueOf(p.getString("mode", "USB")!!) }.getOrDefault(TransportKind.USB),
                wifiHost = p.getString("wifiHost", "")!!,
                wifiPort = p.getInt("wifiPort", DEFAULT_WIFI_PORT),
                usbPort = p.getInt("usbPort", DEFAULT_USB_PORT),
                pairingCode = p.getString("pairingCode", "")!!,
                showLocalInk = p.getBoolean("showLocalInk", true),
            )
        }

        /** A random install ID, not a hardware serial: identifies the tablet without fingerprinting it. */
        fun deviceId(context: Context): String {
            val p = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            return p.getString("deviceId", null) ?: UUID.randomUUID().toString().also {
                p.edit().putString("deviceId", it).apply()
            }
        }
    }

    fun save(context: Context) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putString("mode", mode.name)
            .putString("wifiHost", wifiHost)
            .putInt("wifiPort", wifiPort)
            .putInt("usbPort", usbPort)
            .putString("pairingCode", pairingCode)
            .putBoolean("showLocalInk", showLocalInk)
            .apply()
    }
}
