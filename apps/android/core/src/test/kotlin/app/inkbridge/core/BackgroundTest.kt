package app.inkbridge.core

import app.inkbridge.core.canvas.CanvasBackground
import app.inkbridge.core.canvas.CanvasBackground.Pattern
import app.inkbridge.core.canvas.CanvasDocument
import app.inkbridge.core.input.StylusEvent
import app.inkbridge.core.protocol.InkPoint
import app.inkbridge.core.protocol.MessageCodec
import app.inkbridge.core.protocol.Payload
import app.inkbridge.core.protocol.ProtocolException
import app.inkbridge.core.protocol.Tool
import app.inkbridge.core.protocol.WireStyle
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class BackgroundTest {
    @Test
    fun sharedFixtureDecodesAndRoundTrips() {
        val m = MessageCodec.decode(Fixtures.bytes("valid/canvas.background.json"))
        val p = m.payload as Payload.Background
        assertEquals(CanvasBackground.studio(CanvasBackground.BLACK, Pattern.GRAPH), p.background)
        assertEquals(7, p.revision)
        assertEquals(m, MessageCodec.decode(MessageCodec.encode(m)))
        assertFailsWith<ProtocolException> { MessageCodec.decode(Fixtures.bytes("invalid/bad-background-mode.json")) }
    }

    @Test
    fun storageMessagesUseTheSharedFixtures() {
        val st = (MessageCodec.decode(Fixtures.bytes("valid/storage.state.json")).payload as Payload.Storage).state
        assertEquals("System Design", st.project)
        assertEquals(listOf("~/Documents/InkBridge", "/Volumes/Work/InkBridge"), st.locations)
        val req = MessageCodec.decode(Fixtures.bytes("valid/storage.request.json")).payload as Payload.StorageRequest
        assertEquals("switch_project" to "System Design", req.action to req.name)
        assertFailsWith<ProtocolException>("unknown actions are rejected") { MessageCodec.decode(Fixtures.bytes("invalid/bad-storage-action.json")) }
    }

    @Test
    fun hostRevisionsOnlyMoveForward() {
        val doc = CanvasDocument()
        var changes = 0
        doc.onChange = { changes++ }
        doc.applyHost(Payload.Background(CanvasBackground.studio(CanvasBackground.WHITE), 5))
        doc.applyHost(Payload.Background(CanvasBackground.studio(CanvasBackground.BLACK), 3))  // delayed, older
        assertEquals(CanvasBackground.WHITE, doc.background.argb, "a stale message must not overwrite a newer one")
        assertEquals(5, doc.backgroundRevision)
        doc.applyHost(Payload.Background(CanvasBackground.OVERLAY, 6))
        assertEquals(CanvasBackground.OVERLAY, doc.background)
        assertEquals(2, changes)
    }

    @Test
    fun localChoiceIsShownAtOnceThenTheMacsAnswerWins() {
        val doc = CanvasDocument()
        doc.applyHost(Payload.Background(CanvasBackground.OVERLAY, 4))
        doc.setBackgroundLocal(CanvasBackground.studio(CanvasBackground.BLACK))
        assertTrue(doc.background.isDark)
        // Meanwhile someone picked white on the Mac; its answer has a newer revision.
        doc.applyHost(Payload.Background(CanvasBackground.studio(CanvasBackground.WHITE), 6))
        assertEquals(CanvasBackground.WHITE, doc.background.argb)
    }

    @Test
    fun switchingBackgroundsKeepsStrokes() {
        val doc = CanvasDocument()
        val style = WireStyle(CanvasBackground.BLACK, 2.0)
        doc.applyLocal(StylusEvent.Begin("s1", Tool.PEN, InkPoint(10.0, 10.0, 1.0, 0)), style)
        doc.applyLocal(StylusEvent.End("s1"), style)
        doc.applyHost(Payload.Background(CanvasBackground.studio(CanvasBackground.BLACK), 1))
        doc.applyHost(Payload.Background(CanvasBackground.studio(CanvasBackground.WHITE), 2))
        doc.applyHost(Payload.Background(CanvasBackground.OVERLAY, 3))
        assertEquals(1, doc.size)
        assertEquals(10.0, doc.read { it.first().points.first().x })
    }

    @Test
    fun einkRenderingIsMonochromeButTheColourIsKept() {
        val navy = CanvasBackground.studio(0xFF1E2A44.toInt())
        assertTrue(navy.isDark)
        assertEquals(CanvasBackground.BLACK, navy.einkPaper, "very dark colours render solid black on e-ink")
        assertEquals(0xFF1E2A44.toInt(), navy.argb, "the stored colour is unchanged")
        assertEquals(CanvasBackground.WHITE, CanvasBackground.studio(CanvasBackground.LIGHT_GRAY).einkPaper)
        assertEquals(CanvasBackground.WHITE, CanvasBackground.OVERLAY.einkPaper)
        val mid = CanvasBackground.studio(0xFF808080.toInt()).einkPaper and 0xff
        assertTrue(mid in 100..150 && mid % 17 == 0, "mid tones snap to one of 16 grey levels: $mid")
        assertFalse(CanvasBackground.OVERLAY.isDark)
    }
}
