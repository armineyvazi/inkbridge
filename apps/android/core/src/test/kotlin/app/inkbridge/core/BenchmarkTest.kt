package app.inkbridge.core

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
        val p = StrokeProcessor(streamTag = "bench")
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

    /**
     * The tablet's whole UI-thread pen path per MotionEvent, as the canvas runs it:
     * processor → local document (with the selected tool and size) → percentile summary.
     * Long continuous stroke (20 000 samples), fast and slow hands, direction changes,
     * and a size change every 2 000 events. Regression guard: p99 under 1 ms on the JVM
     * (the BOOX measures ~10× slower per op; its own numbers come from the perf log).
     */
    @Test
    fun localPenPathPercentiles() {
        val doc = app.inkbridge.core.canvas.CanvasDocument()
        val p = StrokeProcessor(streamTag = "bench")
        var tools = app.inkbridge.core.canvas.ToolSettings()
        val rec = app.inkbridge.core.input.LatencyRecorder(capacity = 20_000)
        fun run(record: Boolean) {
            rec.reset()
            var t = 0L
            fun feed(action: PointerAction, samples: List<RawSample>) {
                val t0 = System.nanoTime()
                for (e in p.process(action, ToolKind.STYLUS, false, samples)) {
                    if (e is app.inkbridge.core.input.StylusEvent.Begin) {
                        doc.applyLocal(e, app.inkbridge.core.protocol.WireStyle(0, tools.pen), tools.tool)
                    } else doc.applyLocal(e, app.inkbridge.core.protocol.WireStyle(0, 2.5))
                }
                if (record) rec.add((System.nanoTime() - t0) / 1e6)
            }
            feed(PointerAction.DOWN, listOf(RawSample(100f, 100f, 0.5f, t)))
            for (i in 0 until 10_000) {
                // Alternate fast (5 samples per event, large steps) and slow (1 sample), zig-zag direction.
                val fast = (i / 500) % 2 == 0
                val dir = if ((i / 37) % 2 == 0) 1f else -1f
                val n = if (fast) 5 else 1
                val samples = List(n) { k -> t += 2_000_000; RawSample(100f + (i % 900) * (if (fast) 1.5f else 0.2f), 500f + dir * k * 3f, 0.3f + (k % 5) * 0.15f, t) }
                feed(PointerAction.MOVE, samples)
                if (i % 2_000 == 1_999) tools = tools.withSize(app.inkbridge.core.protocol.Tool.PEN, tools.pen + 0.5)
            }
            feed(PointerAction.UP, listOf(RawSample(1000f, 500f, 0.5f, t)))
        }
        run(record = false)  // JIT warm-up
        run(record = true)
        val us = { q: Double -> "%.1f".format(rec.percentile(q)!! * 1000) }
        println("[bench] local pen path per MotionEvent: p50 ${us(0.5)} · p95 ${us(0.95)} · p99 ${us(0.99)} µs (n=${rec.size})")
        assertTrue(rec.percentile(0.99)!! < 1.0, "p99 budget 1 ms: ${rec.summary()}")
    }
}
