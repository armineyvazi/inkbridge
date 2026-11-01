package app.inkbridge.core.canvas

/**
 * The background layer of the shared canvas. Mirrors CanvasBackground.swift:
 * [mode] overlay (transparent over the Mac desktop) or studio (an opaque
 * surface in [argb]); [pattern] paper lines anchored to canvas px.
 *
 * Part of the document, owned by the Mac: the tablet shows a monochrome
 * rendering of it ([einkPaper]) but never changes the stored colour.
 */
data class CanvasBackground(
    val mode: Mode = Mode.OVERLAY,
    val argb: Int = WHITE,
    val pattern: Pattern = Pattern.NONE,
) {
    enum class Mode(val wire: String) {
        OVERLAY("overlay"), STUDIO("studio");

        companion object {
            fun fromWire(s: String) = entries.firstOrNull { it.wire == s }
        }
    }

    /** Spacing in canvas px: minor lines, and major lines (0 = none). Same as the Mac. */
    enum class Pattern(val wire: String, val minor: Double, val major: Double) {
        NONE("none", 0.0, 0.0),
        GRID("grid", 48.0, 0.0),
        DOTS("dots", 48.0, 0.0),
        GRAPH("graph", 12.0, 60.0),
        ENGINEERING("engineering", 10.0, 100.0);

        companion object {
            fun fromWire(s: String) = entries.firstOrNull { it.wire == s }
        }
    }

    /** Relative luminance 0..1 (sRGB approximation, as on the Mac). */
    val luminance: Double
        get() {
            val r = (argb shr 16 and 0xff) / 255.0
            val g = (argb shr 8 and 0xff) / 255.0
            val b = (argb and 0xff) / 255.0
            return 0.2126 * r + 0.7152 * g + 0.0722 * b
        }

    val isDark: Boolean get() = mode == Mode.STUDIO && luminance < 0.5

    /**
     * The grey this background is shown as on a monochrome e-ink panel:
     * white for the overlay, otherwise the colour's luminance quantised to
     * the panel's 16 grey levels, snapped to pure white/black near the ends so
     * "Light gray" stays clean paper and "Dark gray" stays solid.
     */
    val einkPaper: Int
        get() {
            if (mode == Mode.OVERLAY) return WHITE
            val l = luminance
            val v = when {
                l >= 0.9 -> 255
                l <= 0.2 -> 0
                else -> ((l * 15).toInt() * 17).coerceIn(0, 255)
            }
            return (0xFF shl 24) or (v shl 16) or (v shl 8) or v
        }

    companion object {
        const val WHITE = 0xFFFFFFFF.toInt()
        const val BLACK = 0xFF000000.toInt()
        const val LIGHT_GRAY = 0xFFF2F2F2.toInt()
        const val DARK_GRAY = 0xFF202020.toInt()
        val OVERLAY = CanvasBackground()
        fun studio(argb: Int, pattern: Pattern = Pattern.NONE) = CanvasBackground(Mode.STUDIO, argb, pattern)
    }
}
