package app.inkbridge.core.protocol

import java.security.MessageDigest
import java.security.SecureRandom
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/**
 * Proofs for the LAN handshake (protocol v3):
 * `HMAC-SHA256(key, label ‖ 0x00 ‖ nonce ‖ fingerprint)`.
 *
 * - nonce: this connection's challenge, so proofs cannot be replayed;
 * - fingerprint: SHA-256 of the TLS certificate *this device saw*, so a man
 *   in the middle (who must show its own certificate) gets a proof that the
 *   real Mac rejects;
 * - label: keeps the device proof, the Mac's answer and the token proof apart.
 *
 * Mirrors PairingAuth.swift; both are checked against
 * protocol/fixtures/auth-vector.json.
 */
object PairingAuth {
    const val PAIR_LABEL = "inkbridge-v3-pair"
    const val HOST_LABEL = "inkbridge-v3-host"
    const val TOKEN_LABEL = "inkbridge-v3-token"

    /** Uppercase, letters and digits only, so "k7qw m3xp" equals "K7QW-M3XP". */
    fun normalize(code: String): String = code.uppercase().filter { it.isLetterOrDigit() }

    fun pairProof(code: String, nonceHex: String, fingerprint: ByteArray): String =
        proof(normalize(code).encodeToByteArray(), PAIR_LABEL, nonceHex, fingerprint)

    fun hostProof(code: String, nonceHex: String, fingerprint: ByteArray): String =
        proof(normalize(code).encodeToByteArray(), HOST_LABEL, nonceHex, fingerprint)

    fun tokenProof(tokenHex: String, nonceHex: String, fingerprint: ByteArray): String =
        proof(hexToBytes(tokenHex), TOKEN_LABEL, nonceHex, fingerprint)

    /** Constant-time comparison of the Mac's answer in pair.granted. */
    fun verifyHost(proofHex: String, code: String, nonceHex: String, fingerprint: ByteArray): Boolean =
        MessageDigest.isEqual(
            hostProof(code, nonceHex, fingerprint).encodeToByteArray(),
            proofHex.lowercase().encodeToByteArray(),
        )

    private fun proof(key: ByteArray, label: String, nonceHex: String, fingerprint: ByteArray): String {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key, "HmacSHA256"))
        mac.update(label.encodeToByteArray())
        mac.update(0)
        mac.update(hexToBytes(nonceHex))
        mac.update(fingerprint)
        return toHex(mac.doFinal())
    }

    fun randomHex(bytes: Int): String = toHex(ByteArray(bytes).also { SecureRandom().nextBytes(it) })

    fun toHex(b: ByteArray): String = b.joinToString("") { "%02x".format(it) }

    fun hexToBytes(hex: String): ByteArray {
        require(hex.length % 2 == 0) { "odd-length hex" }
        return ByteArray(hex.length / 2) { i -> hex.substring(i * 2, i * 2 + 2).toInt(16).toByte() }
    }
}
