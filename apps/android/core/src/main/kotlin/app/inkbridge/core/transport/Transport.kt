package app.inkbridge.core.transport

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.StateFlow

/** How a transport reaches the Mac. Reported to the user, not to the protocol. */
enum class TransportKind { USB, WIFI }

sealed interface ConnectionState {
    data object Disconnected : ConnectionState
    data object Connecting : ConnectionState
    data object Connected : ConnectionState
    data class Failed(val reason: String) : ConnectionState
}

/**
 * A byte pipe carrying whole frames. Transports know nothing about message
 * contents; USB and Wi-Fi differ only in how the socket is opened.
 *
 * A Transport instance is single-use: after [disconnect] or a failure,
 * create a new one.
 */
interface Transport {
    val kind: TransportKind
    val connectionState: StateFlow<ConnectionState>

    suspend fun connect()

    /** Sends one frame payload; framing is applied by the transport. */
    suspend fun send(data: ByteArray)

    suspend fun disconnect()

    /** Complete frame payloads from the peer. Completes when the connection ends. */
    fun incomingMessages(): Flow<ByteArray>
}
