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
    const val MAX_IDS_PER_MESSAGE = 256
    /** Canvas px are unbounded in principle; the cap keeps rendering math finite. */
    private val COORDINATE_RANGE = -1e7..1e7
    private val WIDTH_RANGE = 0.01..10_000.0

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
        is Payload.AuthChallenge -> mapOf(
            "nonce" to JsonPrimitive(p.nonce),
            "required" to JsonPrimitive(p.required),
            "host_id" to JsonPrimitive(p.hostId),
        )
        is Payload.Hello -> helloFields(p.hello)
        is Payload.Ready -> mapOf(
            "host_name" to JsonPrimitive(p.hostName),
            "session_id" to JsonPrimitive(p.sessionId),
            "host_id" to JsonPrimitive(p.hostId),
            "resume_sequence" to JsonPrimitive(p.resumeSequence),
        )
        is Payload.PairGranted -> mapOf(
            "host_id" to JsonPrimitive(p.hostId),
            "host_name" to JsonPrimitive(p.hostName),
            "token" to JsonPrimitive(p.token),
            "proof" to JsonPrimitive(p.proof),
        )
        is Payload.Disconnect -> mapOf("reason" to JsonPrimitive(p.reason))
        is Payload.Surface -> mapOf(
            "surface_width_px" to JsonPrimitive(p.widthPx),
            "surface_height_px" to JsonPrimitive(p.heightPx),
        )
        is Payload.StrokeBegin -> buildMap {
            put("stroke_id", JsonPrimitive(p.strokeId))
            put("tool", JsonPrimitive(p.tool.wire))
            put("point", point(p.point))
            p.style?.let { put("style", style(it)) }
        }
        is Payload.StrokeStyle -> mapOf(
            "stroke_id" to JsonPrimitive(p.strokeId),
            "tool" to JsonPrimitive(p.tool.wire),
            "style" to style(p.style),
        )
        is Payload.CanvasViewport -> mapOf(
            "x" to JsonPrimitive(p.viewport.x),
            "y" to JsonPrimitive(p.viewport.y),
            "zoom" to JsonPrimitive(p.viewport.zoom),
        )
        is Payload.Background -> mapOf(
            "mode" to JsonPrimitive(p.background.mode.wire),
            "color" to JsonPrimitive(Colors.toHex(p.background.argb)),
            "pattern" to JsonPrimitive(p.background.pattern.wire),
            "revision" to JsonPrimitive(p.revision),
        )
        is Payload.Diagram -> mapOf(
            "revision" to JsonPrimitive(p.revision),
            "nodes" to buildJsonArray {
                p.diagram.nodes.forEach { n ->
                    add(buildJsonObject {
                        put("id", n.id); put("kind", n.kind); put("label", n.label); put("shape", n.shape)
                        put("x", n.x); put("y", n.y); put("w", n.w); put("h", n.h)
                    })
                }
            },
            "edges" to buildJsonArray {
                p.diagram.edges.forEach { e ->
                    add(buildJsonObject {
                        put("id", e.id); put("from", e.from); put("to", e.to); put("kind", e.kind); put("style", e.style)
                        put("label", e.label); put("dashed", e.dashed)
                        put("points", buildJsonArray { e.points.forEach { add(JsonPrimitive(it)) } })
                    })
                }
            },
        )
        is Payload.Journal -> mapOf(
            "active" to JsonPrimitive(p.active), "day" to JsonPrimitive(p.day), "today" to JsonPrimitive(p.today),
            "title" to JsonPrimitive(p.title), "revision" to JsonPrimitive(p.revision),
            "entries" to buildJsonArray {
                p.entries.forEach { e ->
                    add(buildJsonObject {
                        put("id", e.id); put("kind", e.kind); put("text", e.text); put("done", e.done); put("created_ms", e.createdMs)
                    })
                }
            },
        )
        is Payload.JournalRequest -> buildMap {
            put("action", JsonPrimitive(p.action))
            p.name?.let { put("name", JsonPrimitive(it)) }
        }
        is Payload.Storage -> buildMap {
            val st = p.state
            put("project", JsonPrimitive(st.project)); put("session", JsonPrimitive(st.session))
            put("location", JsonPrimitive(st.location)); put("status", JsonPrimitive(st.status))
            put("saved_at_ms", JsonPrimitive(st.savedAtMs)); put("revision", JsonPrimitive(st.revision))
            st.error?.let { put("error", JsonPrimitive(it)) }
            put("projects", buildJsonArray { st.projects.forEach { add(JsonPrimitive(it)) } })
            put("locations", buildJsonArray { st.locations.forEach { add(JsonPrimitive(it)) } })
        }
        is Payload.StorageRequest -> buildMap {
            put("action", JsonPrimitive(p.action))
            p.name?.let { put("name", JsonPrimitive(it)) }
        }
        is Payload.Command -> mapOf("command" to JsonPrimitive(p.command.wire))
        is Payload.DocReset -> emptyMap()
        is Payload.DocRemove -> mapOf("stroke_ids" to buildJsonArray { p.strokeIds.forEach { add(JsonPrimitive(it)) } })
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
        h.authMode?.let { put("auth_mode", JsonPrimitive(it.wire)) }
    }

    private fun style(s: WireStyle) = buildJsonObject {
        put("color", Colors.toHex(s.argb))
        put("width", s.width)
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
        "auth.challenge" -> Payload.AuthChallenge(f.hex("nonce"), f.bool("required"), f.string("host_id"))
        "device.hello" -> Payload.Hello(hello(f))
        "device.ready" -> Payload.Ready(f.string("host_name"), f.string("session_id"), f.string("host_id"), f.nonNegativeLong("resume_sequence"))
        "pair.granted" -> Payload.PairGranted(f.string("host_id"), f.string("host_name"), f.hex("token"), f.hex("proof"))
        "device.disconnect" -> Payload.Disconnect(f.string("reason"))
        "device.surface" -> Payload.Surface(f.dimension("surface_width_px"), f.dimension("surface_height_px"))
        "stroke.begin" -> Payload.StrokeBegin(
            f.string("stroke_id"),
            f.tool("tool"),
            point(f.obj("point"), "point"),
            f.optionalObj("style")?.let(::style),
        )
        "stroke.style" -> Payload.StrokeStyle(f.string("stroke_id"), f.tool("tool"), style(f.obj("style")))
        "canvas.viewport" -> {
            val x = f.double("x"); val y = f.double("y"); val z = f.double("zoom")
            if (x == null || y == null || z == null || x !in COORDINATE_RANGE || y !in COORDINATE_RANGE ||
                z !in app.inkbridge.core.canvas.Viewport.ZOOM_RANGE
            ) throw ProtocolException("invalid field viewport")
            Payload.CanvasViewport(app.inkbridge.core.canvas.Viewport(x, y, z))
        }
        "canvas.background" -> Payload.Background(
            app.inkbridge.core.canvas.CanvasBackground(
                app.inkbridge.core.canvas.CanvasBackground.Mode.fromWire(f.string("mode")) ?: throw ProtocolException("invalid field mode"),
                Colors.fromHex(f.string("color")) ?: throw ProtocolException("invalid field color"),
                app.inkbridge.core.canvas.CanvasBackground.Pattern.fromWire(f.string("pattern")) ?: throw ProtocolException("invalid field pattern"),
            ),
            f.nonNegativeLong("revision"),
        )
        "diagram.state" -> Payload.Diagram(diagram(f), f.nonNegativeLong("revision"))
        "journal.state" -> Payload.Journal(
            f.bool("active"), f.label("day"), f.bool("today"), f.label("title"),
            f.array("entries").take(100).map { e ->
                val o = Fields(e as? JsonObject ?: throw ProtocolException("invalid field entries"))
                val kind = o.string("kind").also { if (it !in setOf("note", "task", "ink")) throw ProtocolException("invalid field entries") }
                JournalItem(o.string("id"), kind, o.label("text"), o.bool("done"), o.long("created_ms"))
            },
            f.nonNegativeLong("revision"),
        )
        "journal.request" -> Payload.JournalRequest(
            f.string("action").also {
                if (it !in setOf("open", "close", "today", "prev", "next", "day", "add_note", "add_task")) throw ProtocolException("invalid field action")
            },
            f.optionalString("name"),
        )
        "storage.state" -> Payload.Storage(StorageState(
            f.string("project"), f.string("session"), f.string("location"),
            f.string("status").also { if (it !in setOf("empty", "saved", "saving", "unsaved", "failed")) throw ProtocolException("invalid field status") },
            f.long("saved_at_ms"), f.optionalString("error"),
            f.stringArray("projects"), f.stringArray("locations"), f.nonNegativeLong("revision"),
        ))
        "storage.request" -> Payload.StorageRequest(
            f.string("action").also {
                if (it !in setOf("save_now", "new_session", "switch_project", "create_project", "use_location")) throw ProtocolException("invalid field action")
            },
            f.optionalString("name"),
        )
        "canvas.command" -> Payload.Command(
            CanvasCommand.fromWire(f.string("command")) ?: throw ProtocolException("invalid field command"),
        )
        "doc.reset" -> Payload.DocReset
        "doc.remove" -> {
            val list = f.array("stroke_ids")
            if (list.isEmpty() || list.size > MAX_IDS_PER_MESSAGE) throw ProtocolException("invalid field stroke_ids")
            Payload.DocRemove(list.map {
                val prim = it as? JsonPrimitive
                if (prim == null || !prim.isString || prim.content.isEmpty() || prim.content.length > MAX_STRING_LENGTH) {
                    throw ProtocolException("invalid field stroke_ids")
                }
                prim.content
            })
        }
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

    private fun diagram(f: Fields): app.inkbridge.core.canvas.DiagramSnapshot {
        fun obj(e: JsonElement, key: String) = Fields(e as? JsonObject ?: throw ProtocolException("invalid field $key"))
        val nodes = f.array("nodes").take(MAX_IDS_PER_MESSAGE).map { e ->
            val n = obj(e, "nodes")
            val x = n.double("x"); val y = n.double("y"); val w = n.double("w"); val h = n.double("h")
            if (x == null || y == null || w == null || h == null || w <= 0 || h <= 0 || x !in COORDINATE_RANGE || y !in COORDINATE_RANGE) {
                throw ProtocolException("invalid field nodes")
            }
            app.inkbridge.core.canvas.DiagramSnapshot.Node(n.string("id"), n.string("kind"), n.label("label"), n.string("shape"), x, y, w, h)
        }
        val edges = f.array("edges").take(MAX_IDS_PER_MESSAGE).map { e ->
            val o = obj(e, "edges")
            val pts = o.array("points").map { v ->
                ((v as? JsonPrimitive)?.doubleOrNull ?: throw ProtocolException("invalid field points")).also {
                    if (it !in COORDINATE_RANGE) throw ProtocolException("invalid field points")
                }
            }
            if (pts.size % 2 != 0 || pts.size > 200) throw ProtocolException("invalid field points")
            app.inkbridge.core.canvas.DiagramSnapshot.Edge(o.string("id"), o.string("from"), o.string("to"), o.string("kind"),
                o.string("style"), o.label("label"), o.bool("dashed"), pts)
        }
        return app.inkbridge.core.canvas.DiagramSnapshot(nodes, edges)
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
            authMode = f.optionalString("auth_mode")?.let { AuthMode.fromWire(it) ?: throw ProtocolException("invalid field auth_mode") },
        )
    }

    private fun style(o: JsonObject): WireStyle {
        val f = Fields(o)
        val argb = Colors.fromHex(f.string("color")) ?: throw ProtocolException("invalid field style")
        val w = f.double("width")
        if (w == null || w !in WIDTH_RANGE) throw ProtocolException("invalid field style")
        return WireStyle(argb, w)
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

    fun optionalObj(key: String): JsonObject? =
        if (obj[key] == null || obj[key] is JsonNull) null else obj(key)

    fun tool(key: String): Tool = Tool.fromWire(string(key)) ?: throw ProtocolException("invalid field $key")

    /** Like [string] but allows "" and up to 512 bytes (labels in any script). */
    fun label(key: String): String {
        val p = prim(key)
        if (!p.isString || p.content.encodeToByteArray().size > 512) throw ProtocolException("invalid field $key")
        return p.content
    }

    fun stringArray(key: String): List<String> {
        val a = array(key)
        if (a.size > MessageCodec.MAX_IDS_PER_MESSAGE) throw ProtocolException("invalid field $key")
        return a.map { e ->
            val p = e as? JsonPrimitive ?: throw ProtocolException("invalid field $key")
            if (!p.isString || p.content.length > MessageCodec.MAX_STRING_LENGTH) throw ProtocolException("invalid field $key")
            p.content
        }
    }

    fun array(key: String): JsonArray {
        val v = obj[key] ?: throw ProtocolException("missing field $key")
        return v as? JsonArray ?: throw ProtocolException("invalid field $key")
    }
}
