package app.inkbridge.android.features.connection

import android.content.Context
import app.inkbridge.core.client.Credentials
import app.inkbridge.core.protocol.PairingAuth

/** The Mac this tablet is paired with. One Mac at a time, which is what people use. */
data class PairedMac(
    val hostId: String,
    val name: String,
    val fingerprintHex: String,
    /** Secret. Lives only in app-private storage; never logged or displayed. */
    val tokenHex: String,
    val lastAddress: String,
    val lastPort: Int,
    val pairedAt: Long,
    val lastConnectedAt: Long,
) {
    val credentials get() = Credentials.Token(hostId, tokenHex, PairingAuth.hexToBytes(fingerprintHex))

    /** First 8 bytes, as the Mac shows it in Connect Device. */
    val shortFingerprint get() = fingerprintHex.take(16).uppercase().chunked(2).joinToString(":")
}

/**
 * Persists [PairedMac] in app-private SharedPreferences. Android's app
 * sandbox keeps other apps out; a rooted device or a backup could read it,
 * which is why backups are disabled in the manifest (allowBackup=false).
 */
class PairingStore(ctx: Context) {
    private val p = ctx.getSharedPreferences("inkbridge-pairing", Context.MODE_PRIVATE)

    fun load(): PairedMac? {
        val id = p.getString("hostId", null) ?: return null
        return PairedMac(
            id, p.getString("name", "Mac")!!, p.getString("fp", "")!!, p.getString("token", "")!!,
            p.getString("addr", "")!!, p.getInt("port", 0), p.getLong("pairedAt", 0), p.getLong("lastConnectedAt", 0),
        ).takeIf { it.tokenHex.length == 64 && it.fingerprintHex.length == 64 }
    }

    fun save(m: PairedMac) {
        p.edit().putString("hostId", m.hostId).putString("name", m.name).putString("fp", m.fingerprintHex)
            .putString("token", m.tokenHex).putString("addr", m.lastAddress).putInt("port", m.lastPort)
            .putLong("pairedAt", m.pairedAt).putLong("lastConnectedAt", m.lastConnectedAt).apply()
    }

    fun clear() = p.edit().clear().apply()
}
