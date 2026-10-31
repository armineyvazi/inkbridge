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
     * Off by default: drawing ink on the e-ink panel blocks the UI thread and
     * delays pen events. Measured on a Note Air 2 Plus over USB, pen→Mac p95
     * was 59 ms with local ink and 16 ms without.
     */
    val showLocalInk: Boolean = false,
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
                showLocalInk = p.getBoolean("showLocalInk", false),
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
