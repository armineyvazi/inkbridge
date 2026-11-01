package app.inkbridge.android.features.canvas

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Rect
import android.os.Handler
import android.os.HandlerThread
import android.view.SurfaceHolder
import app.inkbridge.core.canvas.CanvasBackground
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
 * How a stroke looks (monochrome, highlighter blend, widths) is [InkPainter],
 * shared with the pen-size preview.
 */
class CanvasRenderer(private val document: CanvasDocument) {
    companion object {
        /** Stylus sample time → its segment posted to the e-ink surface (the app's share of ink latency). */
        val inkLatency = app.inkbridge.core.input.LatencyRecorder()
        /** Time spent drawing and posting one incremental frame on the render thread. */
        val frameTime = app.inkbridge.core.input.LatencyRecorder()
        /** Lock margin around new ink: a pen moves well under this in one 25 ms frame. */
        const val LOCK_MARGIN_PX = 96
        /** `adb shell setprop debug.inkbridge.legacyframe 1`: the old frame order, for A/B measurement. */
        val legacyFrame: Boolean by lazy {
            runCatching {
                Class.forName("android.os.SystemProperties").getMethod("get", String::class.java)
                    .invoke(null, "debug.inkbridge.legacyframe") == "1"
            }.getOrDefault(false)
        }
        // Breakdown of a frame: drawing new segments into the cache, lockCanvas, copy + unlockAndPost.
        val drawTime = app.inkbridge.core.input.LatencyRecorder()
        val lockTime = app.inkbridge.core.input.LatencyRecorder()
        val postTime = app.inkbridge.core.input.LatencyRecorder()
        /** UI thread → render thread: first new sample in the document → frame starts drawing it. */
        val handoffTime = app.inkbridge.core.input.LatencyRecorder()
        private val frames = java.util.concurrent.atomic.AtomicLong()
    }

    /** When the oldest not-yet-drawn sample entered the document (0: nothing waiting). */
    private val pendingSince = java.util.concurrent.atomic.AtomicLong(0)

    private val thread = HandlerThread("ink-render").apply { start() }
    private val handler = Handler(thread.looper)

    // Render-thread state.
    private var holder: SurfaceHolder? = null
    private var cache: Bitmap? = null
    private var cacheCanvas: Canvas? = null
    private var cacheViewport: Viewport? = null
    private val drawnUpTo = HashMap<String, Int>()
    /** Whether the last full render was on dark paper (ink is drawn light). */
    private var dark = false
    private val paint = InkPainter.newPaint()

    // Cross-thread requests.
    @Volatile var viewport: Viewport = Viewport.HOME
        private set
    @Volatile var inkVisible = true
        set(value) { field = value; requestFull() }
    /** Pattern lines; colour depends on the paper (see [drawBackground]). */
    private val patternPaint = Paint(Paint.ANTI_ALIAS_FLAG)

    /** The shared background layer, read from the document on every full redraw. */
    private val background: CanvasBackground get() = document.background
    @Volatile private var preview: Viewport? = null
    private val pendingIds = LinkedHashSet<String>()
    private val fullRequested = AtomicBoolean(true)
    private val scheduled = AtomicBoolean(false)
    @Volatile private var lastPreviewAt = 0L

    init {
        document.onChange = { change ->
            when (change) {
                is CanvasDocument.Change.Grew -> {
                    synchronized(pendingIds) { pendingIds += change.id }
                    pendingSince.compareAndSet(0, System.nanoTime())
                }
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
        val bg = background
        c.drawColor(bg.einkPaper)
        drawBackground(c, bg, v, bmp.width, bmp.height)
        dark = bg.isDark
        drawDiagram(c, document.diagram, v)
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

    /**
     * Every 200 frames: the per-stage summary to logcat (`adb logcat -s InkBridge`).
     * Counted separately: the recorders stop growing at their capacity, so `size % 200`
     * became true on every frame after 2000 frames and logged from the render thread.
     */
    private fun logPerf() {
        if (frames.incrementAndGet() % 200 != 0L) return
        val s = app.inkbridge.android.input.AndroidMotionEventSource
        android.util.Log.i("InkBridge", "perf ink(sample→posted) ${inkLatency.summary()} · frame ${frameTime.summary()}" +
            " · input ${s.deliveryTime.summary()} · process ${s.processTime.summary()} · handoff ${handoffTime.summary()}" +
            " · draw ${drawTime.summary()} · lock ${lockTime.summary()} · copy+post ${postTime.summary()}" +
            " · ${PerfProbe.snapshot()}")
    }

    /** Ink drawn into the cache but outside the last locked region; posted next frame. */
    private val carry = Rect()

    /** Draws new samples of pending strokes into the cache; returns the oldest new sample's time. */
    private fun drainPending(c: Canvas, v: Viewport, dirty: Rect): Long {
        var oldest = Long.MAX_VALUE
        val ids = synchronized(pendingIds) { pendingIds.toList().also { pendingIds.clear() } }
        for (id in ids) {
            val done = drawnUpTo[id] ?: 0
            // Start one point back so the new segment joins the previous one.
            val (pts, style, tool) = document.tail(id, maxOf(done - 1, 0)) ?: continue
            if (pts.isEmpty()) continue
            dirty.union(drawSegments(c, pts, style, tool, v, from = 0))
            drawnUpTo[id] = maxOf(done - 1, 0) + pts.size
            oldest = minOf(oldest, pts[if (done > 0 && pts.size > 1) 1 else 0].t)
        }
        return oldest
    }

    /**
     * lockCanvas waits for the next display frame (the Note Air 2 Plus panel runs
     * at 40 Hz: ~20 ms of a 25 ms frame was spent here). Samples that arrived
     * during that wait used to miss the frame. Now the region is locked with a
     * margin around the new ink, and the samples that arrived meanwhile are drawn
     * before posting; anything outside the margin is carried to the next frame.
     */
    private fun renderIncremental(h: SurfaceHolder) {
        val c = cacheCanvas ?: return
        val bmp = cache ?: return
        if (!inkVisible) return
        val start = System.nanoTime()
        val v = viewport
        val dirty = Rect(carry).also { carry.setEmpty() }
        val since = pendingSince.getAndSet(0)
        if (since != 0L) handoffTime.add((start - since) / 1e6)
        var oldest = drainPending(c, v, dirty)
        if (dirty.isEmpty) return
        drawTime.add((System.nanoTime() - start) / 1e6)
        if (legacyFrame) {
            post(h, dirty, timed = true)
            val end = System.nanoTime()
            frameTime.add((end - start) / 1e6)
            if (oldest != Long.MAX_VALUE && oldest > 0) inkLatency.add((end - oldest) / 1e6)
            logPerf()
            return
        }
        val margin = LOCK_MARGIN_PX
        val locked = Rect(dirty).apply { inset(-margin, -margin); intersect(0, 0, bmp.width, bmp.height) }
        val t0 = System.nanoTime()
        val canvas = h.lockCanvas(Rect(locked)) ?: run { carry.union(dirty); return }
        val t1 = System.nanoTime()
        try {
            val late = Rect()
            oldest = minOf(oldest, drainPending(c, v, late))
            // Those samples made this frame; don't count them as waiting for the next one.
            if (!late.isEmpty) pendingSince.set(0)
            if (!late.isEmpty) {
                if (locked.contains(late)) dirty.union(late) else carry.union(late)
            }
            canvas.drawBitmap(bmp, 0f, 0f, null)
        } finally {
            h.unlockCanvasAndPost(canvas)
        }
        val end = System.nanoTime()
        lockTime.add((t1 - t0) / 1e6)
        postTime.add((end - t1) / 1e6)
        if (!carry.isEmpty) schedule()
        run {
            frameTime.add((end - start) / 1e6)
            // Sample times are MotionEvent times (CLOCK_MONOTONIC), the same clock as nanoTime.
            // The oldest new sample in the frame: the worst latency it contains.
            if (oldest != Long.MAX_VALUE && oldest > 0) inkLatency.add((end - oldest) / 1e6)
            logPerf()
        }
    }

    private fun drawPreview(h: SurfaceHolder, pv: Viewport) {
        val bmp = cache ?: return
        val cv = cacheViewport ?: return
        val canvas = h.lockCanvas() ?: return
        try {
            canvas.drawColor(background.einkPaper)
            val s = (pv.zoom / cv.zoom).toFloat()
            canvas.translate(((cv.x - pv.x) * pv.zoom).toFloat(), ((cv.y - pv.y) * pv.zoom).toFloat())
            canvas.scale(s, s)
            canvas.drawBitmap(bmp, 0f, 0f, null)
        } finally {
            h.unlockCanvasAndPost(canvas)
        }
    }

    /**
     * The shared paper pattern (same spacing as the Mac), anchored to canvas
     * px. Lines closer than 8 screen px are skipped: on e-ink they would be a
     * grey wash that slows every refresh.
     */
    private fun drawBackground(c: Canvas, bg: CanvasBackground, v: Viewport, w: Int, h: Int) {
        val p = bg.pattern
        if (p == CanvasBackground.Pattern.NONE) return
        patternPaint.color = if (bg.isDark) 0xFF707070.toInt() else 0xFFA8A8A8.toInt()
        val x0 = v.x
        val y0 = v.y
        val x1 = v.x + w / v.zoom
        val y1 = v.y + h / v.zoom
        fun each(from: Double, to: Double, step: Double, body: (Double) -> Unit) {
            if (step * v.zoom < 8 || (to - from) / step > 2_000) return
            var t = Math.floor(from / step) * step
            while (t <= to) { body(t); t += step }
        }
        if (p == CanvasBackground.Pattern.DOTS) {
            each(y0, y1, p.minor) { y -> each(x0, x1, p.minor) { x -> c.drawCircle(v.toViewX(x), v.toViewY(y), 1.8f, patternPaint) } }
            return
        }
        fun lines(step: Double, width: Float, minGap: Double) {
            if (step * v.zoom < minGap) return
            patternPaint.strokeWidth = width
            each(x0, x1, step) { x -> c.drawLine(v.toViewX(x), 0f, v.toViewX(x), h.toFloat(), patternPaint) }
            each(y0, y1, step) { y -> c.drawLine(0f, v.toViewY(y), w.toFloat(), v.toViewY(y), patternPaint) }
        }
        if (p.major > 0) {
            // Graph/engineering paper: on e-ink, minor lines only when zoomed in enough to be
            // a guide (≥ 24 px apart) and faint; major lines carry the structure.
            val major = patternPaint.color
            patternPaint.color = if (bg.isDark) 0xFF383838.toInt() else 0xFFD0D0D0.toInt()
            lines(p.minor, 1f, 24.0)
            patternPaint.color = major
            lines(p.major, 1.5f, 8.0)
        } else {
            lines(p.minor, 1f, 8.0)
        }
    }

    private val diagramStroke = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; strokeJoin = Paint.Join.ROUND }
    private val diagramFill = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.FILL }
    private val diagramText = Paint(Paint.ANTI_ALIAS_FLAG).apply { textAlign = Paint.Align.CENTER }

    /**
     * The Mac's diagram in monochrome: shapes filled with paper and outlined
     * in ink, bold labels, the Mac's routed connectors (dashed for async and
     * events) with an arrow at the target. Drawn under the ink, as on the Mac.
     */
    private fun drawDiagram(c: Canvas, d: app.inkbridge.core.canvas.DiagramSnapshot, v: Viewport) {
        if (d.isEmpty) return
        val ink = if (dark) Color.WHITE else Color.BLACK
        val paper = if (dark) Color.BLACK else Color.WHITE
        diagramStroke.color = ink
        diagramText.color = ink
        diagramStroke.strokeWidth = maxOf(1.5f, (1.6 * v.zoom).toFloat())
        for (e in d.edges) {
            if (e.points.size < 4) continue
            val path = android.graphics.Path()
            path.moveTo(v.toViewX(e.points[0]), v.toViewY(e.points[1]))
            for (i in 2 until e.points.size step 2) path.lineTo(v.toViewX(e.points[i]), v.toViewY(e.points[i + 1]))
            diagramStroke.pathEffect = if (e.dashed) android.graphics.DashPathEffect(floatArrayOf(10f, 7f), 0f) else null
            c.drawPath(path, diagramStroke)
            diagramStroke.pathEffect = null
            val n = e.points.size
            val ax = v.toViewX(e.points[n - 4]); val ay = v.toViewY(e.points[n - 3])
            val bx = v.toViewX(e.points[n - 2]); val by = v.toViewY(e.points[n - 1])
            val ang = Math.atan2((by - ay).toDouble(), (bx - ax).toDouble())
            val len = 14f
            val head = android.graphics.Path().apply {
                moveTo(bx, by)
                lineTo((bx - len * Math.cos(ang - 0.4)).toFloat(), (by - len * Math.sin(ang - 0.4)).toFloat())
                lineTo((bx - len * Math.cos(ang + 0.4)).toFloat(), (by - len * Math.sin(ang + 0.4)).toFloat())
                close()
            }
            diagramFill.color = ink
            c.drawPath(head, diagramFill)
            if (e.label.isNotEmpty()) {
                diagramText.textSize = (11 * v.zoom).toFloat().coerceIn(14f, 26f)
                diagramText.typeface = android.graphics.Typeface.DEFAULT
                val mid = n / 4 * 2
                c.drawText(e.label, v.toViewX(e.points[mid]), v.toViewY(e.points[mid + 1]) - 8, diagramText)
            }
        }
        diagramText.typeface = android.graphics.Typeface.DEFAULT_BOLD
        for (node in d.nodes) {
            val r = android.graphics.RectF(v.toViewX(node.x), v.toViewY(node.y), v.toViewX(node.x + node.w), v.toViewY(node.y + node.h))
            val shape = shapePath(node.shape, r, v.zoom.toFloat())
            diagramFill.color = paper
            c.drawPath(shape, diagramFill)
            c.drawPath(shape, diagramStroke)
            if (node.shape == "cylinder") {
                val h = minOf(r.height() * 0.18f, 14f * v.zoom.toFloat())
                c.drawOval(android.graphics.RectF(r.left, r.top, r.right, r.top + 2 * h), diagramStroke)
            }
            diagramText.textSize = (13 * v.zoom).toFloat().coerceIn(14f, 30f)
            c.drawText(ellipsize(node.label, diagramText, r.width() - 8), r.centerX(), r.centerY() + diagramText.textSize / 3, diagramText)
        }
    }

    private fun shapePath(shape: String, r: android.graphics.RectF, zoom: Float): android.graphics.Path = android.graphics.Path().apply {
        val cw = android.graphics.Path.Direction.CW
        when (shape) {
            "box" -> addRect(r, cw)
            "stadium", "queue" -> addRoundRect(r, r.height() / 2, r.height() / 2, cw)
            "diamond" -> { moveTo(r.centerX(), r.top); lineTo(r.right, r.centerY()); lineTo(r.centerX(), r.bottom); lineTo(r.left, r.centerY()); close() }
            "parallelogram" -> { val k = r.width() * 0.12f; moveTo(r.left + k, r.top); lineTo(r.right, r.top); lineTo(r.right - k, r.bottom); lineTo(r.left, r.bottom); close() }
            "hexagon" -> { val k = r.width() * 0.2f; moveTo(r.left + k, r.top); lineTo(r.right - k, r.top); lineTo(r.right, r.centerY()); lineTo(r.right - k, r.bottom); lineTo(r.left + k, r.bottom); lineTo(r.left, r.centerY()); close() }
            "cloud" -> addOval(r, cw)
            "note" -> { val k = minOf(16f * zoom, r.width() * 0.12f); moveTo(r.left, r.top); lineTo(r.right - k, r.top); lineTo(r.right, r.top + k); lineTo(r.right, r.bottom); lineTo(r.left, r.bottom); close() }
            "cylinder" -> {
                val h = minOf(r.height() * 0.18f, 14f * zoom)
                moveTo(r.left, r.top + h); lineTo(r.left, r.bottom - h)
                quadTo(r.centerX(), r.bottom + h, r.right, r.bottom - h); lineTo(r.right, r.top + h)
                quadTo(r.centerX(), r.top - h, r.left, r.top + h)
            }
            else -> { val k = minOf(10f * zoom, r.height() / 4); addRoundRect(r, k, k, cw) }
        }
    }

    private fun ellipsize(s: String, p: Paint, max: Float): String {
        if (max <= 0 || p.measureText(s) <= max) return s
        var n = s.length
        while (n > 1 && p.measureText(s, 0, n) + p.measureText("…") > max) n--
        return s.take(n) + "…"
    }

    /** Copies the cache to the surface; [dirty] null means the whole surface. */
    private fun post(h: SurfaceHolder, dirty: Rect?, timed: Boolean = false) {
        val bmp = cache ?: return
        val t0 = System.nanoTime()
        val canvas = (if (dirty != null) h.lockCanvas(dirty) else h.lockCanvas()) ?: return
        val t1 = System.nanoTime()
        try {
            canvas.drawBitmap(bmp, 0f, 0f, null)
        } finally {
            h.unlockCanvasAndPost(canvas)
        }
        if (timed) {
            lockTime.add((t1 - t0) / 1e6)
            postTime.add((System.nanoTime() - t1) / 1e6)
        }
    }

    private fun drawSegments(c: Canvas, pts: List<InkPoint>, style: WireStyle, tool: Tool, v: Viewport, from: Int): Rect =
        InkPainter.drawSegments(c, paint, if (from == 0) pts else pts.subList(from, pts.size), style, tool, v, dark)

}
