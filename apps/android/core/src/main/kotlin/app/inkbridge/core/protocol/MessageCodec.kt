package app.inkbridge.core.protocol

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put

/** A message failed validation. [recoverable] errors may be ignored by the receiver. */
class ProtocolException(message: String, val recoverable: Boolean = false) : Exception(message)

/**
 * JSON encoding and validating decoding of protocol messages.
 *
 * Limits match the Swift host (see docs/protocol/protocol-specification.md);
 * both are tested against protocol/fixtures.
 */
object MessageCodec {
    const val MAX_STRING_LENGTH = 128
    const val MAX_POINTS_PER_MESSAGE = 256
    private val COORDINATE_RANGE = -0.1..1.1

    private val sessionTypes = setOf("session.start", "session.pause", "session.resume", "session.save")

    fun encode(m: Message): ByteArray {
        val obj = buildJsonObject {
            put("version", m.version)
            put("type", m.payload.type)
            put("sequence", m.sequence)
            put("timestamp_ns", m.timestampNs)
            fields(m.payload).forEach { (k, v) -> put(k, v) }
        }
        return obj.toString().encodeToByteArray()
    }

    private fun fields(p: Payload): Map<String, JsonElement> = when (p) {
        is Payload.AuthChallenge -> mapOf("nonce" to JsonPrimitive(p.nonce), "required" to JsonPrimitive(p.required))
        is Payload.Hello -> helloFields(p.hello)
        is Payload.Ready -> mapOf("host_name" to JsonPrimitive(p.hostName), "session_id" to JsonPrimitive(p.sessionId))
        is Payload.Disconnect -> mapOf("reason" to JsonPrimitive(p.reason))
        is Payload.Surface -> mapOf(
            "surface_width_px" to JsonPrimitive(p.widthPx),
            "surface_height_px" to JsonPrimitive(p.heightPx),
        )
        is Payload.StrokeBegin -> mapOf(
            "stroke_id" to JsonPrimitive(p.strokeId),
            "tool" to JsonPrimitive(p.tool.wire),
            "point" to point(p.point),
        )
        is Payload.StrokePoints -> mapOf(
            "stroke_id" to JsonPrimitive(p.strokeId),
            "points" to buildJsonArray { p.points.forEach { add(point(it)) } },
        )
        is Payload.StrokeEnd -> mapOf("stroke_id" to JsonPrimitive(p.strokeId))
        is Payload.StrokeCancel -> mapOf("stroke_id" to JsonPrimitive(p.strokeId))
        is Payload.Session -> p.sessionId?.let { mapOf("session_id" to JsonPrimitive(it)) } ?: emptyMap()
        is Payload.Ping -> mapOf("ping_id" to JsonPrimitive(p.pingId))
        is Payload.Pong -> mapOf("ping_id" to JsonPrimitive(p.pingId), "echo_timestamp_ns" to JsonPrimitive(p.echoTimestampNs))
        is Payload.Error -> mapOf("code" to JsonPrimitive(p.code), "message" to JsonPrimitive(p.message))
    }

    private fun helloFields(h: DeviceHello): Map<String, JsonElement> = buildMap {
        put("device_id", JsonPrimitive(h.deviceId))
        put("device_name", JsonPrimitive(h.deviceName))
        put("model", JsonPrimitive(h.model))
        put("android_api", JsonPrimitive(h.androidApi))
        put("stream_id", JsonPrimitive(h.streamId))
        put("surface_width_px", JsonPrimitive(h.surfaceWidthPx))
        put("surface_height_px", JsonPrimitive(h.surfaceHeightPx))
        put("capabilities", buildJsonObject {
            put("pressure", h.capabilities.pressure)
            put("tilt", h.capabilities.tilt)
            put("eraser", h.capabilities.eraser)
            put("stylus_button", h.capabilities.stylusButton)
        })
        h.auth?.let { put("auth", JsonPrimitive(it)) }
    }

    private fun point(p: InkPoint) = buildJsonObject {
        put("x", p.x)
        put("y", p.y)
        put("p", p.p)
        put("t", p.t)
    }

    fun decode(bytes: ByteArray): Message {
        val root = try {
            Json.parseToJsonElement(bytes.decodeToString())
        } catch (e: Exception) {
            throw ProtocolException("malformed JSON")
        }
        val f = Fields(root as? JsonObject ?: throw ProtocolException("message is not a JSON object"))
        val version = f.int("version")
        if (version != PROTOCOL_VERSION) throw ProtocolException("unsupported protocol version $version")
        val type = f.string("type")
        val sequence = f.long("sequence")
        if (sequence < 0) throw ProtocolException("invalid field sequence")
        return Message(sequence, f.long("timestamp_ns"), payload(type, f), version)
    }

    private fun payload(type: String, f: Fields): Payload = when (type) {
        "auth.challenge" -> Payload.AuthChallenge(f.hex("nonce"), f.bool("required"))
        "device.hello" -> Payload.Hello(hello(f))
        "device.ready" -> Payload.Ready(f.string("host_name"), f.string("session_id"))
        "device.disconnect" -> Payload.Disconnect(f.string("reason"))
        "device.surface" -> Payload.Surface(f.dimension("surface_width_px"), f.dimension("surface_height_px"))
        "stroke.begin" -> Payload.StrokeBegin(
            f.string("stroke_id"),
            Tool.fromWire(f.string("tool")) ?: throw ProtocolException("invalid field tool"),
            point(f.obj("point"), "point"),
        )
        "stroke.point" -> {
            val list = f.array("points")
            if (list.isEmpty() || list.size > MAX_POINTS_PER_MESSAGE) throw ProtocolException("invalid field points")
            Payload.StrokePoints(f.string("stroke_id"), list.map {
                point(it as? JsonObject ?: throw ProtocolException("invalid field points"), "points")
            })
        }
        "stroke.end" -> Payload.StrokeEnd(f.string("stroke_id"))
        "stroke.cancel" -> Payload.StrokeCancel(f.string("stroke_id"))
        in sessionTypes -> Payload.Session(type, f.optionalString("session_id"))
        "connection.ping" -> Payload.Ping(f.nonNegativeLong("ping_id"))
        "connection.pong" -> Payload.Pong(f.nonNegativeLong("ping_id"), f.long("echo_timestamp_ns"))
        "error" -> Payload.Error(f.string("code"), f.string("message", maxLength = 512))
        else -> throw ProtocolException("unknown message type ${type.take(MAX_STRING_LENGTH)}", recoverable = true)
    }

    private fun hello(f: Fields): DeviceHello {
        val caps = Fields(f.obj("capabilities"))
        return DeviceHello(
            deviceId = f.string("device_id"),
            deviceName = f.string("device_name"),
            model = f.string("model"),
            androidApi = f.int("android_api"),
            streamId = f.string("stream_id"),
            surfaceWidthPx = f.dimension("surface_width_px"),
            surfaceHeightPx = f.dimension("surface_height_px"),
            capabilities = Capabilities(caps.bool("pressure"), caps.bool("tilt"), caps.bool("eraser"), caps.bool("stylus_button")),
            auth = f.optionalHex("auth"),
        )
    }

    private fun point(o: JsonObject, field: String): InkPoint {
        val f = Fields(o)
        val x = f.double("x"); val y = f.double("y"); val p = f.double("p")
        val t = (o["t"] as? JsonPrimitive)?.takeIf { !it.isString }?.longOrNull
        if (x == null || y == null || p == null || t == null ||
            x !in COORDINATE_RANGE || y !in COORDINATE_RANGE || p !in 0.0..1.0
        ) throw ProtocolException("invalid field $field")
        return InkPoint(x, y, p, t)
    }
}

/** Validating accessors over a JSON object. */
private class Fields(val obj: JsonObject) {
    private fun prim(key: String): JsonPrimitive {
        val v = obj[key]
        if (v == null || v is JsonNull) throw ProtocolException("missing field $key")
        return v as? JsonPrimitive ?: throw ProtocolException("invalid field $key")
    }

    fun string(key: String, maxLength: Int = MessageCodec.MAX_STRING_LENGTH): String {
        val p = prim(key)
        if (!p.isString || p.content.isEmpty() || p.content.encodeToByteArray().size > maxLength) {
            throw ProtocolException("invalid field $key")
        }
        return p.content
    }

    fun optionalString(key: String): String? =
        if (obj[key] == null || obj[key] is JsonNull) null else string(key)

    fun hex(key: String): String {
        val s = string(key)
        if (s.length % 2 != 0 || !s.all { it.isDigit() || it.lowercaseChar() in 'a'..'f' }) {
            throw ProtocolException("invalid field $key")
        }
        return s.lowercase()
    }

    fun optionalHex(key: String): String? =
        if (obj[key] == null || obj[key] is JsonNull) null else hex(key)

    fun bool(key: String): Boolean {
        val p = prim(key)
        return (if (p.isString) null else p.booleanOrNull) ?: throw ProtocolException("invalid field $key")
    }

    fun int(key: String): Int {
        val p = prim(key)
        return (if (p.isString) null else p.intOrNull) ?: throw ProtocolException("invalid field $key")
    }

    fun long(key: String): Long {
        val p = prim(key)
        return (if (p.isString) null else p.longOrNull) ?: throw ProtocolException("invalid field $key")
    }

    fun nonNegativeLong(key: String): Long =
        long(key).also { if (it < 0) throw ProtocolException("invalid field $key") }

    fun dimension(key: String): Int =
        int(key).also { if (it !in 1..32_768) throw ProtocolException("invalid field $key") }

    fun double(key: String): Double? {
        val p = obj[key] as? JsonPrimitive ?: return null
        if (p.isString || p.booleanOrNull != null) return null
        return p.doubleOrNull?.takeIf { it.isFinite() }
    }

    fun obj(key: String): JsonObject {
        val v = obj[key] ?: throw ProtocolException("missing field $key")
        return v as? JsonObject ?: throw ProtocolException("invalid field $key")
    }

    fun array(key: String): JsonArray {
        val v = obj[key] ?: throw ProtocolException("missing field $key")
        return v as? JsonArray ?: throw ProtocolException("invalid field $key")
    }
}
