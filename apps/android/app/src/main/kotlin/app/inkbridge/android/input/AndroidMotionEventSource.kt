package app.inkbridge.android.input

import android.os.Build
import android.view.MotionEvent
import app.inkbridge.core.input.PointerAction
import app.inkbridge.core.input.RawSample
import app.inkbridge.core.input.StrokeProcessor
import app.inkbridge.core.input.StylusEvent
import app.inkbridge.core.input.StylusInputSource
import app.inkbridge.core.input.ToolKind
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.asSharedFlow

/**
 * Standard Android stylus input: MotionEvent → [StrokeProcessor].
 *
 * Every MotionEvent carries the samples the digitizer reported since the
 * last frame as "historical" points; reading them is what keeps fast
 * strokes smooth instead of polygonal. Only pointer 0 is tracked: the pen
 * is a single pointer, and extra pointers are palms or fingers.
 */
class AndroidMotionEventSource(private val processor: StrokeProcessor) : StylusInputSource {
    private val events = MutableSharedFlow<StylusEvent>(
        extraBufferCapacity = 4096,
        onBufferOverflow = BufferOverflow.SUSPEND,
    )

    override fun observeEvents(): Flow<StylusEvent> = events.asSharedFlow()

    /** Direct callback, invoked synchronously on the UI thread (lowest latency). */
    var onEvents: ((List<StylusEvent>) -> Unit)? = null

    fun onMotionEvent(ev: MotionEvent): Boolean {
        val t0 = System.nanoTime()
        val action = when (ev.actionMasked) {
            MotionEvent.ACTION_DOWN -> PointerAction.DOWN
            MotionEvent.ACTION_MOVE -> PointerAction.MOVE
            MotionEvent.ACTION_UP -> PointerAction.UP
            MotionEvent.ACTION_CANCEL -> PointerAction.CANCEL
            else -> return true // secondary pointers: consume, ignore
        }
        val buttonPressed = ev.buttonState and MotionEvent.BUTTON_STYLUS_PRIMARY != 0
        val out = processor.process(action, toolKind(ev.getToolType(0)), buttonPressed, samples(ev))
        if (out.isNotEmpty()) {
            onEvents?.invoke(out)
            out.forEach { if (!events.tryEmit(it)) droppedSamples.incrementAndGet() }
        }
        // Newest sample's age on arrival = the system's input delivery time (digitizer →
        // kernel → InputDispatcher → this thread); then our own processing on the UI thread.
        deliveryTime.add((t0 - eventTimeNs(ev)) / 1e6)
        processTime.add((System.nanoTime() - t0) / 1e6)
        samplesSeen.addAndGet(ev.historySize + 1L)
        return true
    }

    companion object {
        /** Input delivery (sample time → onTouchEvent) and UI-thread processing per MotionEvent. */
        val deliveryTime = app.inkbridge.core.input.LatencyRecorder()
        val processTime = app.inkbridge.core.input.LatencyRecorder()
        val samplesSeen = java.util.concurrent.atomic.AtomicLong()
        /** Samples the observer flow could not take (the direct path never drops). */
        val droppedSamples = java.util.concurrent.atomic.AtomicLong()

        fun toolKind(type: Int) = when (type) {
            MotionEvent.TOOL_TYPE_STYLUS -> ToolKind.STYLUS
            MotionEvent.TOOL_TYPE_ERASER -> ToolKind.ERASER
            MotionEvent.TOOL_TYPE_FINGER -> ToolKind.FINGER
            MotionEvent.TOOL_TYPE_MOUSE -> ToolKind.MOUSE
            else -> ToolKind.UNKNOWN
        }

        /** Historical samples oldest-first, then the current one. Times in ns (CLOCK_MONOTONIC). */
        fun samples(ev: MotionEvent): List<RawSample> {
            val n = ev.historySize
            val out = ArrayList<RawSample>(n + 1)
            for (h in 0 until n) {
                out += RawSample(ev.getHistoricalX(0, h), ev.getHistoricalY(0, h), ev.getHistoricalPressure(0, h), historicalTimeNs(ev, h))
            }
            out += RawSample(ev.x, ev.y, ev.pressure, eventTimeNs(ev))
            return out
        }

        // Event times are on SystemClock.uptimeMillis's clock (CLOCK_MONOTONIC), the
        // same clock as System.nanoTime(), which stamps outgoing messages. That shared
        // clock is what lets the Mac compute pen-to-host latency.
        fun eventTimeNs(ev: MotionEvent): Long =
            if (Build.VERSION.SDK_INT >= 34) ev.eventTimeNanos else ev.eventTime * 1_000_000

        private fun historicalTimeNs(ev: MotionEvent, h: Int): Long =
            if (Build.VERSION.SDK_INT >= 34) ev.getHistoricalEventTimeNanos(h) else ev.getHistoricalEventTime(h) * 1_000_000
    }
}
