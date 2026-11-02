package app.inkbridge.core

import app.inkbridge.core.canvas.CanvasDocument
import app.inkbridge.core.canvas.ToolSettings
import app.inkbridge.core.canvas.ToolSize
import app.inkbridge.core.canvas.ToolSync
import app.inkbridge.core.input.StylusEvent
import app.inkbridge.core.protocol.InkPoint
import app.inkbridge.core.protocol.MessageCodec
import app.inkbridge.core.protocol.Payload
import app.inkbridge.core.protocol.Tool
import app.inkbridge.core.protocol.WireStyle
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.double
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Pen-size model on the tablet: shared limits with the Mac, per-tool memory, optimistic sync. */
class ToolSettingsTest {
    private val config = Json.parseToJsonElement(String(Fixtures.bytes("tool-sizes.json"))).jsonObject

    @Test
    fun limitsAndPresetsMatchSharedFixture() {
        val tools = config["tools"]!!.jsonObject
        assertEquals(ToolSize.entries.map { it.tool.wire }.toSet(), tools.keys)
        for (spec in ToolSize.entries) {
            val t = tools[spec.tool.wire]!!.jsonObject
            assertEquals(t["default"]!!.jsonPrimitive.double, spec.default, spec.name)
            assertEquals(t["min"]!!.jsonPrimitive.double, spec.min, spec.name)
            assertEquals(t["max"]!!.jsonPrimitive.double, spec.max, spec.name)
            assertEquals(t["presets"]!!.jsonArray.map { it.jsonPrimitive.double }, spec.presets, spec.name)
        }
    }

    @Test
    fun stepVectorsMatchSharedFixture() {
        for (e in config["steps"]!!.jsonArray) {
            val o = e as JsonObject
            val spec = ToolSize.of(Tool.fromWire(o["tool"]!!.jsonPrimitive.content)!!)!!
            val from = o["from"]!!.jsonPrimitive.double
            assertEquals(o["up"]!!.jsonPrimitive.double, spec.step(from, up = true), "$spec $from up")
            assertEquals(o["down"]!!.jsonPrimitive.double, spec.step(from, up = false), "$spec $from down")
        }
    }

    @Test
    fun eachToolRemembersItsSize() {
        var s = ToolSettings().copy(tool = Tool.PEN).withSize(Tool.PEN, 2.0)
        s = s.copy(tool = Tool.HIGHLIGHTER).withSize(Tool.HIGHLIGHTER, 12.0)
        s = s.copy(tool = Tool.PEN)
        assertEquals(2.0, s.size(Tool.PEN))
        assertEquals(12.0, s.size(Tool.HIGHLIGHTER))
        assertNull(s.size(Tool.LASER))
        assertEquals(24.0, s.withSize(Tool.PEN, 99.0).pen)
        assertEquals(ToolSize.PEN.default, ToolSettings(pen = Double.NaN).clamped().pen)
    }

    @Test
    fun wireRoundTrip() {
        val st = MessageCodec.decode(Fixtures.bytes("valid/tool.state.json"))
        val p = st.payload as Payload.ToolState
        assertEquals(ToolSettings(Tool.HIGHLIGHTER, 4.5, 36.0, 28.0), p.settings)
        assertEquals(7, p.revision); assertEquals(3, p.ack)
        val rq = MessageCodec.decode(Fixtures.bytes("valid/tool.request.json")).payload as Payload.ToolRequest
        assertEquals(Payload.ToolRequest(4, Tool.PEN, mapOf(Tool.PEN to 5.0)), rq)
    }

    /** A slider drag: replies to superseded steps must not make the control jump back. */
    @Test
    fun staleRepliesAreSkippedLatestIsAdopted() {
        val sync = ToolSync(ToolSettings())
        sync.edit(ToolSettings().withSize(Tool.PEN, 5.0), false, Tool.PEN)
        val r2 = sync.edit(ToolSettings().withSize(Tool.PEN, 6.0), false, Tool.PEN)
        assertEquals(mapOf(Tool.PEN to 6.0), r2.sizes)
        assertNull(r2.tool)
        assertFalse(sync.receive(Payload.ToolState(ToolSettings().withSize(Tool.PEN, 5.0), 1, ack = 1)))
        assertEquals(6.0, sync.settings.pen)
        // The Mac changed the highlighter meanwhile; the reply to our last edit merges both.
        val merged = ToolSettings().withSize(Tool.PEN, 6.0).withSize(Tool.HIGHLIGHTER, 50.0)
        assertTrue(sync.receive(Payload.ToolState(merged, 2, ack = 2)))
        assertEquals(merged, sync.settings)
        // Later Mac-only changes are adopted.
        assertTrue(sync.receive(Payload.ToolState(merged.copy(tool = Tool.ERASER), 3, ack = 2)))
        assertEquals(Tool.ERASER, sync.settings.tool)
    }

    /** New local ink uses the selected tool at once; the hardware eraser always erases. */
    @Test
    fun localInkUsesSelectedToolAndSize() {
        val doc = CanvasDocument()
        val pt = InkPoint(1.0, 1.0, 1.0, 1)
        doc.applyLocal(StylusEvent.Begin("a", Tool.PEN, pt), WireStyle(0, 36.0), Tool.HIGHLIGHTER)
        doc.applyLocal(StylusEvent.Begin("b", Tool.ERASER, pt), WireStyle(0, 28.0), Tool.PEN)
        val tools = doc.read { all -> all.associate { it.id to (it.tool to it.style.width) } }
        assertEquals(Tool.HIGHLIGHTER to 36.0, tools["a"])
        assertEquals(Tool.ERASER, tools["b"]!!.first)
    }

    /** Changing the size later never touches a stroke already written. */
    @Test
    fun sizeChangeDoesNotRestyleExistingStrokes() {
        val doc = CanvasDocument()
        val pt = InkPoint(1.0, 1.0, 1.0, 1)
        var s = ToolSettings().withSize(Tool.PEN, 2.0)
        doc.applyLocal(StylusEvent.Begin("a", Tool.PEN, pt), WireStyle(0, s.pen), s.tool)
        doc.applyLocal(StylusEvent.End("a"), WireStyle(0, 0.0))
        s = s.withSize(Tool.PEN, 11.0)
        doc.applyLocal(StylusEvent.Begin("b", Tool.PEN, pt), WireStyle(0, s.pen), s.tool)
        assertEquals(listOf(2.0, 11.0), doc.read { all -> all.sortedBy { it.id }.map { it.style.width } })
    }

    /** Regression (found on hardware): after a Mac restart its acks restart at 0 and the tablet ignored it forever. */
    @Test
    fun macRestartIsAdoptedAfterReconnect() {
        val sync = ToolSync(ToolSettings())
        sync.edit(ToolSettings().withSize(Tool.PEN, 11.0), false, Tool.PEN)
        assertTrue(sync.receive(Payload.ToolState(ToolSettings().withSize(Tool.PEN, 11.0), 5, ack = 1)) || sync.settings.pen == 11.0)
        // Mac restarts with pen 7; its first state (ack 0) may arrive before the Ready callback.
        val restarted = Payload.ToolState(ToolSettings().withSize(Tool.PEN, 7.0), 1, ack = 0)
        assertFalse(sync.receive(restarted))
        assertNull(sync.connected(), "everything was acknowledged: nothing to re-send")
        assertTrue(sync.adoptLatest())
        assertEquals(7.0, sync.settings.pen)
        // And later Mac states are adopted normally (acks stay at 0 after a restart).
        assertTrue(sync.receive(Payload.ToolState(ToolSettings().withSize(Tool.PEN, 8.0), 2, ack = 0)))
    }

    /** An offline size edit is re-sent with only that field, so it cannot clobber the Mac's other sizes. */
    @Test
    fun unacknowledgedEditIsResentOnReconnectWithoutClobbering() {
        val sync = ToolSync(ToolSettings())
        sync.edit(ToolSettings().withSize(Tool.PEN, 9.0), false, Tool.PEN)  // offline
        val req = sync.connected()!!
        assertEquals(mapOf(Tool.PEN to 9.0), req.sizes)
        assertNull(req.tool, "only the pen size changed")
        // The Mac's connect-time state (its own older value) is not adopted…
        assertFalse(sync.receive(Payload.ToolState(ToolSettings().withSize(Tool.PEN, 7.0), 1, ack = 0)))
        assertEquals(9.0, sync.settings.pen)
        // …the reply to the request is.
        sync.receive(Payload.ToolState(ToolSettings().withSize(Tool.PEN, 9.0), 2, ack = req.seq))
        assertEquals(9.0, sync.settings.pen)
        assertNull(sync.connected())
    }

    /** A slider preview must survive a tool switch: the size is committed with the new tool. */
    @Test
    fun previewSurvivesToolSwitch() {
        val sync = ToolSync(ToolSettings())
        sync.preview(ToolSettings().withSize(Tool.PEN, 10.0), Tool.PEN)
        assertEquals(10.0, sync.settings.pen)
        val req = sync.edit(sync.settings.copy(tool = Tool.HIGHLIGHTER), toolChanged = true, sizeOf = sync.pendingSize())
        assertEquals(Tool.HIGHLIGHTER, req.tool)
        assertEquals(mapOf(Tool.PEN to 10.0), req.sizes)
        assertEquals(10.0, sync.settings.pen)
    }

    /** After reconnect, a late Mac state with an old ack must not overwrite a new local edit. */
    @Test
    fun staleAckAfterReconnectDoesNotRevertNewEdit() {
        val sync = ToolSync(ToolSettings())
        sync.edit(ToolSettings().withSize(Tool.PEN, 7.0), false, Tool.PEN)
        sync.receive(Payload.ToolState(ToolSettings().withSize(Tool.PEN, 7.0), 1, ack = 1))
        assertNull(sync.connected())
        sync.adoptLatest() // no-op without a newer state; re-baselines to ack 1
        sync.edit(ToolSettings().withSize(Tool.PEN, 9.0), false, Tool.PEN)
        assertFalse(sync.receive(Payload.ToolState(ToolSettings().withSize(Tool.PEN, 7.0), 1, ack = 1)))
        assertEquals(9.0, sync.settings.pen)
    }
}
