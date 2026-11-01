package app.inkbridge.core.protocol

/** The protocol version this build speaks. */
const val PROTOCOL_VERSION = 3

/** The tool a stroke is drawn with. The device sends only [PEN] or [ERASER]. */
enum class Tool(val wire: String) {
    PEN("pen"),
    HIGHLIGHTER("highlighter"),
    ERASER("eraser"),
    LASER("laser");

    companion object {
        fun fromWire(s: String): Tool? = entries.firstOrNull { it.wire == s }
    }
}

/**
 * One stylus sample in **canvas coordinates** (canvas px: 1 unit = 1 tablet
 * pixel at zoom 1, unbounded, y down; ADR-006). [p] is pressure 0..1, [t]
 * the sample time in ns on the device's monotonic clock.
 */
data class InkPoint(val x: Double, val y: Double, val p: Double, val t: Long)

/** Stroke look on the wire: ARGB color and width in canvas px. */
data class WireStyle(val argb: Int, val width: Double)

/** Document commands the tablet can ask the Mac to perform. */
enum class CanvasCommand(val wire: String) {
    UNDO("undo"), REDO("redo"), CLEAR("clear");

    companion object {
        fun fromWire(s: String): CanvasCommand? = entries.firstOrNull { it.wire == s }
    }
}

data class Capabilities(
    val pressure: Boolean,
    val tilt: Boolean,
    val eraser: Boolean,
    val stylusButton: Boolean,
)

data class DeviceHello(
    val deviceId: String,
    val deviceName: String,
    val model: String,
    val androidApi: Int,
    /** Random per process; sequence numbers are scoped to it. */
    val streamId: String,
    val surfaceWidthPx: Int,
    val surfaceHeightPx: Int,
    val capabilities: Capabilities,
    /** Hex HMAC-SHA256 proof over the challenge (see [PairingAuth]). */
    val auth: String?,
    /** Which secret [auth] is keyed with; null when no proof is sent. */
    val authMode: AuthMode? = null,
)

/** First contact proves the Connect Device code; afterwards, the device token. */
enum class AuthMode(val wire: String) {
    PAIR("pair"), TOKEN("token");

    companion object {
        fun fromWire(s: String): AuthMode? = entries.firstOrNull { it.wire == s }
    }
}

/** The typed body of a message. [type] is the wire name. */
sealed interface Payload {
    val type: String

    /** [hostId] is the Mac's stable identity. */
    data class AuthChallenge(val nonce: String, val required: Boolean, val hostId: String) : Payload {
        override val type get() = "auth.challenge"
    }
    data class Hello(val hello: DeviceHello) : Payload {
        override val type get() = "device.hello"
    }
    /**
     * [resumeSequence]: the highest sequence the Mac already holds for this
     * stream. The device re-sends what it sent after that on a dead link.
     */
    data class Ready(val hostName: String, val sessionId: String, val hostId: String, val resumeSequence: Long) : Payload {
        override val type get() = "device.ready"
    }
    /** Host → device after a correct pairing code: the device token and the Mac's own proof. */
    data class PairGranted(val hostId: String, val hostName: String, val token: String, val proof: String) : Payload {
        override val type get() = "pair.granted"
    }
    data class Disconnect(val reason: String) : Payload {
        override val type get() = "device.disconnect"
    }
    data class Surface(val widthPx: Int, val heightPx: Int) : Payload {
        override val type get() = "device.surface"
    }
    /** [style] is set on host→device strokes; the device omits it. */
    data class StrokeBegin(val strokeId: String, val tool: Tool, val point: InkPoint, val style: WireStyle? = null) : Payload {
        override val type get() = "stroke.begin"
    }
    /** Host → device: how the host resolved a device stroke. */
    data class StrokeStyle(val strokeId: String, val tool: Tool, val style: WireStyle) : Payload {
        override val type get() = "stroke.style"
    }
    /** Either direction: the view of the canvas moved. */
    data class CanvasViewport(val viewport: app.inkbridge.core.canvas.Viewport) : Payload {
        override val type get() = "canvas.viewport"
    }
    /**
     * Either direction: the background layer. Host → device carries the
     * Mac's revision (apply only if newer); device → host is a request the
     * Mac applies and echoes with a new revision.
     */
    data class Background(val background: app.inkbridge.core.canvas.CanvasBackground, val revision: Long) : Payload {
        override val type get() = "canvas.background"
    }
    /** Host → device: the engineering diagram (whole snapshot, routes included). */
    data class Diagram(val diagram: app.inkbridge.core.canvas.DiagramSnapshot, val revision: Long) : Payload {
        override val type get() = "diagram.state"
    }
    /** Host → device: what the Mac is saving to and how it is going (paths are display strings). */
    data class Storage(val state: StorageState) : Payload {
        override val type get() = "storage.state"
    }
    /** Device → host: save_now, new_session, switch_project, create_project, use_location. */
    data class StorageRequest(val action: String, val name: String? = null) : Payload {
        override val type get() = "storage.request"
    }
    data class Command(val command: CanvasCommand) : Payload {
        override val type get() = "canvas.command"
    }
    /** Host → device: drop every confirmed stroke before a full resync. */
    data object DocReset : Payload {
        override val type get() = "doc.reset"
    }
    data class DocRemove(val strokeIds: List<String>) : Payload {
        override val type get() = "doc.remove"
    }
    data class StrokePoints(val strokeId: String, val points: List<InkPoint>) : Payload {
        override val type get() = "stroke.point"
    }
    data class StrokeEnd(val strokeId: String) : Payload {
        override val type get() = "stroke.end"
    }
    data class StrokeCancel(val strokeId: String) : Payload {
        override val type get() = "stroke.cancel"
    }
    data class Session(override val type: String, val sessionId: String?) : Payload
    data class Ping(val pingId: Long) : Payload {
        override val type get() = "connection.ping"
    }
    data class Pong(val pingId: Long, val echoTimestampNs: Long) : Payload {
        override val type get() = "connection.pong"
    }
    data class Error(val code: String, val message: String) : Payload {
        override val type get() = "error"
    }
}

/** A complete message: envelope plus payload. */
data class Message(
    val sequence: Long,
    val timestampNs: Long,
    val payload: Payload,
    val version: Int = PROTOCOL_VERSION,
)

/** Mirror of StorageState.swift. The Mac owns storage; the tablet only shows it and asks. */
data class StorageState(
    val project: String,
    val session: String,
    val location: String,
    val status: String,
    val savedAtMs: Long,
    val error: String?,
    val projects: List<String>,
    val locations: List<String>,
    val revision: Long,
)
