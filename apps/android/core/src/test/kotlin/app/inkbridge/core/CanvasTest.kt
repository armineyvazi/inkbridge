package app.inkbridge.core

import app.inkbridge.core.canvas.Bounds
import app.inkbridge.core.canvas.CanvasDocument
import app.inkbridge.core.canvas.Viewport
import app.inkbridge.core.input.StylusEvent
import app.inkbridge.core.protocol.InkPoint
import app.inkbridge.core.protocol.Payload
import app.inkbridge.core.protocol.Tool
import app.inkbridge.core.protocol.WireStyle
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class ViewportTest {
    @Test
    fun conversionsRoundTrip() {
        val v = Viewport(x = -300.0, y = 250.0, zoom = 1.7)
        assertEquals(123.0f, v.toViewX(v.toCanvasX(123f)), 1e-3f)
        assertEquals(-300.0 + 170.0 / 1.7, v.toCanvasX(170f), 1e-9)
    }

    @Test
    fun zoomKeepsFocusFixed() {
        val v = Viewport(100.0, 200.0, 1.0).zoomedBy(2.0, 300f, 400f)
        assertEquals(2.0, v.zoom)
        assertEquals(400.0, v.toCanvasX(300f), 1e-9)
        assertEquals(600.0, v.toCanvasY(400f), 1e-9)
    }

    @Test
    fun zoomIsClampedAndPanFollowsFinger() {
        assertEquals(Viewport.ZOOM_RANGE.start, Viewport.HOME.zoomedBy(1e-9, 0f, 0f).zoom)
        val p = Viewport(0.0, 0.0, 2.0).pannedBy(100f, -50f)
        assertEquals(-50.0, p.x, "dragging right reveals content to the left")
        assertEquals(25.0, p.y)
    }

    @Test
    fun fittingMatchesSwift() {
        // Same case as Swift ViewportTests.testFittingCentresContentWithMargin.
        val v = Viewport.fitting(Bounds(1000.0, 2000.0, 3808.0, 2100.0), 1404, 1872)
        assertEquals(1404 * 0.9 / 2808, v.zoom, 1e-9)
        assertEquals(1000.0 + 1404, v.x + 1404 / v.zoom / 2, 1e-6)
        assertEquals(Viewport.HOME, Viewport.fitting(Bounds.EMPTY, 1404, 1872))
    }
}

class CanvasDocumentTest {
    private val black = WireStyle(0xFF000000.toInt(), 2.5)
    private val red = WireStyle(0xFFEB3B33.toInt(), 5.6)
    private fun pt(x: Double, y: Double) = InkPoint(x, y, 0.5, 0)
    private fun draw(d: CanvasDocument, id: String, vararg p: InkPoint) {
        d.applyLocal(StylusEvent.Begin(id, Tool.PEN, p[0]), black)
        if (p.size > 1) d.applyLocal(StylusEvent.Move(id, p.drop(1)), black)
        d.applyLocal(StylusEvent.End(id), black)
    }
    private fun ids(d: CanvasDocument) = d.read { all -> all.map { it.id } }

    @Test
    fun localStrokesStayVisibleAndReportIncrementalChanges() {
        val d = CanvasDocument()
        val changes = mutableListOf<CanvasDocument.Change>()
        d.onChange = { changes += it }
        draw(d, "a", pt(0.0, 0.0), pt(10.0, 10.0))
        draw(d, "b", pt(5000.0, 5000.0))
        assertEquals(listOf("a", "b"), ids(d), "every stroke persists")
        assertTrue(changes.all { it is CanvasDocument.Change.Grew }, "writing never forces a full redraw")
    }

    @Test
    fun hostStyleUpdatesWithoutFullRedrawUnlessToolChanges() {
        val d = CanvasDocument()
        var fulls = 0
        d.onChange = { if (it == CanvasDocument.Change.Full) fulls++ }
        d.applyLocal(StylusEvent.Begin("a", Tool.PEN, pt(0.0, 0.0)), black)
        d.applyHost(Payload.StrokeStyle("a", Tool.PEN, red))
        assertEquals(0, fulls)
        assertEquals(red, d.read { it.first().style })
        d.applyHost(Payload.StrokeStyle("a", Tool.HIGHLIGHTER, red))
        assertEquals(1, fulls)
    }

    @Test
    fun hostEraserStrokeDisappearsAndRemovalsApply() {
        val d = CanvasDocument()
        draw(d, "keep", pt(0.0, 0.0))
        draw(d, "gone", pt(1.0, 1.0))
        d.applyLocal(StylusEvent.Begin("e", Tool.PEN, pt(2.0, 2.0)), black)
        d.applyHost(Payload.StrokeStyle("e", Tool.ERASER, black))
        d.applyLocal(StylusEvent.End("e"), black)
        assertEquals(listOf("keep", "gone"), ids(d), "eraser trail is not kept")
        d.applyHost(Payload.DocRemove(listOf("gone")))
        assertEquals(listOf("keep"), ids(d))
    }

    @Test
    fun resetKeepsUnsentLocalStrokesAndAcceptsHostStrokes() {
        val d = CanvasDocument()
        draw(d, "sent", pt(0.0, 0.0))
        d.markSent("sent")
        draw(d, "offline", pt(1.0, 1.0)) // drawn during an outage, not yet sent
        d.applyHost(Payload.DocReset)
        assertEquals(listOf("offline"), ids(d))
        d.applyHost(Payload.StrokeBegin("h1", Tool.HIGHLIGHTER, pt(-100.0, 7.0), red))
        d.applyHost(Payload.StrokePoints("h1", listOf(pt(-90.0, 7.0))))
        d.applyHost(Payload.StrokeEnd("h1"))
        assertEquals(listOf("offline", "h1"), ids(d))
        assertEquals(Bounds(-100.0, 7.0, -90.0, 7.0), d.read { all -> all.first { it.id == "h1" }.bounds })
    }

    @Test
    fun clearLocalNeverDropsUnsentWorkAndContentBoundsIgnoreTransient() {
        val d = CanvasDocument()
        draw(d, "a", pt(-10.0, -10.0), pt(10.0, 10.0))
        d.markSent("a")
        assertEquals(Bounds(-11.25, -11.25, 11.25, 11.25), d.contentBounds())
        d.clearLocal()
        assertEquals(0, d.size)
    }
}
