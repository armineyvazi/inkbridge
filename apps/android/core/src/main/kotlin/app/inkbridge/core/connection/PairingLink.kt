package app.inkbridge.core.connection

import app.inkbridge.core.protocol.PROTOCOL_VERSION
import app.inkbridge.core.protocol.PairingAuth
import java.net.URI
import java.net.URLDecoder

/**
 * The `inkbridge://pair?…` link in the Mac's Connect Device QR code.
 * Mirrors PairingLink.swift; both parse protocol/fixtures/pairing-link.txt.
 *
 * It carries the certificate fingerprint, so a tablet that opens it pins
 * the Mac from the first byte instead of trusting on first use.
 */
data class PairingLink(
    val hostName: String,
    val hostId: String,
    val addresses: List<String>,
    val port: Int,
    val code: String,
    val fingerprint: ByteArray,
    val expiresAtEpochSec: Long,
) {
    fun expired(nowEpochSec: Long = System.currentTimeMillis() / 1000) = nowEpochSec >= expiresAtEpochSec

    companion object {
        /** Null for anything that is not a complete v3 pairing link. */
        fun parse(link: String): PairingLink? {
            val uri = runCatching { URI(link.trim()) }.getOrNull() ?: return null
            if (uri.scheme != "inkbridge" || uri.host != "pair") return null
            val q = (uri.rawQuery ?: return null).split("&").mapNotNull {
                val i = it.indexOf('=')
                if (i <= 0) null else it.substring(0, i) to URLDecoder.decode(it.substring(i + 1), "UTF-8")
            }.toMap()
            if (q["v"] != PROTOCOL_VERSION.toString()) return null
            val fp = q["fp"]?.takeIf { it.length == 64 }?.let { runCatching { PairingAuth.hexToBytes(it) }.getOrNull() } ?: return null
            val code = q["code"]?.let(PairingAuth::normalize)?.takeIf { it.length == 8 } ?: return null
            return PairingLink(
                hostName = q["name"]?.take(64) ?: return null,
                hostId = q["id"] ?: return null,
                addresses = q["addr"].orEmpty().split(",").filter { it.isNotBlank() },
                port = q["port"]?.toIntOrNull()?.takeIf { it in 1..65535 } ?: return null,
                code = code,
                fingerprint = fp,
                expiresAtEpochSec = q["exp"]?.toLongOrNull() ?: return null,
            )
        }
    }
}
