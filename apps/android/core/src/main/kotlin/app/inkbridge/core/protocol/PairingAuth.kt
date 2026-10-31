package app.inkbridge.core.protocol

import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/**
 * Answers the host's pairing challenge: HMAC-SHA256(key = normalized pairing
 * code, message = nonce). The code never crosses the network. Mirrors
 * PairingAuth.swift; both are checked against protocol/fixtures/auth-vector.json.
 */
object PairingAuth {
    /** Uppercase, letters and digits only, so "k7qw m3xp" equals "K7QW-M3XP". */
    fun normalize(code: String): String = code.uppercase().filter { it.isLetterOrDigit() }

    fun response(code: String, nonceHex: String): String {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(normalize(code).encodeToByteArray(), "HmacSHA256"))
        return mac.doFinal(hexToBytes(nonceHex)).joinToString("") { "%02x".format(it) }
    }

    fun hexToBytes(hex: String): ByteArray {
        require(hex.length % 2 == 0) { "odd-length hex" }
        return ByteArray(hex.length / 2) { i -> hex.substring(i * 2, i * 2 + 2).toInt(16).toByte() }
    }
}
