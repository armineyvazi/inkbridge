package app.inkbridge.core.canvas

import app.inkbridge.core.input.StylusEvent
import app.inkbridge.core.protocol.InkPoint
import app.inkbridge.core.protocol.Payload
import app.inkbridge.core.protocol.Tool
import app.inkbridge.core.protocol.WireStyle

/**
 * The tablet's mirror of the shared drawing (ADR-006).
 *
 * The Mac owns the document. This mirror shows the user's own strokes
 * immediately (optimistic) and applies the Mac's changes: styles, removals,
 * strokes the tablet lacks, resets. Stroke points are canvas px, so the
 * viewport never touches this data.
 *
 * Thread-safe: local input (UI thread), host messages (network thread) and
 * the renderer all go through [lock]. The renderer copies what it needs and
 * draws outside the lock, so input is never blocked by drawing.
 */
class CanvasDocument {
    class Stroke(val id: String, var tool: Tool, var style: WireStyle, val local: Boolean) {
        val points = ArrayList<InkPoint>()
        var ended = false
        var bounds = Bounds.EMPTY
            private set

        fun add(p: InkPoint) {
            points += p
            bounds = bounds.union(Bounds(p.x, p.y, p.x, p.y))
        }

        /** Eraser and laser strokes are shown while drawn but never kept. */
        val isTransient get() = tool == Tool.ERASER || tool == Tool.LASER
    }

    /** What changed, so the renderer can redraw as little as possible. */
    sealed interface Change {
        /** New points on one stroke: draw just those segments. */
        data class Grew(val id: String) : Change
        /** Anything else: redraw everything visible. */
        data object Full : Change
    }

    private val lock = Any()
    private val strokes = LinkedHashMap<String, Stroke>()
    /** Local strokes not yet fully sent; they survive a reset (outage drawing). */
    private val pending = HashSet<String>()

    var onChange: ((Change) -> Unit)? = null

    /** The background layer as last confirmed by the Mac, or set optimistically here. */
    @Volatile var background: CanvasBackground = CanvasBackground.OVERLAY
        private set
    /** The Mac revision [background] came from; older host messages are ignored. */
    @Volatile var backgroundRevision: Long = 0
        private set

    /**
     * Shows a background chosen on the tablet right away (e-ink feedback
     * without a round trip). The Mac's echo then confirms or overrides it.
     */
    fun setBackgroundLocal(bg: CanvasBackground) {
        if (bg == background) return
        background = bg
        onChange?.invoke(Change.Full)
    }

    val size: Int get() = synchronized(lock) { strokes.size }

    /** Strokes drawn here that have not fully reached the Mac yet (offline drawing). */
    val unsentCount: Int get() = synchronized(lock) { pending.size }

    fun <T> read(block: (Collection<Stroke>) -> T): T = synchronized(lock) { block(strokes.values) }

    /** Copies of points [from, end) of a stroke, plus its style. Null if gone. */
    fun tail(id: String, from: Int): Triple<List<InkPoint>, WireStyle, Tool>? = synchronized(lock) {
        val s = strokes[id] ?: return null
        Triple(ArrayList(s.points.subList(from.coerceIn(0, s.points.size), s.points.size)), s.style, s.tool)
    }

    fun contentBounds(): Bounds = synchronized(lock) {
        strokes.values.filter { !it.isTransient }.fold(Bounds.EMPTY) { acc, s -> acc.union(s.bounds.inflate(s.style.width / 2)) }
    }

    // MARK: Local input

    fun applyLocal(e: StylusEvent, defaultStyle: WireStyle) {
        val change: Change = synchronized(lock) {
            when (e) {
                is StylusEvent.Begin -> {
                    strokes[e.strokeId] = Stroke(e.strokeId, e.tool, defaultStyle, local = true).also { it.add(e.point) }
                    pending += e.strokeId
                    Change.Grew(e.strokeId)
                }
                is StylusEvent.Move -> {
                    val s = strokes[e.strokeId] ?: return
                    e.points.forEach(s::add)
                    Change.Grew(e.strokeId)
                }
                is StylusEvent.End -> {
                    val s = strokes[e.strokeId] ?: return
                    s.ended = true
                    if (s.isTransient) { strokes.remove(e.strokeId); Change.Full } else Change.Grew(e.strokeId)
                }
                is StylusEvent.Cancel -> {
                    strokes.remove(e.strokeId)
                    pending -= e.strokeId
                    Change.Full
                }
            }
        }
        onChange?.invoke(change)
    }

    /** The client wrote this stroke's end to the socket; it is now the Mac's to keep. */
    fun markSent(id: String) = synchronized(lock) { pending -= id }

    /** Local-only clear, e.g. when offline. The Mac's copy is untouched and comes back on resync. */
    fun clearLocal() {
        synchronized(lock) { strokes.keys.retainAll(pending) }
        onChange?.invoke(Change.Full)
    }

    // MARK: Host messages

    /** Applies a host→device message. Returns false if it was not a document message. */
    fun applyHost(p: Payload): Boolean {
        val change: Change? = synchronized(lock) {
            when (p) {
                is Payload.StrokeBegin -> {
                    val style = p.style ?: return@synchronized null
                    strokes.remove(p.strokeId)
                    strokes[p.strokeId] = Stroke(p.strokeId, p.tool, style, local = false).also { it.add(p.point) }
                    Change.Grew(p.strokeId)
                }
                is Payload.StrokePoints -> strokes[p.strokeId]?.takeIf { !it.local }?.let { s ->
                    p.points.forEach(s::add)
                    Change.Grew(p.strokeId)
                }
                is Payload.StrokeEnd -> strokes[p.strokeId]?.takeIf { !it.local }?.let { it.ended = true; null }
                is Payload.StrokeStyle -> strokes[p.strokeId]?.let { s ->
                    val toolChanged = s.tool != p.tool
                    s.tool = p.tool
                    s.style = p.style
                    when {
                        s.isTransient && s.ended -> { strokes.remove(p.strokeId); Change.Full }
                        // Pen colour/width only affects segments drawn from now on; a tool
                        // change (pen → highlighter) needs the stroke redrawn.
                        toolChanged -> Change.Full
                        else -> null
                    }
                }
                is Payload.DocRemove -> {
                    var any = false
                    p.strokeIds.forEach { if (strokes.remove(it) != null) any = true }
                    if (any) Change.Full else null
                }
                is Payload.Background -> {
                    // Revisions only move forward: a delayed older message never wins.
                    if (p.revision < backgroundRevision) return@synchronized null
                    backgroundRevision = p.revision
                    if (p.background == background) null else { background = p.background; Change.Full }
                }
                is Payload.DocReset -> {
                    strokes.keys.retainAll(pending)
                    Change.Full
                }
                else -> return false
            }
        }
        change?.let { onChange?.invoke(it) }
        return true
    }
}
