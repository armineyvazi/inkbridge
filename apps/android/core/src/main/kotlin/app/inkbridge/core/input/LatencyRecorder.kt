package app.inkbridge.core.input

/**
 * Fixed-size ring of latency samples (ms) with percentiles. Thread-safe.
 * Used for on-device diagnostics: sample → ink posted, render time per frame.
 */
class LatencyRecorder(private val capacity: Int = 2_000) {
    private val values = DoubleArray(capacity)
    private var count = 0
    private var next = 0

    @Synchronized fun add(ms: Double) {
        values[next] = ms
        next = (next + 1) % capacity
        if (count < capacity) count++
    }

    @Synchronized fun percentile(p: Double): Double? {
        if (count == 0) return null
        val sorted = values.copyOf(count).also { it.sort() }
        return sorted[((count - 1) * p).toInt().coerceIn(0, count - 1)]
    }

    @Synchronized fun reset() { count = 0; next = 0 }

    val size: Int @Synchronized get() = count

    fun summary(): String {
        val p50 = percentile(0.5) ?: return "n/a"
        return "p50 %.1f · p95 %.1f · p99 %.1f ms (n=%d)".format(p50, percentile(0.95)!!, percentile(0.99)!!, size)
    }
}
