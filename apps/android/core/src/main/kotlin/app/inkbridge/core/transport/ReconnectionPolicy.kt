package app.inkbridge.core.transport

import kotlin.math.min
import kotlin.math.pow
import kotlin.random.Random

/**
 * Exponential backoff with jitter, capped low.
 *
 * The cap is 2 s because the target is "reconnected within 3 s" after a
 * cable replug or Wi-Fi blip, and there is only ever one client per host,
 * so retry storms are not a concern. Jitter still avoids lockstep retries
 * with the host's own timers.
 */
class ReconnectionPolicy(
    private val initialMs: Long = 250,
    private val maxMs: Long = 2_000,
    private val multiplier: Double = 2.0,
    private val jitter: Double = 0.2,
    private val random: Random = Random.Default,
) {
    /** Delay before attempt number [attempt] (1-based). */
    fun delayFor(attempt: Int): Long {
        require(attempt >= 1)
        val base = min(maxMs.toDouble(), initialMs * multiplier.pow(attempt - 1))
        val spread = base * jitter
        return (base - spread + random.nextDouble() * 2 * spread).toLong().coerceIn(0, maxMs)
    }
}
