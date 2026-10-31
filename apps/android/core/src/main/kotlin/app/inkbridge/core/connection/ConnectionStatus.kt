package app.inkbridge.core.connection

import app.inkbridge.core.client.ClientState
import app.inkbridge.core.client.FailureKind
import app.inkbridge.core.transport.TransportKind

/** How the tablet reaches the Mac. Wi-Fi is the default; USB needs a cable and adb. */
enum class ConnectionMode { WIFI, USB }

/**
 * The unified connection stage shown to people, in the order a first
 * connection passes through them:
 *
 *     NOT_PAIRED → DISCOVERING → FOUND → PAIRING → AUTHENTICATING → CONNECTED
 *                                   ↑                                   │ link lost
 *                                   └──────────── RECONNECTING ◀────────┘
 *
 * plus CONNECTING (USB, or a paired Mac whose address is known),
 * DISCONNECTED (the user pressed Disconnect) and FAILED (needs the user:
 * wrong code, Mac forgot us, certificate changed).
 */
enum class Stage { NOT_PAIRED, DISCONNECTED, DISCOVERING, FOUND, CONNECTING, PAIRING, AUTHENTICATING, CONNECTED, RECONNECTING, FAILED }

/** What the main screen's single most important button does. */
enum class PrimaryAction { CONNECT_TO_MAC, OPEN_CANVAS, RETRY, PAIR_AGAIN }

enum class Tone { GOOD, BUSY, NEUTRAL, PROBLEM }

/** Everything the UI needs to show the connection, already worded. */
data class StatusView(
    val stage: Stage,
    val title: String,
    val detail: String,
    val tone: Tone,
    val primary: PrimaryAction,
    /** Short form for the canvas's status chip. */
    val chip: String,
)

/** Inputs to [ConnectionStatus.describe]; all plain data so the mapping is testable. */
data class ConnectionFacts(
    val mode: ConnectionMode,
    /** The paired Mac's name, if any (Wi-Fi). */
    val pairedMac: String?,
    /** A pairing code is being tried right now. */
    val pairingInProgress: Boolean,
    /** Macs found by discovery right now. */
    val discovered: Int,
    val client: ClientState?,
    val rttMs: Double?,
    /** Whether a connection has succeeded since the app started (drives "Reconnecting"). */
    val wasConnected: Boolean,
    /** The user disconnected on purpose. */
    val paused: Boolean = false,
)

object ConnectionStatus {
    fun describe(f: ConnectionFacts): StatusView {
        val c = f.client
        val via = if (f.mode == ConnectionMode.USB) "USB" else "Wi-Fi"
        return when {
            c is ClientState.Ready -> StatusView(
                Stage.CONNECTED, "Connected to ${c.hostName}",
                "$via" + (f.rttMs?.let { " · %.0f ms".format(it) } ?: "") + " · Ready to draw",
                Tone.GOOD, PrimaryAction.OPEN_CANVAS, "${c.hostName} · $via",
            )
            c is ClientState.Failed -> failed(c)
            f.paused -> StatusView(
                Stage.DISCONNECTED, "Disconnected",
                f.pairedMac?.let { "Paired with $it. Connect when you want to draw on the Mac." } ?: "Connect when you want to draw on the Mac.",
                Tone.NEUTRAL, PrimaryAction.CONNECT_TO_MAC, "Disconnected",
            )
            c is ClientState.Authenticating -> StatusView(
                if (c.pairing) Stage.PAIRING else Stage.AUTHENTICATING,
                if (c.pairing) "Pairing…" else "Connecting…",
                if (c.pairing) "Checking the code with the Mac" else "Verifying ${f.pairedMac ?: "the Mac"}",
                Tone.BUSY, PrimaryAction.OPEN_CANVAS, "Connecting…",
            )
            f.mode == ConnectionMode.WIFI && f.pairedMac == null && !f.pairingInProgress -> when (f.discovered) {
                0 -> StatusView(
                    Stage.NOT_PAIRED, "Not connected",
                    "Connect this tablet to your Mac over Wi-Fi to start drawing.",
                    Tone.NEUTRAL, PrimaryAction.CONNECT_TO_MAC, "Not connected",
                )
                else -> StatusView(
                    Stage.FOUND, "Mac found",
                    if (f.discovered == 1) "One Mac with InkBridge is on this network." else "${f.discovered} Macs with InkBridge are on this network.",
                    Tone.NEUTRAL, PrimaryAction.CONNECT_TO_MAC, "Not connected",
                )
            }
            f.wasConnected && (c is ClientState.Retrying || c is ClientState.Connecting) -> StatusView(
                Stage.RECONNECTING, "Reconnecting…",
                (c as? ClientState.Retrying)?.let { "Connection lost: ${plain(it.reason)}" } ?: "Connection lost; trying again",
                Tone.BUSY, PrimaryAction.OPEN_CANVAS, "Reconnecting…",
            )
            c is ClientState.Retrying -> StatusView(
                if (f.mode == ConnectionMode.WIFI) Stage.DISCOVERING else Stage.CONNECTING,
                if (f.mode == ConnectionMode.WIFI) "Looking for ${f.pairedMac ?: "your Mac"}…" else "Waiting for the Mac over USB…",
                if (f.mode == ConnectionMode.WIFI) "Make sure InkBridge is running on the Mac and both are on the same Wi-Fi."
                else "Connect the cable, then run adb reverse tcp:8765 tcp:8765 on the Mac.",
                Tone.BUSY, PrimaryAction.OPEN_CANVAS, "Searching…",
            )
            else -> StatusView(
                Stage.CONNECTING, "Connecting…", "Reaching ${f.pairedMac ?: "the Mac"} over $via",
                Tone.BUSY, PrimaryAction.OPEN_CANVAS, "Connecting…",
            )
        }
    }

    private fun failed(c: ClientState.Failed): StatusView = when (c.kind) {
        FailureKind.WRONG_CODE -> StatusView(Stage.FAILED, "Wrong code", "Check the code shown on the Mac and try again.",
            Tone.PROBLEM, PrimaryAction.PAIR_AGAIN, "Not connected")
        FailureKind.PAIRING_CLOSED -> StatusView(Stage.FAILED, "Code expired",
            "On the Mac, open InkBridge → Connect Device for a new code.", Tone.PROBLEM, PrimaryAction.PAIR_AGAIN, "Not connected")
        FailureKind.NOT_PAIRED -> StatusView(Stage.FAILED, "Pair again", "The Mac no longer recognises this tablet.",
            Tone.PROBLEM, PrimaryAction.PAIR_AGAIN, "Not paired")
        FailureKind.IDENTITY_CHANGED -> StatusView(Stage.FAILED, "Mac identity changed",
            "This Mac's security certificate is not the one this tablet paired with. If you reinstalled InkBridge on the Mac, pair again.",
            Tone.PROBLEM, PrimaryAction.PAIR_AGAIN, "Not connected")
        FailureKind.PROTOCOL -> StatusView(Stage.FAILED, "Connection failed", plain(c.reason),
            Tone.PROBLEM, PrimaryAction.RETRY, "Not connected")
    }

    /** Socket error text is for diagnostics; people get a short version. */
    fun plain(reason: String): String = when {
        reason.contains("ECONNREFUSED") || reason.contains("refused") -> "the Mac isn't accepting connections"
        reason.contains("timed out") || reason.contains("timeout") || reason.contains("silent") -> "no answer from the Mac"
        reason.contains("ENETUNREACH") || reason.contains("unreachable") -> "no network"
        reason.contains("different Mac") -> "a different Mac answered at this address"
        reason.contains("closed") || reason.contains("reset") -> "the connection closed"
        else -> reason.take(80)
    }

    fun transportLabel(kind: TransportKind) = if (kind == TransportKind.USB) "USB" else "Wi-Fi"
}
