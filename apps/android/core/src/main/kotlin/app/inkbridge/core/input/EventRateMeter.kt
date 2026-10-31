package app.inkbridge.core.input

/**
 * Measures sample frequency over a sliding window of timestamps (ns).
 * Used by the diagnostics view to report the digitizer's real report rate,
 * counting historical samples, not just delivered MotionEvents.
 */
class EventRateMeter(private val windowNs: Long = 1_000_000_000L) {
    private val times = ArrayDeque<Long>()

    fun record(timeNs: Long) {
        times.addLast(timeNs)
        while (times.isNotEmpty() && timeNs - times.first() > windowNs) times.removeFirst()
    }

    /** Samples per second over the window, or 0 with fewer than two samples. */
    val hz: Double
        get() {
            if (times.size < 2) return 0.0
            val span = times.last() - times.first()
            return if (span <= 0) 0.0 else (times.size - 1) * 1e9 / span
        }

    fun reset() = times.clear()
}
