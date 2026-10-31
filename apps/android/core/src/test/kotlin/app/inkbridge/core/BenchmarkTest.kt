package app.inkbridge.core

import app.inkbridge.core.input.CoordinateNormalizer
import app.inkbridge.core.input.PointerAction
import app.inkbridge.core.input.RawSample
import app.inkbridge.core.input.StrokeProcessor
import app.inkbridge.core.input.ToolKind
import app.inkbridge.core.protocol.Framing
import app.inkbridge.core.protocol.InkPoint
import app.inkbridge.core.protocol.Message
import app.inkbridge.core.protocol.MessageCodec
import app.inkbridge.core.protocol.Payload
import kotlin.test.Test
import kotlin.test.assertTrue

/**
 * Coarse throughput checks for the per-sample path on the JVM. Real numbers
 * for the tablet's CPU come from the in-app diagnostics, not from here.
 */
class BenchmarkTest {
    @Test
    fun processAndEncodePerEvent() {
        val p = StrokeProcessor(CoordinateNormalizer(1404, 1872), "bench")
        p.process(PointerAction.DOWN, ToolKind.STYLUS, false, listOf(RawSample(1f, 1f, 0.5f, 0)))
        val samples = List(2) { RawSample(700f + it, 900f, 0.6f, it.toLong()) }
        repeat(20_000) { // warm-up for the JIT
            p.process(PointerAction.MOVE, ToolKind.STYLUS, false, samples).forEach { e ->
                Framing.frame(MessageCodec.encode(Message(it.toLong(), 0, Payload.StrokePoints(e.strokeId, listOf(InkPoint(0.5, 0.5, 0.5, 0))))))
            }
        }
        val n = 50_000
        val start = System.nanoTime()
        repeat(n) { i ->
            val e = p.process(PointerAction.MOVE, ToolKind.STYLUS, false, samples)[0] as app.inkbridge.core.input.StylusEvent.Move
            Framing.frame(MessageCodec.encode(Message(i.toLong(), 0, Payload.StrokePoints(e.strokeId, e.points))))
        }
        val us = (System.nanoTime() - start) / 1e3 / n
        println("[bench] process+encode+frame one MotionEvent (2 samples): ${"%.2f".format(us)} µs")
        assertTrue(us < 2_000, "input processing budget is 2 ms")
    }
}
