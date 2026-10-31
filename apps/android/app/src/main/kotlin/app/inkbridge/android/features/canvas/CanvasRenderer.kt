package app.inkbridge.android.features.canvas

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Rect
import android.os.Handler
import android.os.HandlerThread
import android.view.SurfaceHolder
import app.inkbridge.core.canvas.Bounds
import app.inkbridge.core.canvas.CanvasDocument
import app.inkbridge.core.canvas.Viewport
import app.inkbridge.core.protocol.InkPoint
import app.inkbridge.core.protocol.Tool
import app.inkbridge.core.protocol.WireStyle
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Draws the canvas on its own thread, built around e-ink:
 *
 * - **Incremental**: new pen segments are drawn into a cached bitmap of the
 *   current viewport, and only their bounding rect is posted to the surface.
 *   Writing never triggers a full-screen refresh.
 * - **Full redraw** only when the view or the document changes (zoom/pan end,
 *   undo, erase, sync). It culls strokes outside the viewport.
 * - **Pinch/pan preview**: the cached bitmap is transformed instead of
 *   re-rendering every stroke on every gesture frame.
 *
 * The UI thread only posts requests, so pen input is never blocked by drawing.
 * Ink is monochrome: colours that read well on a Mac (yellow highlighter)
 * would vanish on e-ink, so pens draw black and highlighters grey.
 */
class CanvasRenderer(private val document: CanvasDocument) {
    private val thread = HandlerThread("ink-render").apply { start() }
    private val handler = Handler(thread.looper)

    // Render-thread state.
    private var holder: SurfaceHolder? = null
    private var cache: Bitmap? = null
    private var cacheCanvas: Canvas? = null
    private var cacheViewport: Viewport? = null
    private val drawnUpTo = HashMap<String, Int>()
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeCap = Paint.Cap.ROUND
        strokeJoin = Paint.Join.ROUND
    }

    // Cross-thread requests.
    @Volatile var viewport: Viewport = Viewport.HOME
        private set
    @Volatile var inkVisible = true
        set(value) { field = value; requestFull() }
    @Volatile private var preview: Viewport? = null
    private val pendingIds = LinkedHashSet<String>()
    private val fullRequested = AtomicBoolean(true)
    private val scheduled = AtomicBoolean(false)
    @Volatile private var lastPreviewAt = 0L

    init {
        document.onChange = { change ->
            when (change) {
                is CanvasDocument.Change.Grew -> synchronized(pendingIds) { pendingIds += change.id }
                CanvasDocument.Change.Full -> fullRequested.set(true)
            }
            schedule()
        }
    }

    fun attach(h: SurfaceHolder, width: Int, height: Int) = handler.post {
        holder = h
        if (cache?.width != width || cache?.height != height) {
            cache = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888).also { cacheCanvas = Canvas(it) }
        }
        fullRequested.set(true)
        frame()
    }

    fun detach() = handler.post { holder = null }

    fun setViewport(v: Viewport) {
        viewport = v
        preview = null
        fullRequested.set(true)
        schedule()
    }

    /** Gesture in progress: show [v] by transforming the cache, at most ~20 fps. */
    fun preview(v: Viewport) {
        preview = v
        val now = System.nanoTime()
        if (now - lastPreviewAt > 50_000_000) {
            lastPreviewAt = now
            schedule()
        }
    }

    fun requestFull() {
        fullRequested.set(true)
        schedule()
    }

    fun quit() = thread.quitSafely()

    private fun schedule() {
        if (scheduled.compareAndSet(false, true)) handler.post(::frame)
    }

    // MARK: Frames (render thread)

    private fun frame() {
        scheduled.set(false)
        val h = holder ?: return
        val pv = preview
        when {
            pv != null && !fullRequested.get() -> drawPreview(h, pv)
            fullRequested.getAndSet(false) || cacheViewport != viewport -> renderFull(h)
            else -> renderIncremental(h)
        }
    }

    private fun renderFull(h: SurfaceHolder) {
        val c = cacheCanvas ?: return
        val bmp = cache ?: return
        val v = viewport
        synchronized(pendingIds) { pendingIds.clear() }
        drawnUpTo.clear()
        c.drawColor(Color.WHITE)
        if (inkVisible) {
            val visible = Bounds(v.x, v.y, v.x + bmp.width / v.zoom, v.y + bmp.height / v.zoom)
            // Copy what is visible under the lock, draw outside it.
            val snapshot = document.read { all ->
                all.filter { it.bounds.inflate(it.style.width).intersects(visible) }
                    .map { Triple(it.id, ArrayList(it.points), it.style to it.tool) }
            }
            for ((id, pts, st) in snapshot) {
                drawSegments(c, pts, st.first, st.second, v, from = 0)
                drawnUpTo[id] = pts.size
            }
        }
        cacheViewport = v
        post(h, null)
    }

    private fun renderIncremental(h: SurfaceHolder) {
        val c = cacheCanvas ?: return
        if (!inkVisible) return
        val ids = synchronized(pendingIds) { pendingIds.toList().also { pendingIds.clear() } }
        val v = viewport
        val dirty = Rect()
        for (id in ids) {
            val done = drawnUpTo[id] ?: 0
            // Start one point back so the new segment joins the previous one.
            val (pts, style, tool) = document.tail(id, maxOf(done - 1, 0)) ?: continue
            if (pts.isEmpty()) continue
            dirty.union(drawSegments(c, pts, style, tool, v, from = 0))
            drawnUpTo[id] = maxOf(done - 1, 0) + pts.size
        }
        if (!dirty.isEmpty) post(h, dirty)
    }

    private fun drawPreview(h: SurfaceHolder, pv: Viewport) {
        val bmp = cache ?: return
        val cv = cacheViewport ?: return
        val canvas = h.lockCanvas() ?: return
        try {
            canvas.drawColor(Color.WHITE)
            val s = (pv.zoom / cv.zoom).toFloat()
            canvas.translate(((cv.x - pv.x) * pv.zoom).toFloat(), ((cv.y - pv.y) * pv.zoom).toFloat())
            canvas.scale(s, s)
            canvas.drawBitmap(bmp, 0f, 0f, null)
        } finally {
            h.unlockCanvasAndPost(canvas)
        }
    }

    /** Copies the cache to the surface; [dirty] null means the whole surface. */
    private fun post(h: SurfaceHolder, dirty: Rect?) {
        val bmp = cache ?: return
        val canvas = (if (dirty != null) h.lockCanvas(dirty) else h.lockCanvas()) ?: return
        try {
            canvas.drawBitmap(bmp, 0f, 0f, null)
        } finally {
            h.unlockCanvasAndPost(canvas)
        }
    }

    /** Draws a polyline with pressure width; returns the touched rect in view px. */
    private fun drawSegments(c: Canvas, pts: List<InkPoint>, style: WireStyle, tool: Tool, v: Viewport, from: Int): Rect {
        val r = Rect()
        if (pts.isEmpty()) return r
        val base = (style.width * v.zoom).toFloat()
        when (tool) {
            Tool.PEN -> paint.color = Color.BLACK
            Tool.HIGHLIGHTER -> paint.color = Color.argb(0x70, 0x60, 0x60, 0x60)
            Tool.ERASER -> paint.color = Color.argb(0x90, 0xA0, 0xA0, 0xA0)
            Tool.LASER -> paint.color = Color.DKGRAY
        }
        val pressureSensitive = tool == Tool.PEN
        var px = v.toViewX(pts[from].x)
        var py = v.toViewY(pts[from].y)
        if (pts.size - from == 1) {
            paint.strokeWidth = width(base, pts[from].p, pressureSensitive)
            c.drawPoint(px, py, paint)
            r.union(Rect((px - base).toInt(), (py - base).toInt(), (px + base).toInt() + 1, (py + base).toInt() + 1))
            return r
        }
        for (i in from + 1 until pts.size) {
            val x = v.toViewX(pts[i].x)
            val y = v.toViewY(pts[i].y)
            val w = if (tool == Tool.ERASER || tool == Tool.LASER) 2f else width(base, (pts[i - 1].p + pts[i].p) / 2, pressureSensitive)
            paint.strokeWidth = w
            c.drawLine(px, py, x, y, paint)
            val pad = w / 2 + 2
            r.union(Rect((minOf(px, x) - pad).toInt(), (minOf(py, y) - pad).toInt(), (maxOf(px, x) + pad).toInt() + 1, (maxOf(py, y) + pad).toInt() + 1))
            px = x
            py = y
        }
        return r
    }

    // Same width rule as the Mac renderer: 30 % of the width at zero pressure.
    private fun width(base: Float, p: Double, pressureSensitive: Boolean): Float =
        if (pressureSensitive) maxOf(base * (0.3f + 0.7f * p.toFloat().coerceIn(0f, 1f)), 1f) else maxOf(base, 1f)
}
