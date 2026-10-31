package app.inkbridge.android.features.drawing

import android.os.SystemClock
import android.view.MotionEvent
import app.inkbridge.android.input.AndroidMotionEventSource
import app.inkbridge.core.input.EventRateMeter

/**
 * Live readout for Phase 0 hardware validation: what the digitizer is
 * actually reporting (not what it advertises).
 */
class StylusDiagnostics {
    private val rate = EventRateMeter()
    private var minPressure = Float.MAX_VALUE
    private var maxPressure = -Float.MAX_VALUE
    private val toolsSeen = linkedSetOf<String>()
    private var buttonsSeen = 0
    private var last: String = "touch the screen with the stylus"
    private var dispatchLagMs = 0.0

    fun record(ev: MotionEvent, hovering: Boolean = false) {
        for (s in AndroidMotionEventSource.samples(ev)) rate.record(s.timeNs)
        val p = ev.pressure
        if (!hovering) {
            minPressure = minOf(minPressure, p)
            maxPressure = maxOf(maxPressure, p)
        }
        toolsSeen += toolName(ev.getToolType(0))
        buttonsSeen = buttonsSeen or ev.buttonState
        // How stale the event already is when the app sees it.
        dispatchLagMs = (SystemClock.uptimeMillis() - ev.eventTime).toDouble()
        val tilt = ev.getAxisValue(MotionEvent.AXIS_TILT)
        last = "%s x=%.1f y=%.1f p=%.3f tilt=%.2f t=%dms hist=%d".format(
            if (hovering) "hover" else MotionEvent.actionToString(ev.actionMasked).removePrefix("ACTION_").lowercase(),
            ev.x, ev.y, p, tilt, ev.eventTime, ev.historySize,
        )
    }

    fun text(): String {
        val range = if (minPressure <= maxPressure) "%.3f–%.3f".format(minPressure, maxPressure) else "–"
        return "$last\nrate=%.0f Hz  pressure range=%s  tools=%s  buttons=0x%x  dispatch lag=%.0f ms".format(
            rate.hz, range, toolsSeen.joinToString(","), buttonsSeen, dispatchLagMs,
        )
    }

    fun reset() {
        rate.reset()
        minPressure = Float.MAX_VALUE
        maxPressure = -Float.MAX_VALUE
        toolsSeen.clear()
        buttonsSeen = 0
    }

    private fun toolName(t: Int) = when (t) {
        MotionEvent.TOOL_TYPE_STYLUS -> "stylus"
        MotionEvent.TOOL_TYPE_ERASER -> "eraser"
        MotionEvent.TOOL_TYPE_FINGER -> "finger"
        MotionEvent.TOOL_TYPE_MOUSE -> "mouse"
        else -> "unknown($t)"
    }
}
