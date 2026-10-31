package app.inkbridge.android

import android.graphics.Bitmap
import android.graphics.Canvas
import android.view.View
import androidx.test.core.app.ApplicationProvider
import app.inkbridge.android.features.canvas.CanvasActivity
import app.inkbridge.android.features.connect.ConnectActivity
import app.inkbridge.android.features.dashboard.DashboardActivity
import app.inkbridge.android.features.diagnostics.DiagnosticsActivity
import app.inkbridge.android.features.settings.SettingsActivity
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import org.robolectric.shadows.ShadowLooper
import java.io.File

/**
 * Renders each screen at the BOOX Note Air's size (1404×1872 px, 240 dpi)
 * to PNGs for design review. Skipped unless -Dinkbridge.screenshots=DIR is
 * set (`make screenshots`); these are pictures, not assertions.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [30], qualifiers = "w585dp-h780dp-port-hdpi")
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class ScreenshotTest {
    private val out = System.getProperty("inkbridge.screenshots")?.let(::File)

    private fun shoot(name: String, root: View) {
        val dir = out ?: return
        ShadowLooper.idleMainLooper()
        val w = 1404
        val h = 1872
        root.measure(View.MeasureSpec.makeMeasureSpec(w, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(h, View.MeasureSpec.EXACTLY))
        root.layout(0, 0, w, h)
        val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        bmp.eraseColor(android.graphics.Color.WHITE)
        root.draw(Canvas(bmp))
        dir.mkdirs()
        File(dir, "$name.png").outputStream().use { bmp.compress(Bitmap.CompressFormat.PNG, 100, it) }
    }

    @Test
    fun screens() {
        assumeTrue(out != null)
        val app = ApplicationProvider.getApplicationContext<InkBridgeApp>()
        app.connection.forgetMac()
        shoot("1-dashboard", Robolectric.buildActivity(DashboardActivity::class.java).setup().get().window.decorView)
        val connect = Robolectric.buildActivity(ConnectActivity::class.java).setup().get()
        shoot("2-connect", connect.window.decorView)
        connect.window.decorView.let { root ->
            fun find(v: View, label: String): View? = if (v.contentDescription == label) v else (v as? android.view.ViewGroup)?.let { g -> (0 until g.childCount).firstNotNullOfOrNull { find(g.getChildAt(it), label) } }
            find(root, "Enter the Mac's address")?.performClick()
            find(root, "Continue")?.let { c ->
                (root.findViewsWithText("IP address")); c
            }
        }
        shoot("3-manual", connect.window.decorView)
        shoot("4-settings", Robolectric.buildActivity(SettingsActivity::class.java).setup().get().window.decorView)
        shoot("5-diagnostics", Robolectric.buildActivity(DiagnosticsActivity::class.java).setup().get().window.decorView)
        shoot("6-canvas", Robolectric.buildActivity(CanvasActivity::class.java).setup().get().window.decorView)
    }
}

private fun View.findViewsWithText(s: String) = ArrayList<View>().also { findViewsWithText(it, s, View.FIND_VIEWS_WITH_TEXT) }
