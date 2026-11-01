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
import app.inkbridge.android.features.connection.PairingStore
import app.inkbridge.android.features.settings.AppSettings
import app.inkbridge.android.features.settings.SettingsActivity
import app.inkbridge.core.connection.ConnectionMode
import app.inkbridge.core.input.PressureResponse
import app.inkbridge.core.input.StylusEvent
import app.inkbridge.core.protocol.Tool
import app.inkbridge.core.protocol.InkPoint
import app.inkbridge.core.protocol.WireStyle
import app.inkbridge.core.canvas.CanvasBackground
import app.inkbridge.core.protocol.Payload
import app.inkbridge.android.features.storage.StorageActivity
import app.inkbridge.core.protocol.StorageState
import app.inkbridge.android.features.canvas.JournalSheet
import app.inkbridge.core.protocol.JournalItem
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowLooper
import kotlin.test.assertEquals
import kotlin.test.assertFalse
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
    fun linkCopyingThePairedMacsIdStillWarnsWhenTheCertificateDiffers() {
        app.getSharedPreferences("inkbridge-pairing", 0).edit()
            .putString("hostId", "real-mac").putString("name", "My Mac").putString("fp", "11".repeat(32))
            .putString("token", "22".repeat(32)).commit()
        val exp = System.currentTimeMillis() / 1000 + 300
        // Same host id as the paired Mac, different certificate: must still warn.
        val link = "inkbridge://pair?v=3&name=My%20Mac&id=real-mac&addr=192.168.1.66&port=8766&code=K7QWM3XP&fp=${"a0".repeat(32)}&exp=$exp"
        val a = buildConnect(link)
        assertTrue("This replaces the pairing with My Mac." in a.window.decorView.texts(), a.window.decorView.texts().toString())
    }

    private fun buildConnect(link: String): ConnectActivity {
        // Reload so the manager sees the pairing written above.
        val m = app.connection
        val f = m.javaClass.getDeclaredField("_paired").apply { isAccessible = true }
        @Suppress("UNCHECKED_CAST")
        (f.get(m) as kotlinx.coroutines.flow.MutableStateFlow<Any?>).value =
            PairingStore(app).load()
        return Robolectric.buildActivity(ConnectActivity::class.java, Intent(Intent.ACTION_VIEW, Uri.parse(link))).setup().get()
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
    fun backgroundPanelSwitchesInstantlyAndKeepsStrokesAndView() {
        val a = Robolectric.buildActivity(CanvasActivity::class.java).setup().get()
        idle()
        val doc = app.connection.document
        doc.applyLocal(StylusEvent.Begin("s-ui", Tool.PEN,
            InkPoint(5.0, 5.0, 1.0, 0)), WireStyle(0, 2.0))
        val root = a.window.decorView
        root.byLabel("Zoom in").performClick()
        root.byLabel("Background").performClick()
        assertTrue("Background" in root.texts() && "Studio canvas" in root.texts())
        root.byLabel("Black background").performClick()
        assertEquals(CanvasBackground.studio(CanvasBackground.BLACK), doc.background)
        root.byLabel("White background").performClick()
        root.byLabel("Graph").performClick()
        assertEquals(CanvasBackground.Pattern.GRAPH, doc.background.pattern)
        root.byLabel("Desktop overlay").performClick()
        assertEquals(CanvasBackground.Mode.OVERLAY, doc.background.mode)
        assertEquals(1, doc.size, "switching backgrounds never touches strokes")
        assertTrue("150%" in root.texts(), "zoom is preserved")
        root.byLabel("Close").performClick()
        assertTrue("Studio canvas" !in root.texts())
    }

    @Test
    fun hostDocumentIsMirroredEvenWhenTheCanvasWasNeverOpened() {
        Robolectric.buildActivity(DashboardActivity::class.java).setup()
        val handler = assertNotNull(app.connection.client.onHostPayload)
        val before = app.connection.document.backgroundRevision
        handler(Payload.Background(CanvasBackground.studio(CanvasBackground.BLACK), before + 1))
        assertEquals(CanvasBackground.BLACK, app.connection.document.background.argb)
    }

    @Test
    fun storageScreenShowsMacLocationAndRefusesChangesWhileOffline() {
        val a0 = Robolectric.buildActivity(StorageActivity::class.java).setup().get()
        idle()
        assertTrue("Not connected yet" in a0.window.decorView.texts())
        app.connection.defaultHostHandler(Payload.Storage(StorageState(
            "System Design", "Payments", "~/Documents/InkBridge/Projects/System Design", "saved", 1_793_448_000_000, null,
            listOf("My Drawings", "System Design"), listOf("~/Documents/InkBridge", "/Volumes/Work/InkBridge"), 3)))
        idle()
        val a = Robolectric.buildActivity(StorageActivity::class.java).setup().get()
        idle()
        val t = a.window.decorView.texts()
        assertTrue("System Design" in t && "~/Documents/InkBridge/Projects/System Design" in t, t.toString())
        assertTrue(t.any { it.startsWith("Offline") }, "never claims the Mac's status while offline")
        assertFalse(app.connection.requestStorage("new_session"), "storage changes need the Mac")
        assertNull(app.connection.storageRequest.value)
    }

    @Test
    fun journalPanelExplainsOfflineAndHeaderShowsTheOpenDay() {
        val a = Robolectric.buildActivity(CanvasActivity::class.java).setup().get()
        idle()
        val root = a.window.decorView
        root.byLabel("Daily Journal").performClick()
        assertTrue(root.texts().any { it.contains("kept on your Mac") }, "offline: says where the journal lives and that drawing is kept")
        assertFalse(app.connection.requestJournal("open"), "journal changes need the Mac")
        app.connection.defaultHostHandler(Payload.Journal(true, "2026-11-01", true, "Sync ideas",
            listOf(JournalItem("j1", "note", "Offline-first storage", false, 1_793_425_500_000)), 4))
        idle()
        assertTrue(root.texts().any { it.startsWith("Daily Journal · Sunday, 1 November 2026 · Today") }, root.texts().toString())
    }

    @Test
    fun sentStrokesLeaveTheTabletWhenTheMacSwitchesDocuments() {
        val doc = app.connection.document
        val style = WireStyle(0, 2.0)
        doc.applyLocal(StylusEvent.Begin("w1", Tool.PEN, InkPoint(1.0, 1.0, 1.0, 0)), style)
        doc.applyLocal(StylusEvent.End("w1"), style)
        doc.applyLocal(StylusEvent.Begin("w2", Tool.PEN, InkPoint(2.0, 2.0, 1.0, 0)), style)
        doc.applyLocal(StylusEvent.End("w2"), style)
        val sent = assertNotNull(app.connection.client.onStrokeSent, "the client must report sent strokes to the mirror")
        sent("w1")  // w1 reached the Mac; w2 was drawn offline and is still waiting
        doc.applyHost(Payload.DocReset)  // the Mac opened another document (journal, session, project)
        assertEquals(listOf("w2"), doc.read { all -> all.map { it.id } }, "only unsent ink survives a switch")
        assertEquals(1, doc.unsentCount)
    }

    @Test
    fun journalAndStorageUpdatesArriveWhileTheCanvasIsOpen() {
        val a = Robolectric.buildActivity(CanvasActivity::class.java).setup().get()
        idle()
        val handler = assertNotNull(app.connection.client.onHostPayload)
        handler(Payload.Journal(true, "2026-11-01", true, "", emptyList(), 1))
        idle()
        assertTrue(a.window.decorView.texts().any { it.startsWith("Daily Journal · Sunday, 1 November 2026 · Today") })
        handler(Payload.Journal(false, "2026-11-01", true, "", emptyList(), 2))  // the Mac closed the journal
        idle()
        assertTrue(a.window.decorView.texts().none { it.startsWith("Daily Journal ·") }, "header goes away when the Mac closes the journal")
        assertEquals(false, app.connection.journal.value?.active)
    }

    @Test
    fun journalSheetShowsPutAwayStateAndKeepsATypedNoteAcrossUpdates() {
        val a = Robolectric.buildActivity(CanvasActivity::class.java).setup().get()
        val asked = mutableListOf<String>()
        val sheet = JournalSheet(a, { action, _ -> asked += action; true }, {})
        val open = Payload.Journal(true, "2026-11-01", true, "", emptyList(), 1, hidden = false)
        sheet.render(open, connected = true)
        val field = sheet.findViews<EditText>().single()
        field.setText("half a thought")
        // New handwriting on the page: the Mac sends an update while the note is being typed.
        sheet.render(open.copy(entries = listOf(JournalItem("j1", "ink", "", false, 1_793_500_000_000)), revision = 2), connected = true)
        assertEquals("half a thought", sheet.findViews<EditText>().single().text.toString(), "a typed note survives updates")
        assertTrue(sheet.texts().contains("Hide on Mac"))
        sheet.render(open.copy(hidden = true, revision = 3), connected = true)
        assertTrue(sheet.texts().any { it.startsWith("Put away on your Mac") }, sheet.texts().toString())
        var button: View = sheet.findViews<TextView>().single { it.text == "Show on Mac" }
        while (!button.hasOnClickListeners()) button = button.parent as View
        button.performClick()
        assertEquals(listOf("show"), asked)
    }

    @Test
    fun dashboardJournalCardOnlyWhileTheJournalIsOpenAndConnected() {
        val a = Robolectric.buildActivity(DashboardActivity::class.java).setup().get()
        app.connection.defaultHostHandler(Payload.Journal(true, "2026-11-01", true, "", emptyList(), 1, hidden = true))
        idle()
        var card: View = a.window.decorView.findViews<TextView>().first { it.text == "Daily Journal is open" }
        while (card.parent is View && card.visibility == View.VISIBLE) card = card.parent as View
        assertEquals(View.GONE, card.visibility, "offline: the Mac's journal can't be continued, so no card")
    }

    private fun View.allViews(): List<View> =
        listOf(this) + ((this as? ViewGroup)?.let { g -> (0 until g.childCount).flatMap { g.getChildAt(it).allViews() } } ?: emptyList())

    private inline fun <reified T : View> View.findViews(): List<T> = allViews().filterIsInstance<T>()

    @Test
    fun diagnosticsNeverShowsSecrets() {
        val a = Robolectric.buildActivity(DiagnosticsActivity::class.java).setup().get()
        idle()
        val text = a.window.decorView.texts().joinToString("\n")
        assertTrue("connection" in text && "protocol" in text)
        assertTrue("token" !in text.lowercase())
    }
}
