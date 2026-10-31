package app.inkbridge.core

import app.inkbridge.core.canvas.Viewport
import app.inkbridge.core.input.EventRateMeter
import app.inkbridge.core.input.PointerAction
import app.inkbridge.core.input.RawSample
import app.inkbridge.core.input.StrokeProcessor
import app.inkbridge.core.input.StylusEvent
import app.inkbridge.core.input.ToolKind
import app.inkbridge.core.protocol.Tool
import app.inkbridge.core.transport.ReconnectionPolicy
import kotlin.random.Random
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertIs
import kotlin.test.assertTrue

private fun s(x: Float, y: Float, p: Float = 0.5f, t: Long = 0) = RawSample(x, y, p, t)

class StrokeProcessorTest {
    private fun processor() = StrokeProcessor(streamTag = "abcd")

    @Test
    fun fullLifecycle() {
        val p = processor()
        val begin = p.process(PointerAction.DOWN, ToolKind.STYLUS, false, listOf(s(100f, 200f, 0.3f, 10)))
        val b = assertIs<StylusEvent.Begin>(begin.single())
        assertEquals("s-abcd-1", b.strokeId)
        assertEquals(Tool.PEN, b.tool)
        assertEquals(100.0, b.point.x, "home view: canvas px = view px")
        assertEquals(0.3, b.point.p)
        assertEquals(10, b.point.t)

        // Historical samples arrive batched in one event.
        val move = p.process(PointerAction.MOVE, ToolKind.STYLUS, false, listOf(s(110f, 200f, t = 12), s(120f, 200f, t = 14)))
        assertEquals(2, assertIs<StylusEvent.Move>(move.single()).points.size)

        val up = p.process(PointerAction.UP, ToolKind.STYLUS, false, listOf(s(125f, 200f, t = 16)))
        assertIs<StylusEvent.Move>(up[0])
        assertIs<StylusEvent.End>(up[1])
        assertTrue(!p.isStrokeActive)
    }

    @Test
    fun samplesAreConvertedThroughTheCurrentViewport() {
        val p = processor()
        p.viewport = Viewport(x = 5000.0, y = -200.0, zoom = 0.5)
        val b = p.process(PointerAction.DOWN, ToolKind.STYLUS, false, listOf(s(100f, 40f)))[0] as StylusEvent.Begin
        assertEquals(5200.0, b.point.x, "x + px / zoom")
        assertEquals(-120.0, b.point.y)
    }

    @Test
    fun fingersAreRejectedByDefault() {
        val p = processor()
        assertTrue(p.process(PointerAction.DOWN, ToolKind.FINGER, false, listOf(s(1f, 1f))).isEmpty())
        p.acceptFinger = true
        assertEquals(1, p.process(PointerAction.DOWN, ToolKind.FINGER, false, listOf(s(1f, 1f))).size)
    }

    @Test
    fun palmDuringStrokeDoesNotEndIt() {
        val p = processor()
        p.process(PointerAction.DOWN, ToolKind.STYLUS, false, listOf(s(1f, 1f)))
        assertTrue(p.process(PointerAction.UP, ToolKind.FINGER, false, listOf(s(5f, 5f))).isEmpty())
        assertTrue(p.isStrokeActive)
    }

    @Test
    fun eraserToolAndButton() {
        val p = processor()
        assertEquals(Tool.ERASER, (p.process(PointerAction.DOWN, ToolKind.ERASER, false, listOf(s(1f, 1f)))[0] as StylusEvent.Begin).tool)
        val again = p.process(PointerAction.DOWN, ToolKind.STYLUS, true, listOf(s(1f, 1f)))
        assertIs<StylusEvent.End>(again[0], "missing UP repaired")
        assertEquals(Tool.ERASER, (again[1] as StylusEvent.Begin).tool)
    }

    @Test
    fun moveWithoutDownIgnoredAndCancelEmitsCancel() {
        val p = processor()
        assertTrue(p.process(PointerAction.MOVE, ToolKind.STYLUS, false, listOf(s(1f, 1f))).isEmpty())
        p.process(PointerAction.DOWN, ToolKind.STYLUS, false, listOf(s(1f, 1f)))
        assertIs<StylusEvent.Cancel>(p.process(PointerAction.CANCEL, ToolKind.STYLUS, false, emptyList()).single())
        assertTrue(p.process(PointerAction.UP, ToolKind.STYLUS, false, listOf(s(1f, 1f))).isEmpty())
    }

    @Test
    fun hugeBatchesAreSplitWithinProtocolLimit() {
        val p = processor()
        p.process(PointerAction.DOWN, ToolKind.STYLUS, false, listOf(s(0f, 0f)))
        val out = p.process(PointerAction.MOVE, ToolKind.STYLUS, false, List(600) { s(it.toFloat(), 0f) })
        assertEquals(listOf(256, 256, 88), out.map { (it as StylusEvent.Move).points.size })
    }

    @Test
    fun pressureClamped() {
        val p = processor()
        val b = p.process(PointerAction.DOWN, ToolKind.STYLUS, false, listOf(s(1f, 1f, 1.7f)))[0] as StylusEvent.Begin
        assertEquals(1.0, b.point.p)
    }

    @Test
    fun strokeIdsUnique() {
        val p = processor()
        val ids = (1..50).map {
            val id = (p.process(PointerAction.DOWN, ToolKind.STYLUS, false, listOf(s(1f, 1f)))[0] as StylusEvent.Begin).strokeId
            p.process(PointerAction.UP, ToolKind.STYLUS, false, emptyList())
            id
        }
        assertEquals(50, ids.toSet().size)
    }
}

class EventRateMeterTest {
    @Test
    fun measuresFrequency() {
        val m = EventRateMeter()
        for (i in 0..200) m.record(i * 5_000_000L) // every 5 ms
        assertEquals(200.0, m.hz, 0.5)
    }
}

class ReconnectionPolicyTest {
    @Test
    fun backsOffAndCaps() {
        val p = ReconnectionPolicy(jitter = 0.0)
        assertEquals(listOf(250L, 500L, 1000L, 2000L, 2000L), (1..5).map(p::delayFor))
    }

    @Test
    fun jitterStaysInBounds() {
        val p = ReconnectionPolicy(random = Random(42))
        repeat(1000) { assertTrue(p.delayFor(1) in 200..300) }
        repeat(1000) { assertTrue(p.delayFor(10) <= 2000) }
    }
}
