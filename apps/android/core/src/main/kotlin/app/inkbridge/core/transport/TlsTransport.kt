package app.inkbridge.core.transport

import java.io.IOException
import java.net.Socket
import java.security.MessageDigest
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLSocket
import javax.net.ssl.X509TrustManager

/** The Mac presented a certificate other than the one pinned at pairing. */
class PinMismatchException(message: String) : IOException(message)

/**
 * The Wi-Fi transport: TLS over TCP to the Mac's LAN listener.
 *
 * The Mac's certificate is self-signed, so there is no chain to validate.
 * Instead it is pinned: [pin] is the SHA-256 recorded when this tablet
 * paired (or read from the QR link), and any other certificate fails the
 * handshake. With no pin (first contact by typed code) any certificate is
 * accepted, and [peerFingerprint] goes into the pairing proof, which is what
 * defeats a man in the middle: the Mac only accepts proofs over its own
 * certificate's fingerprint.
 */
class TlsTransport(
    host: String,
    port: Int = DEFAULT_WIFI_PORT,
    private val pin: ByteArray? = null,
    connectTimeoutMs: Int = 3_000,
) : TcpTransport(host, port, TransportKind.WIFI, connectTimeoutMs) {
    @Volatile override var peerFingerprint: ByteArray? = null
        private set

    override fun open(): Socket {
        val raw = super.open()
        try {
            val trust = PinningTrustManager(pin)
            val context = SSLContext.getInstance("TLS").apply { init(null, arrayOf(trust), null) }
            val tls = context.socketFactory.createSocket(raw, host, port, true) as SSLSocket
            tls.soTimeout = connectTimeoutMs
            try {
                tls.startHandshake()
            } catch (e: IOException) {
                trust.mismatch?.let { throw PinMismatchException(it) }
                throw e
            }
            tls.soTimeout = 0  // reads block; the client's keep-alive detects silence
            peerFingerprint = trust.seen
            return tls
        } catch (e: Exception) {
            raw.close()
            throw e
        }
    }

    private class PinningTrustManager(private val pin: ByteArray?) : X509TrustManager {
        @Volatile var seen: ByteArray? = null
        @Volatile var mismatch: String? = null

        override fun checkServerTrusted(chain: Array<out X509Certificate>, authType: String) {
            val leaf = chain.firstOrNull() ?: throw CertificateException("no certificate")
            val fp = sha256(leaf.encoded)
            seen = fp
            if (pin != null && !MessageDigest.isEqual(pin, fp)) {
                mismatch = "this Mac's certificate changed since pairing"
                throw CertificateException(mismatch)
            }
        }

        override fun checkClientTrusted(chain: Array<out X509Certificate>, authType: String) =
            throw CertificateException("client mode only")

        override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
    }

    companion object {
        fun sha256(b: ByteArray): ByteArray = MessageDigest.getInstance("SHA-256").digest(b)
    }
}
