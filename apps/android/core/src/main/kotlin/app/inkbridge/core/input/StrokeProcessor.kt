package app.inkbridge.core.input

import app.inkbridge.core.canvas.Viewport
import app.inkbridge.core.protocol.InkPoint
import kotlin.math.roundToLong
import app.inkbridge.core.protocol.Tool

/**
 * Turns raw pointer events into stroke lifecycle events.
 *
 * Responsibilities: palm/finger rejection, stroke IDs, view px → canvas px
 * through the current [viewport] (ADR-006), and
 * repairing broken sequences (a DOWN without a preceding UP ends the old
 * stroke first; MOVE without DOWN is ignored). Kept free of Android types
 * so it is unit-testable on the JVM.
 */
class StrokeProcessor(
    /** Read on every sample; written by the UI thread when the user pans or zooms. */
    @Volatile var viewport: Viewport = Viewport.HOME,
    /** Prefix that makes stroke IDs unique across app processes. */
    private val streamTag: String,
    var acceptFinger: Boolean = false,
    /** Read on every sample; a settings change applies to the next sample. */
    @Volatile var pressure: PressureResponse = PressureResponse.NORMAL,
) {
    private var counter = 0L
    private var activeId: String? = null

    val isStrokeActive: Boolean get() = activeId != null

    /**
     * @param buttonPressed the primary stylus button; held = eraser, the
     *   common convention on Wacom-style pens. Unverified on BOOX Pen Plus.
     */
    fun process(action: PointerAction, tool: ToolKind, buttonPressed: Boolean, samples: List<RawSample>): List<StylusEvent> {
        val out = ArrayList<StylusEvent>(2)
        if (!accepts(tool)) {
            // A finger landing mid-stroke must not end the pen stroke.
            return out
        }
        when (action) {
            PointerAction.DOWN -> {
                activeId?.let { out += StylusEvent.End(it) }
                val first = samples.lastOrNull() ?: return out
                val id = "s-$streamTag-${++counter}"
                activeId = id
                val strokeTool = if (tool == ToolKind.ERASER || buttonPressed) Tool.ERASER else Tool.PEN
                out += StylusEvent.Begin(id, strokeTool, point(first))
            }
            PointerAction.MOVE -> {
                val id = activeId ?: return out
                if (samples.isNotEmpty()) {
                    // The protocol caps points per message; split very large batches.
                    samples.chunked(MAX_BATCH).forEach { chunk -> out += StylusEvent.Move(id, chunk.map(::point)) }
                }
            }
            PointerAction.UP -> {
                val id = activeId ?: return out
                if (samples.isNotEmpty()) out += StylusEvent.Move(id, samples.takeLast(MAX_BATCH).map(::point))
                out += StylusEvent.End(id)
                activeId = null
            }
            PointerAction.CANCEL -> {
                val id = activeId ?: return out
                out += StylusEvent.Cancel(id)
                activeId = null
            }
        }
        return out
    }

    private fun accepts(tool: ToolKind) = when (tool) {
        ToolKind.STYLUS, ToolKind.ERASER -> true
        ToolKind.FINGER -> acceptFinger
        // Mouse lets the emulator and desktop testing work; unknown is treated as stylus
        // because some vendor digitizers report TOOL_TYPE_UNKNOWN.
        ToolKind.MOUSE, ToolKind.UNKNOWN -> true
    }

    private fun point(s: RawSample): InkPoint {
        val v = viewport
        return InkPoint(
            x = round2(v.toCanvasX(s.x)),
            y = round2(v.toCanvasY(s.y)),
            p = round4(pressure.apply(s.pressure.toDouble().coerceIn(0.0, 1.0))),
            t = s.timeNs,
        )
    }

    companion object {
        const val MAX_BATCH = 256


        // 0.01 canvas px is far below what a digitizer resolves; rounding keeps messages short.
        fun round2(v: Double): Double = (v * 100).roundToLong() / 100.0
        fun round4(v: Double): Double = (v * 10_000).roundToLong() / 10_000.0
    }
}

/**
 * How pen pressure maps to line width. A power curve keeps 0 and 1 fixed:
 * SOFT reaches full width with a lighter hand, FIRM needs more force, OFF
 * draws every line at full width (as if pressure were always 1).
 */
enum class PressureResponse(private val exponent: Double?) {
    OFF(null), SOFT(0.6), NORMAL(1.0), FIRM(1.6);

    fun apply(p: Double): Double = exponent?.let { Math.pow(p, it) } ?: 1.0
}
