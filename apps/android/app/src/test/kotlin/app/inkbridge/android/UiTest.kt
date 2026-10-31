package app.inkbridge.android

import android.content.Intent
import android.net.Uri
import android.view.View
import android.view.ViewGroup
import android.widget.EditText
import android.widget.TextView
import androidx.test.core.app.ApplicationProvider
import app.inkbridge.android.features.canvas.CanvasActivity
import app.inkbridge.android.features.canvas.CanvasView
import app.inkbridge.android.features.connect.ConnectActivity
import app.inkbridge.android.features.dashboard.DashboardActivity
import app.inkbridge.android.features.diagnostics.DiagnosticsActivity
import app.inkbridge.android.features.settings.AppSettings
import app.inkbridge.android.features.settings.SettingsActivity
import app.inkbridge.core.connection.ConnectionMode
import app.inkbridge.core.input.PressureResponse
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowLooper
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Screen tests on the JVM (Robolectric, API 30 = the Note Air 2 Plus's
 * Android 11). They check structure, wording, navigation and state
 * changes. E-ink refresh, stylus feel and real Wi-Fi need the tablet; see
 * docs/testing/android-ui-tests.md for what is covered where.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [30])
class UiTest {
    private val app get() = ApplicationProvider.getApplicationContext<InkBridgeApp>()

    @Before
    fun reset() {
        app.getSharedPreferences("inkbridge", 0).edit().clear().commit()
        app.getSharedPreferences("inkbridge-pairing", 0).edit().clear().commit()
        app.connection.update(AppSettings())
        app.connection.forgetMac()
    }

    private fun View.texts(): List<String> = when (this) {
        is EditText -> listOf(text.toString())
        is TextView -> listOf(text.toString())
        is ViewGroup -> (0 until childCount).flatMap { getChildAt(it).texts() }
        else -> emptyList()
    }

    private fun View.find(pred: (View) -> Boolean): View? {
        if (pred(this)) return this
        if (this is ViewGroup) for (i in 0 until childCount) getChildAt(i).find(pred)?.let { return it }
        return null
    }

    private fun View.byLabel(label: String) = find { it.contentDescription == label && it.isClickable }
        ?: find { it is TextView && it.text.toString() == label && it.isClickable }
        ?: error("no control '$label' in ${texts()}")

    private fun View.edits(): List<EditText> = buildList {
        fun walk(v: View) { if (v is EditText) add(v); if (v is ViewGroup) for (i in 0 until v.childCount) walk(v.getChildAt(i)) }
        walk(this@edits)
    }

    private fun idle() = ShadowLooper.idleMainLooper()

    @Test
    fun dashboardWhenNotPairedLeadsToConnect() {
        val a = Robolectric.buildActivity(DashboardActivity::class.java).setup().get()
        idle()
        val root = a.window.decorView
        assertTrue("Not connected" in root.texts(), root.texts().toString())
        assertTrue("Not paired" in root.texts())
        root.byLabel("Connect to Mac").performClick()
        assertEquals(ConnectActivity::class.java.name, shadowOf(a).nextStartedActivity.component?.className)
    }

    @Test
    fun dashboardNavigatesToSettingsDiagnosticsAndOfflineCanvas() {
        val a = Robolectric.buildActivity(DashboardActivity::class.java).setup().get()
        idle()
        val root = a.window.decorView
        root.byLabel("Settings").performClick()
        assertEquals(SettingsActivity::class.java.name, shadowOf(a).nextStartedActivity.component?.className)
        root.byLabel("Diagnostics").performClick()
        assertEquals(DiagnosticsActivity::class.java.name, shadowOf(a).nextStartedActivity.component?.className)
        root.byLabel("Draw offline").performClick()
        assertEquals(CanvasActivity::class.java.name, shadowOf(a).nextStartedActivity.component?.className)
    }

    @Test
    fun settingsApplyImmediatelyAndPersist() {
        val a = Robolectric.buildActivity(SettingsActivity::class.java).setup().get()
        val root = a.window.decorView
        listOf("Connection", "Drawing", "Display", "Application").forEach { assertTrue(it.uppercase() in root.texts(), it) }
        root.byLabel("USB cable").performClick()
        root.byLabel("Firm").performClick()
        idle()
        val saved = AppSettings.load(app)
        assertEquals(ConnectionMode.USB, saved.mode)
        assertEquals(PressureResponse.FIRM, saved.pressure)
        assertEquals(PressureResponse.FIRM, app.connection.settings.pressure)
    }

    @Test
    fun manualPairingFormatsTheCodeAndStartsPairing() {
        val a = Robolectric.buildActivity(ConnectActivity::class.java).setup().get()
        var root = a.window.decorView
        assertTrue("Pair with your Mac" in root.texts())
        root.byLabel("Enter the Mac's address").performClick()
        root = a.window.decorView
        val (host, port) = root.edits()
        host.setText("192.168.1.20")
        port.setText("8766")
        root.byLabel("Continue").performClick()
        root = a.window.decorView
        assertTrue("Enter the code" in root.texts())
        val code = root.edits().single()
        code.setText("k7qw m3xp")
        assertEquals("K7QW-M3XP", code.text.toString(), "typed codes are normalised as you type")
        root.byLabel("Pair").performClick()
        val req = assertNotNull(app.connection.pairing.value)
        assertEquals("K7QWM3XP", req.code)
        assertEquals("192.168.1.20", req.address)
        assertNull(req.pin, "a typed code has no pin; the TLS fingerprint is bound into the proof instead")
    }

    @Test
    fun shortCodeIsRejectedLocally() {
        val a = Robolectric.buildActivity(ConnectActivity::class.java).setup().get()
        a.window.decorView.byLabel("Enter the Mac's address").performClick()
        a.window.decorView.edits()[0].setText("10.0.0.5")
        a.window.decorView.byLabel("Continue").performClick()
        a.window.decorView.edits().single().setText("K7Q")
        a.window.decorView.byLabel("Pair").performClick()
        assertTrue("The code has 8 characters." in a.window.decorView.texts())
        assertNull(app.connection.pairing.value)
    }

    @Test
    fun qrLinkAsksBeforePairingThenPinsTheCertificate() {
        val exp = System.currentTimeMillis() / 1000 + 300
        val fp = "a0a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbcbdbebf"
        val link = "inkbridge://pair?v=3&name=Studio%20Mac&id=h1&addr=192.168.1.20&port=8766&code=K7QWM3XP&fp=$fp&exp=$exp"
        val a = Robolectric.buildActivity(ConnectActivity::class.java, Intent(Intent.ACTION_VIEW, Uri.parse(link))).setup().get()
        assertNull(app.connection.pairing.value, "a link alone must never start pairing")
        assertTrue("Pair with Studio Mac?" in a.window.decorView.texts())
        assertTrue("A0:A1:A2:A3:A4:A5:A6:A7" in a.window.decorView.texts(), "certificate shown for comparison")
        a.window.decorView.byLabel("Pair").performClick()
        val req = assertNotNull(app.connection.pairing.value)
        assertEquals("Studio Mac", req.name)
        assertEquals(fp, req.pin!!.joinToString("") { "%02x".format(it) })
    }

    @Test
    fun qrLinkToAPublicAddressIsRefused() {
        val exp = System.currentTimeMillis() / 1000 + 300
        val link = "inkbridge://pair?v=3&name=M&id=h1&addr=8.8.8.8&port=8766&code=K7QWM3XP&fp=${"a0".repeat(32)}&exp=$exp"
        val a = Robolectric.buildActivity(ConnectActivity::class.java, Intent(Intent.ACTION_VIEW, Uri.parse(link))).setup().get()
        assertTrue(a.window.decorView.texts().any { it.contains("local network") })
        assertNull(app.connection.pairing.value)
    }

    @Test
    fun expiredQrLinkExplainsWhatToDo() {
        val fp = "a0".repeat(32)
        val link = "inkbridge://pair?v=3&name=M&id=h1&addr=10.0.0.2&port=8766&code=K7QWM3XP&fp=$fp&exp=1"
        val a = Robolectric.buildActivity(ConnectActivity::class.java, Intent(Intent.ACTION_VIEW, Uri.parse(link))).setup().get()
        assertTrue(a.window.decorView.texts().any { it.contains("expired") })
        assertNull(app.connection.pairing.value)
    }

    @Test
    fun canvasIsFullScreenWithCompactControls() {
        val a = Robolectric.buildActivity(CanvasActivity::class.java).setup().get()
        idle()
        val root = a.window.decorView
        val canvas = assertNotNull(root.find { it is CanvasView })
        assertEquals(ViewGroup.LayoutParams.MATCH_PARENT, canvas.layoutParams.width)
        assertEquals(ViewGroup.LayoutParams.MATCH_PARENT, canvas.layoutParams.height)
        listOf("Undo", "Redo", "Zoom in", "Zoom out", "Fit all ink", "More", "Connection status").forEach { root.byLabel(it) }
        root.byLabel("Zoom in").performClick()
        assertTrue("150%" in root.texts())
    }

    @Test
    fun diagnosticsNeverShowsSecrets() {
        val a = Robolectric.buildActivity(DiagnosticsActivity::class.java).setup().get()
        idle()
        val text = a.window.decorView.texts().joinToString("\n")
        assertTrue("connection" in text && "protocol" in text)
        assertTrue("token" !in text.lowercase())
    }
}
