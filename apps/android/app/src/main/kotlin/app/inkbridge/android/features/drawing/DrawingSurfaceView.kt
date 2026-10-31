package app.inkbridge.android.features.drawing

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.util.AttributeSet
import android.view.MotionEvent
import android.view.View
import app.inkbridge.android.input.AndroidMotionEventSource

/**
 * The tablet-side drawing surface.
 *
 * Its job is capture, not rendering: every event goes to [source] first
 * and on to the Mac. Local ink is optional feedback; on e-ink each redraw
 * costs a panel refresh, so it draws only the newly added segments into a
 * bitmap and invalidates just their bounds.
 */
class DrawingSurfaceView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
) : View(context, attrs) {
    var source: AndroidMotionEventSource? = null
    val diagnostics = StylusDiagnostics()
    var showLocalInk = false
    /** Surface size changes (first layout, rotation). */
    var onSurfaceChanged: ((Int, Int) -> Unit)? = null
    /** Throttled diagnostics refresh; e-ink cannot redraw text at input rate. */
    var onDiagnostics: ((String) -> Unit)? = null

    private var bitmap: Bitmap? = null
    private var canvas: Canvas? = null
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.BLACK
        style = Paint.Style.STROKE
        strokeCap = Paint.Cap.ROUND
        strokeJoin = Paint.Join.ROUND
    }
    private var lastX = 0f
    private var lastY = 0f
    private var lastDiagnosticsAt = 0L

    init {
        setBackgroundColor(Color.WHITE)
        isFocusable = true
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        if (w <= 0 || h <= 0) return
        bitmap = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888).also { canvas = Canvas(it) }
        onSurfaceChanged?.invoke(w, h)
    }

    fun clear() {
        bitmap?.eraseColor(Color.TRANSPARENT)
        diagnostics.reset()
        invalidate()
    }

    override fun onDraw(c: Canvas) {
        bitmap?.let { c.drawBitmap(it, 0f, 0f, null) }
    }

    override fun onTouchEvent(ev: MotionEvent): Boolean {
        if (ev.actionMasked == MotionEvent.ACTION_DOWN) {
            // Deliver every input event as it arrives instead of batching to vsync;
            // more events, less latency. The cost is more onTouchEvent calls.
            requestUnbufferedDispatch(ev)
        }
        source?.onMotionEvent(ev)
        diagnostics.record(ev)
        if (showLocalInk) drawLocally(ev)
        publishDiagnostics(ev.actionMasked == MotionEvent.ACTION_UP)
        if (ev.actionMasked == MotionEvent.ACTION_UP) performClick()
        return true
    }

    // Lets accessibility services treat a tap on the surface as a click.
    override fun performClick(): Boolean = super.performClick()

    override fun onHoverEvent(ev: MotionEvent): Boolean {
        diagnostics.record(ev, hovering = true)
        publishDiagnostics(false)
        return true
    }

    private fun drawLocally(ev: MotionEvent) {
        val c = canvas ?: return
        if (ev.getToolType(0) == MotionEvent.TOOL_TYPE_FINGER) return
        when (ev.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                lastX = ev.x
                lastY = ev.y
            }
            MotionEvent.ACTION_MOVE, MotionEvent.ACTION_UP -> {
                var minX = lastX; var maxX = lastX; var minY = lastY; var maxY = lastY
                for (i in 0..ev.historySize) {
                    val x = if (i < ev.historySize) ev.getHistoricalX(0, i) else ev.x
                    val y = if (i < ev.historySize) ev.getHistoricalY(0, i) else ev.y
                    val p = if (i < ev.historySize) ev.getHistoricalPressure(0, i) else ev.pressure
                    paint.strokeWidth = 1.5f + 4f * p.coerceIn(0f, 1f)
                    c.drawLine(lastX, lastY, x, y, paint)
                    lastX = x; lastY = y
                    minX = minOf(minX, x); maxX = maxOf(maxX, x); minY = minOf(minY, y); maxY = maxOf(maxY, y)
                }
                val pad = 8
                postInvalidateOnAnimation(minX.toInt() - pad, minY.toInt() - pad, maxX.toInt() + pad, maxY.toInt() + pad)
            }
        }
    }

    private fun publishDiagnostics(force: Boolean) {
        val now = System.nanoTime()
        if (!force && now - lastDiagnosticsAt < 250_000_000) return
        lastDiagnosticsAt = now
        onDiagnostics?.invoke(diagnostics.text())
    }
}
