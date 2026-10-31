package app.inkbridge.core.input

import kotlin.math.roundToLong

/**
 * Converts surface pixels to normalized 0..1 coordinates.
 *
 * The surface is the drawing view in its current orientation, so rotation
 * is handled by updating the size (and telling the host via device.surface)
 * rather than by rotating points. Values are clamped to 0..1 because
 * digitizers report samples slightly past the panel edge, and rounded to
 * 1e-5 (≈0.02 px on a 1872 px axis) to keep messages short.
 */
class CoordinateNormalizer(width: Int, height: Int) {
    var width: Int = width
        private set
    var height: Int = height
        private set

    init {
        resize(width, height)
    }

    fun resize(width: Int, height: Int) {
        require(width > 0 && height > 0) { "surface must be non-empty, got ${width}x$height" }
        this.width = width
        this.height = height
    }

    fun normalizeX(x: Float): Double = round5((x.toDouble() / width).coerceIn(0.0, 1.0))
    fun normalizeY(y: Float): Double = round5((y.toDouble() / height).coerceIn(0.0, 1.0))

    companion object {
        fun round5(v: Double): Double = (v * 100_000).roundToLong() / 100_000.0
        fun round4(v: Double): Double = (v * 10_000).roundToLong() / 10_000.0
    }
}
