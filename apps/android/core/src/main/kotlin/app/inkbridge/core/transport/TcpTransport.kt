package app.inkbridge.core.transport

import app.inkbridge.core.protocol.FrameDecoder
import app.inkbridge.core.protocol.Framing
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.BufferedOutputStream
import java.io.IOException
import java.net.InetSocketAddress
import java.net.Socket

/**
 * Framed messages over a blocking TCP socket, run on [io].
 *
 * Blocking sockets on a dedicated dispatcher are simpler than NIO here:
 * there is exactly one connection, and the reader thread doubles as the
 * disconnect detector.
 */
open class TcpTransport(
    private val host: String,
    private val port: Int,
    override val kind: TransportKind,
    private val connectTimeoutMs: Int = 3_000,
    private val io: CoroutineDispatcher = Dispatchers.IO,
) : Transport {
    private val state = MutableStateFlow<ConnectionState>(ConnectionState.Disconnected)
    override val connectionState: StateFlow<ConnectionState> = state.asStateFlow()

    private val inbox = Channel<ByteArray>(Channel.UNLIMITED)
    private val writeLock = Mutex()
    @Volatile private var socket: Socket? = null
    private var output: BufferedOutputStream? = null
    private var reader: Thread? = null

    override suspend fun connect() = withContext(io) {
        check(socket == null) { "transport is single-use" }
        state.value = ConnectionState.Connecting
        val s = Socket()
        try {
            // Disable Nagle: each message is tiny and latency matters more than packet count.
            s.tcpNoDelay = true
            s.keepAlive = true
            s.connect(InetSocketAddress(host, port), connectTimeoutMs)
        } catch (e: IOException) {
            s.close()
            state.value = ConnectionState.Failed("connect $host:$port: ${e.message}")
            inbox.close()
            throw e
        }
        socket = s
        output = BufferedOutputStream(s.getOutputStream(), 16 * 1024)
        state.value = ConnectionState.Connected
        reader = Thread({ readLoop(s) }, "inkbridge-tcp-reader").apply {
            isDaemon = true
            start()
        }
    }

    private fun readLoop(s: Socket) {
        val decoder = FrameDecoder()
        val chunk = ByteArray(16 * 1024)
        try {
            val input = s.getInputStream()
            while (true) {
                val n = input.read(chunk)
                if (n < 0) break
                decoder.append(chunk, 0, n)
                while (true) inbox.trySend(decoder.next() ?: break)
            }
            finish(ConnectionState.Disconnected)
        } catch (e: Exception) {
            finish(if (socket == null) ConnectionState.Disconnected else ConnectionState.Failed("read: ${e.message}"))
        }
    }

    override suspend fun send(data: ByteArray) {
        val frame = Framing.frame(data)
        writeLock.withLock {
            withContext(io) {
                val out = output ?: throw IOException("not connected")
                out.write(frame)
                out.flush()
            }
        }
    }

    override suspend fun disconnect() = withContext(io) {
        val s = socket
        socket = null
        s?.close()
        finish(ConnectionState.Disconnected)
    }

    private fun finish(final: ConnectionState) {
        if (state.value !is ConnectionState.Failed) state.value = final
        inbox.close()
        try {
            socket?.close()
        } catch (_: IOException) {
        }
    }

    override fun incomingMessages(): Flow<ByteArray> = inbox.receiveAsFlow()
}

/**
 * USB connection through `adb reverse tcp:8765 tcp:8765`: the tablet dials its
 * own loopback and adbd tunnels the bytes over the cable to the Mac's
 * localhost:8765. Development transport; needs USB debugging enabled.
 */
class AdbReverseTransport(port: Int = DEFAULT_USB_PORT) :
    TcpTransport("127.0.0.1", port, TransportKind.USB)

/** LAN connection to the Mac's Wi-Fi listener; the host requires pairing. */
class WifiTcpTransport(host: String, port: Int = DEFAULT_WIFI_PORT) :
    TcpTransport(host, port, TransportKind.WIFI)

const val DEFAULT_USB_PORT = 8765
const val DEFAULT_WIFI_PORT = 8766
const val BONJOUR_SERVICE_TYPE = "_inkbridge._tcp"
