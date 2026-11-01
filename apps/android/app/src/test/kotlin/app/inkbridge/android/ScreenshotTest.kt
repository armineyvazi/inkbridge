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
import app.inkbridge.android.features.canvas.JournalSheet
import app.inkbridge.core.protocol.JournalItem
import app.inkbridge.core.protocol.Payload
import org.junit.Assume.assumeTrue
import app.inkbridge.core.protocol.Tool
import app.inkbridge.core.canvas.ToolSettings
import app.inkbridge.android.features.canvas.PenSheet
import app.inkbridge.android.features.canvas.PenBar
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
        val canvas = Robolectric.buildActivity(CanvasActivity::class.java).setup().get()
        shoot("6-canvas", canvas.window.decorView)
        // The journal sheet as it looks on the tablet (open day, put away on the Mac), over a white frame.
        val sheet = JournalSheet(canvas, { _, _ -> true }, {})
        val t = { h: Int, m: Int -> java.util.Calendar.getInstance().apply { set(2026, 10, 1, h, m, 0) }.timeInMillis }
        sheet.render(Payload.Journal(true, "2026-11-01", true, "Planning the sync engine", listOf(
            JournalItem("1", "ink", "", false, t(9, 15)),
            JournalItem("2", "note", "Offline-first: the tablet never waits for the Mac", false, t(9, 24)),
            JournalItem("3", "task", "Measure input to ink on the BOOX", false, t(10, 2)),
            JournalItem("4", "task", "Book the design review", true, t(10, 5)),
            JournalItem("5", "ink", "", false, t(14, 31)),
        ), 3, hidden = true), connected = true)
        shoot("7-journal", android.widget.FrameLayout(canvas).apply {
            setPadding(160, 160, 160, 160)
            addView(sheet, android.widget.FrameLayout.LayoutParams(-1, -2))
        })
        // Pen-size panel and the toolbar pen group, for each tool.
        for (tool in listOf(Tool.PEN, Tool.HIGHLIGHTER, Tool.ERASER)) {
            val s = ToolSettings(tool = tool, pen = 4.5)
            val pen = PenSheet(canvas, {}, { _, _, _ -> }, {}).apply { render(s, 1.0) }
            val bar = PenBar(canvas, {}, {}, {}).apply { render(s, 1.0) }
            shoot("8-pen-${tool.wire}", android.widget.LinearLayout(canvas).apply {
                orientation = android.widget.LinearLayout.VERTICAL
                setBackgroundColor(android.graphics.Color.WHITE)
                setPadding(160, 120, 160, 160)
                addView(bar, android.widget.LinearLayout.LayoutParams(-2, -2))
                addView(pen, android.widget.LinearLayout.LayoutParams(660, -2).apply { topMargin = 24 })
            })
        }
    }
}

private fun View.findViewsWithText(s: String) = ArrayList<View>().also { findViewsWithText(it, s, View.FIND_VIEWS_WITH_TEXT) }
