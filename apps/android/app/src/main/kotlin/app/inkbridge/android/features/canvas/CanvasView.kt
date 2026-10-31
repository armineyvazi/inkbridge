package app.inkbridge.android.features.canvas

import android.content.Context
import android.util.AttributeSet
import android.view.MotionEvent
import android.view.ScaleGestureDetector
import android.view.SurfaceHolder
import android.view.SurfaceView
import app.inkbridge.android.features.drawing.StylusDiagnostics
import app.inkbridge.android.input.AndroidMotionEventSource
import app.inkbridge.core.canvas.Viewport

/**
 * The tablet's drawing surface: **pen draws, fingers navigate.**
 *
 * - Stylus (and eraser end) events go straight to [source], which forwards
 *   them to the network before anything is drawn.
 * - One finger pans, two fingers pinch-zoom around the fingers' midpoint.
 *   While the gesture runs the renderer shows a transformed preview; the
 *   final viewport is committed on lift (one full redraw, one network update).
 */
class CanvasView @JvmOverloads constructor(context: Context, attrs: AttributeSet? = null) :
    SurfaceView(context, attrs), SurfaceHolder.Callback {

    var source: AndroidMotionEventSource? = null
    var renderer: CanvasRenderer? = null
    val diagnostics = StylusDiagnostics.shared
    /** Off: fingers do nothing (for people who rest their hand on the screen). */
    var fingerNavigation = true
    var onSurfaceChanged: ((Int, Int) -> Unit)? = null
    var onDiagnostics: ((String) -> Unit)? = null
    /** Viewport changes from gestures; [final] is true when the gesture ends. */
    var onViewport: ((Viewport, Boolean) -> Unit)? = null
    /** The committed viewport (the one strokes are converted with). */
    var viewport: Viewport = Viewport.HOME

    private var gestureViewport: Viewport? = null
    private var lastFocusX = 0f
    private var lastFocusY = 0f
    private var lastDiagnosticsAt = 0L

    private val scaleDetector = ScaleGestureDetector(context, object : ScaleGestureDetector.SimpleOnScaleGestureListener() {
        override fun onScale(d: ScaleGestureDetector): Boolean {
            val v = (gestureViewport ?: viewport).zoomedBy(d.scaleFactor.toDouble(), d.focusX, d.focusY)
            gestureViewport = v
            renderer?.preview(v)
            return true
        }
    })

    init {
        holder.addCallback(this)
        isFocusable = true
    }

    override fun surfaceCreated(h: SurfaceHolder) {}

    override fun surfaceChanged(h: SurfaceHolder, format: Int, width: Int, height: Int) {
        renderer?.attach(h, width, height)
        onSurfaceChanged?.invoke(width, height)
    }

    override fun surfaceDestroyed(h: SurfaceHolder) {
        renderer?.detach()
    }

    override fun onTouchEvent(ev: MotionEvent): Boolean {
        val tool = ev.getToolType(0)
        if (tool == MotionEvent.TOOL_TYPE_FINGER) return if (fingerNavigation) navigate(ev) else true
        if (ev.actionMasked == MotionEvent.ACTION_DOWN) {
            // Deliver every input event as it arrives instead of batching to vsync.
            requestUnbufferedDispatch(ev)
        }
        source?.onMotionEvent(ev)
        diagnostics.record(ev)
        publishDiagnostics(ev.actionMasked == MotionEvent.ACTION_UP)
        if (ev.actionMasked == MotionEvent.ACTION_UP) performClick()
        return true
    }

    override fun performClick(): Boolean = super.performClick()

    override fun onHoverEvent(ev: MotionEvent): Boolean {
        diagnostics.record(ev, hovering = true)
        publishDiagnostics(false)
        return true
    }

    private fun navigate(ev: MotionEvent): Boolean {
        scaleDetector.onTouchEvent(ev)
        val (fx, fy) = focus(ev)
        when (ev.actionMasked) {
            MotionEvent.ACTION_DOWN, MotionEvent.ACTION_POINTER_DOWN, MotionEvent.ACTION_POINTER_UP -> {
                // Re-anchor whenever the finger count changes so the view doesn't jump.
                lastFocusX = fx
                lastFocusY = fy
                if (gestureViewport == null) gestureViewport = viewport
            }
            MotionEvent.ACTION_MOVE -> {
                val v = (gestureViewport ?: viewport).pannedBy(fx - lastFocusX, fy - lastFocusY)
                lastFocusX = fx
                lastFocusY = fy
                gestureViewport = v
                renderer?.preview(v)
                onViewport?.invoke(v, false)
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                gestureViewport?.let { v ->
                    gestureViewport = null
                    if (v != viewport) onViewport?.invoke(v, true) else renderer?.setViewport(v)
                }
            }
        }
        return true
    }

    /** Midpoint of all fingers still down (excluding one that is lifting). */
    private fun focus(ev: MotionEvent): Pair<Float, Float> {
        val skip = if (ev.actionMasked == MotionEvent.ACTION_POINTER_UP) ev.actionIndex else -1
        var sx = 0f
        var sy = 0f
        var n = 0
        for (i in 0 until ev.pointerCount) {
            if (i == skip) continue
            sx += ev.getX(i)
            sy += ev.getY(i)
            n++
        }
        return if (n == 0) lastFocusX to lastFocusY else sx / n to sy / n
    }

    private fun publishDiagnostics(force: Boolean) {
        val now = System.nanoTime()
        if (!force && now - lastDiagnosticsAt < 1_000_000_000) return
        lastDiagnosticsAt = now
        onDiagnostics?.invoke(diagnostics.text())
    }
}
