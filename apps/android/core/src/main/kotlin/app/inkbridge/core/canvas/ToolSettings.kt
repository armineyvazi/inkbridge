package app.inkbridge.core.canvas

import app.inkbridge.core.protocol.Tool

/**
 * The selected drawing tool and each tool's size: a **preference**, not document data.
 *
 * Sizes are in canvas px (1 = one tablet pixel at 100 % zoom; ADR-006). That is the
 * unit strokes are stored in, so a size means the same thickness on the page at any
 * zoom, on any Mac display. Renderers convert at the boundary (`width × zoom` on the
 * tablet, `width × mapper.scale` on the Mac). Pen and highlighter sizes are the line
 * width at full pressure; the eraser size is its radius.
 *
 * The Mac is the source of truth (it styles every stroke). The tablet applies its own
 * changes at once, sends them as `tool.request`, and adopts `tool.state` from the Mac
 * except while one of its own requests is still in flight (see [ToolSync]).
 * The limits and presets are shared with the Mac through `protocol/fixtures/tool-sizes.json`.
 */
data class ToolSettings(
    val tool: Tool = Tool.PEN,
    val pen: Double = ToolSize.PEN.default,
    val highlighter: Double = ToolSize.HIGHLIGHTER.default,
    val eraser: Double = ToolSize.ERASER.default,
) {
    /** The size of [t]; null for the laser (fixed size). */
    fun size(t: Tool): Double? = when (t) {
        Tool.PEN -> pen
        Tool.HIGHLIGHTER -> highlighter
        Tool.ERASER -> eraser
        Tool.LASER -> null
    }

    /** A copy with [t]'s size set to [v], clamped to the tool's range. Other tools keep theirs. */
    fun withSize(t: Tool, v: Double): ToolSettings {
        val spec = ToolSize.of(t) ?: return this
        val c = spec.clamp(v)
        return when (t) {
            Tool.PEN -> copy(pen = c)
            Tool.HIGHLIGHTER -> copy(highlighter = c)
            Tool.ERASER -> copy(eraser = c)
            Tool.LASER -> this
        }
    }

    /** Every tool clamped into range (for values read from disk or the wire). */
    fun clamped(): ToolSettings = copy(
        pen = ToolSize.PEN.clamp(pen), highlighter = ToolSize.HIGHLIGHTER.clamp(highlighter), eraser = ToolSize.ERASER.clamp(eraser),
    )

    val sizes: Map<Tool, Double> get() = mapOf(Tool.PEN to pen, Tool.HIGHLIGHTER to highlighter, Tool.ERASER to eraser)
}

/** Limits, default and presets of one sizable tool (canvas px). */
enum class ToolSize(val tool: Tool, val default: Double, val min: Double, val max: Double, val presets: List<Double>) {
    PEN(Tool.PEN, 4.0, 0.5, 24.0, listOf(1.5, 3.0, 4.5, 7.0, 11.0)),
    HIGHLIGHTER(Tool.HIGHLIGHTER, 36.0, 6.0, 96.0, listOf(16.0, 24.0, 36.0, 52.0, 72.0)),
    ERASER(Tool.ERASER, 28.0, 4.0, 160.0, listOf(8.0, 16.0, 28.0, 48.0, 80.0));

    fun clamp(v: Double): Double = if (v.isFinite()) v.coerceIn(min, max) else default

    /**
     * One − / + press. Increments grow with the size (0.5 below 6, 1 below 12, 2 below
     * 24, 4 below 48, then 8) so each press is a visible but small change at any size.
     * Off-grid values snap to the grid first, so presses land on round numbers.
     */
    fun step(v: Double, up: Boolean): Double {
        val r = if (up) {
            val inc = increment(v)
            Math.floor(v / inc + 1e-9) * inc + inc
        } else {
            val inc = increment(v - 1e-9)
            Math.ceil(v / inc - 1e-9) * inc - inc
        }
        return clamp(r)
    }

    /** Index of the preset nearest to [v] (for highlighting XS…XL). */
    fun nearestPreset(v: Double): Int = presets.indices.minBy { Math.abs(presets[it] - v) }

    companion object {
        val LABELS = listOf("XS", "S", "M", "L", "XL")

        fun of(t: Tool): ToolSize? = entries.firstOrNull { it.tool == t }

        private fun increment(v: Double) = when {
            v < 6 -> 0.5
            v < 12 -> 1.0
            v < 24 -> 2.0
            v < 48 -> 4.0
            else -> 8.0
        }
    }
}

/**
 * Optimistic local edits against the Mac's authoritative [ToolSettings].
 *
 * Every local edit gets a sequence number. The Mac echoes the last one it applied as
 * `ack` in `tool.state`. A state whose ack is older than our latest edit is a reply to
 * an earlier step (a slider being dragged); adopting it would make the control jump
 * back, so it is skipped: the reply to our latest edit carries the merged result.
 * The Mac keeps the ack per device stream, in memory. Every new connection re-baselines
 * through [connected], so a restarted Mac (acks back at 0) is adopted, and an edit it never
 * acknowledged is re-sent in full. Not thread-safe: use from one thread (the UI thread).
 */
class ToolSync(initial: ToolSettings) {
    var settings: ToolSettings = initial
        private set
    var revision: Long = -1
        private set
    private var lastSent = 0L

    /** A local change: returns the request to send. */
    fun edit(next: ToolSettings, toolChanged: Boolean, sizeOf: Tool?): app.inkbridge.core.protocol.Payload.ToolRequest {
        settings = next
        lastSent += 1
        val sizes = if (sizeOf != null) next.size(sizeOf)?.let { mapOf(sizeOf to it) } ?: emptyMap() else emptyMap()
        return app.inkbridge.core.protocol.Payload.ToolRequest(lastSent, if (toolChanged) next.tool else null, sizes)
    }

    /** Highest `ack` seen on this connection. */
    private var acked = 0L
    /** The newest state received, adopted or not (it may arrive before [connected] runs). */
    private var latest: app.inkbridge.core.protocol.Payload.ToolState? = null

    /** The Mac's state. Returns true when it was adopted (the UI should refresh). */
    fun receive(state: app.inkbridge.core.protocol.Payload.ToolState): Boolean {
        latest = state
        if (state.ack < lastSent) return false
        acked = maxOf(acked, state.ack)
        revision = state.revision
        if (state.settings == settings) return false
        settings = state.settings
        return true
    }

    /**
     * A new connection is ready. The Mac's acks live in its memory, so after a Mac restart
     * they start again at 0; keeping our old `lastSent` would make us ignore the Mac forever.
     * - Every edit acknowledged: start over at 0 and adopt whatever the Mac sends.
     * - Some edit never acknowledged (made offline, or lost with a dead link): send the whole
     *   current state once, so that edit wins, and wait for its reply.
     * Returns the request to send, if any.
     */
    fun connected(): app.inkbridge.core.protocol.Payload.ToolRequest? {
        if (acked >= lastSent) {
            lastSent = 0
            acked = 0
            return null
        }
        lastSent += 1
        acked = 0
        return app.inkbridge.core.protocol.Payload.ToolRequest(lastSent, settings.tool, settings.sizes)
    }

    /** After [connected] returned null: adopts the newest Mac state if it was skipped. True when settings changed. */
    fun adoptLatest(): Boolean {
        val st = latest ?: return false
        if (lastSent != 0L) return false
        revision = st.revision
        if (st.settings == settings) return false
        settings = st.settings
        return true
    }
}
