package app.inkbridge.core.protocol

/** The protocol version this build speaks. */
const val PROTOCOL_VERSION = 1

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
 * One stylus sample in normalized surface coordinates: [x], [y] in 0..1 with
 * the origin at the top-left, [p] pressure in 0..1, [t] sample time in ns on
 * the device's monotonic clock.
 */
data class InkPoint(val x: Double, val y: Double, val p: Double, val t: Long)

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
    /** Hex HMAC-SHA256 of the challenge nonce keyed by the pairing code. */
    val auth: String?,
)

/** The typed body of a message. [type] is the wire name. */
sealed interface Payload {
    val type: String

    data class AuthChallenge(val nonce: String, val required: Boolean) : Payload {
        override val type get() = "auth.challenge"
    }
    data class Hello(val hello: DeviceHello) : Payload {
        override val type get() = "device.hello"
    }
    data class Ready(val hostName: String, val sessionId: String) : Payload {
        override val type get() = "device.ready"
    }
    data class Disconnect(val reason: String) : Payload {
        override val type get() = "device.disconnect"
    }
    data class Surface(val widthPx: Int, val heightPx: Int) : Payload {
        override val type get() = "device.surface"
    }
    data class StrokeBegin(val strokeId: String, val tool: Tool, val point: InkPoint) : Payload {
        override val type get() = "stroke.begin"
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
