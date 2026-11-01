package app.inkbridge.core.canvas

/**
 * The visible region of the infinite canvas (ADR-006).
 *
 * [x], [y]: the canvas point at the view's top-left corner. [zoom]: view px
 * per canvas px. Stroke data is stored in canvas px and never changes when
 * the viewport does. Mirrors `Viewport` in the Swift core.
 */
data class Viewport(val x: Double = 0.0, val y: Double = 0.0, val zoom: Double = 1.0) {
    fun toCanvasX(viewX: Float): Double = x + viewX / zoom
    fun toCanvasY(viewY: Float): Double = y + viewY / zoom
    fun toViewX(canvasX: Double): Float = ((canvasX - x) * zoom).toFloat()
    fun toViewY(canvasY: Double): Float = ((canvasY - y) * zoom).toFloat()

    /** Zooms by [factor], keeping the canvas point under ([fx], [fy]) view px fixed. */
    fun zoomedBy(factor: Double, fx: Float, fy: Float): Viewport {
        val z = (zoom * factor).coerceIn(ZOOM_RANGE)
        val cx = x + fx / zoom
        val cy = y + fy / zoom
        return Viewport(cx - fx / z, cy - fy / z, z)
    }

    /** Moves the view by a finger drag of ([dx], [dy]) view px (content follows the finger). */
    fun pannedBy(dx: Float, dy: Float): Viewport = copy(x = x - dx / zoom, y = y - dy / zoom)

    companion object {
        val HOME = Viewport()
        val ZOOM_RANGE = 0.02..50.0

        /** The viewport that shows [bounds] (canvas px) in a [viewW]×[viewH] view with a margin. */
        fun fitting(bounds: Bounds, viewW: Int, viewH: Int, margin: Double = 0.05): Viewport {
            if (bounds.isEmpty || viewW <= 0 || viewH <= 0) return HOME
            val usable = 1 - 2 * margin
            val zx = if (bounds.width > 0) viewW * usable / bounds.width else Double.POSITIVE_INFINITY
            val zy = if (bounds.height > 0) viewH * usable / bounds.height else Double.POSITIVE_INFINITY
            // Fit shows everything; it never magnifies past actual size (a few short
            // strokes would otherwise fill the screen at 1000 %+).
            val z = minOf(zx, zy, 1.0).coerceIn(ZOOM_RANGE)
            return Viewport(bounds.centerX - viewW / z / 2, bounds.centerY - viewH / z / 2, z)
        }
    }
}

/** Axis-aligned box in canvas px. */
data class Bounds(val minX: Double, val minY: Double, val maxX: Double, val maxY: Double) {
    val width get() = maxX - minX
    val height get() = maxY - minY
    val centerX get() = (minX + maxX) / 2
    val centerY get() = (minY + maxY) / 2
    val isEmpty get() = minX > maxX || minY > maxY

    fun union(o: Bounds) = if (isEmpty) o else if (o.isEmpty) this else
        Bounds(minOf(minX, o.minX), minOf(minY, o.minY), maxOf(maxX, o.maxX), maxOf(maxY, o.maxY))

    fun inflate(d: Double) = Bounds(minX - d, minY - d, maxX + d, maxY + d)

    fun intersects(o: Bounds) = !isEmpty && !o.isEmpty && minX <= o.maxX && o.minX <= maxX && minY <= o.maxY && o.minY <= maxY

    companion object {
        val EMPTY = Bounds(Double.POSITIVE_INFINITY, Double.POSITIVE_INFINITY, Double.NEGATIVE_INFINITY, Double.NEGATIVE_INFINITY)
    }
}
