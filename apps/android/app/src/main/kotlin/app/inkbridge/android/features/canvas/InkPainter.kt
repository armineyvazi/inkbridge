package app.inkbridge.android.features.canvas

import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.graphics.Rect
import app.inkbridge.core.canvas.Viewport
import app.inkbridge.core.protocol.InkPoint
import app.inkbridge.core.protocol.Tool
import app.inkbridge.core.protocol.WireStyle

/**
 * How one stroke looks on the tablet. Shared by the canvas renderer and the pen-size
 * preview, so the preview is the real thing, not an approximation.
 *
 * Monochrome for e-ink: colours that read well on a Mac (yellow highlighter) would
 * vanish, so pens draw in ink and highlighters in an opaque grey with a DARKEN blend
 * (LIGHTEN on dark paper). Opaque + darken means overlapping segments and round caps
 * never build up into beads, and the ink underneath stays fully black, like a marker.
 * The eraser shows the band it sweeps at its real radius while the pen is down.
 *
 * Width: `style.width` is canvas px at full pressure; on screen it is `× zoom`.
 * Pen width follows pressure with the Mac's rule (30 % at zero pressure).
 */
object InkPainter {
    /** Width change (view px) that starts a new run: below what the eye sees at e-ink resolution. */
    private const val WIDTH_STEP = 0.35f
    private val DARKEN = PorterDuffXfermode(PorterDuff.Mode.DARKEN)
    private val LIGHTEN = PorterDuffXfermode(PorterDuff.Mode.LIGHTEN)

    fun newPaint() = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeCap = Paint.Cap.ROUND
        strokeJoin = Paint.Join.ROUND
    }

    fun configure(paint: Paint, tool: Tool, dark: Boolean) {
        paint.xfermode = null
        when (tool) {
            Tool.PEN -> paint.color = if (dark) Color.WHITE else Color.BLACK
            Tool.HIGHLIGHTER -> {
                paint.color = if (dark) 0xFF5C5C5C.toInt() else 0xFFBDBDBD.toInt()
                paint.xfermode = if (dark) LIGHTEN else DARKEN
            }
            Tool.ERASER -> {
                paint.color = if (dark) 0xFF3A3A3A.toInt() else 0xFFDCDCDC.toInt()
                paint.xfermode = if (dark) LIGHTEN else DARKEN
            }
            Tool.LASER -> paint.color = if (dark) Color.LTGRAY else Color.DKGRAY
        }
    }

    /** On-screen width of a segment, in view px. */
    fun width(style: WireStyle, tool: Tool, zoom: Double, pressure: Double): Float {
        val base = (style.width * zoom).toFloat()
        return when (tool) {
            // Eraser size is a radius: the band is its diameter.
            Tool.ERASER -> maxOf(2 * base, 2f)
            Tool.LASER -> 2f
            Tool.PEN -> maxOf(base * (0.3f + 0.7f * pressure.toFloat().coerceIn(0f, 1f)), 1f)
            Tool.HIGHLIGHTER -> maxOf(base, 1f)
        }
    }

    /** Draws [pts] (canvas px) as round-capped segments; returns the touched rect in view px. */
    fun drawSegments(c: Canvas, paint: Paint, pts: List<InkPoint>, style: WireStyle, tool: Tool, v: Viewport, dark: Boolean): Rect {
        val r = Rect()
        if (pts.isEmpty()) return r
        configure(paint, tool, dark)
        var px = v.toViewX(pts[0].x)
        var py = v.toViewY(pts[0].y)
        if (pts.size == 1) {
            val w = width(style, tool, v.zoom, pts[0].p)
            paint.strokeWidth = w
            c.drawPoint(px, py, paint)
            val pad = w / 2 + 2
            r.union(Rect((px - pad).toInt(), (py - pad).toInt(), (px + pad).toInt() + 1, (py + pad).toInt() + 1))
            return r
        }
        // Consecutive segments of (almost) the same width go into one Path, so joints are real
        // line joins. Drawing each segment with its own round caps overlapped the anti-aliased
        // caps at every sample and left a notched edge on thick lines.
        val path = android.graphics.Path()
        var runWidth = -1f
        path.moveTo(px, py)
        for (i in 1 until pts.size) {
            val x = v.toViewX(pts[i].x)
            val y = v.toViewY(pts[i].y)
            val w = width(style, tool, v.zoom, (pts[i - 1].p + pts[i].p) / 2)
            if (runWidth < 0) runWidth = w
            if (Math.abs(w - runWidth) > WIDTH_STEP) {
                paint.strokeWidth = runWidth
                c.drawPath(path, paint)
                path.rewind()
                path.moveTo(px, py)
                runWidth = w
            }
            path.lineTo(x, y)
            val pad = w / 2 + 2
            r.union(Rect((minOf(px, x) - pad).toInt(), (minOf(py, y) - pad).toInt(), (maxOf(px, x) + pad).toInt() + 1, (maxOf(py, y) + pad).toInt() + 1))
            px = x
            py = y
        }
        paint.strokeWidth = runWidth
        c.drawPath(path, paint)
        return r
    }
}
