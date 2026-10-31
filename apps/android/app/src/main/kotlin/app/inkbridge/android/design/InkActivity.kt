package app.inkbridge.android.design

import android.content.Intent
import android.os.Bundle
import android.view.View
import androidx.activity.ComponentActivity
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import app.inkbridge.android.connection
import app.inkbridge.android.features.connection.ConnectionManager
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.launch

/**
 * Base for every screen: no transition animations (each animation frame is
 * an e-ink refresh, and they ghost), text size from settings, and a helper
 * to observe flows only while visible.
 */
abstract class InkActivity : ComponentActivity() {
    protected val manager: ConnectionManager get() = connection

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Ink.textScale = manager.settings.textSize.scale
        @Suppress("DEPRECATION")
        overridePendingTransition(0, 0)
    }

    override fun finish() {
        super.finish()
        @Suppress("DEPRECATION")
        overridePendingTransition(0, 0)
    }

    /** Collects [flow] while the screen is started; UI updates stop when hidden. */
    protected fun <T> observe(flow: Flow<T>, body: (T) -> Unit) {
        lifecycleScope.launch { repeatOnLifecycle(Lifecycle.State.STARTED) { flow.collect { body(it) } } }
    }

    protected inline fun <reified A : InkActivity> open(configure: Intent.() -> Unit = {}) {
        startActivity(Intent(this, A::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NO_ANIMATION)
            configure()
        })
    }

    /** Clears e-ink ghosting: one frame of solid ink over the screen, then the real content. */
    fun cleanRefresh() = EInk.flash(window.decorView)
}

object EInk {
    /**
     * A full-screen black frame for ~120 ms forces the panel through a full
     * waveform, which is how e-ink readers clean ghosting. Uses only standard
     * views, so it works on any device; BOOX's own refresh API is not used
     * because its compatibility with the Note Air 3 is unverified
     * (docs/design/eink-design-considerations.md).
     */
    fun flash(root: View) {
        val group = root as? android.view.ViewGroup ?: return
        val cover = View(root.context).apply { setBackgroundColor(Ink.INK) }
        group.addView(cover, android.view.ViewGroup.LayoutParams(-1, -1))
        root.postDelayed({ group.removeView(cover) }, 120)
    }
}
