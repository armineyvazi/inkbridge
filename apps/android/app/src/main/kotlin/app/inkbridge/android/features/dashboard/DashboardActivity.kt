package app.inkbridge.android.features.dashboard

import android.os.Bundle
import android.text.format.DateUtils
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import app.inkbridge.android.R
import app.inkbridge.android.design.Ink
import app.inkbridge.android.design.InkActivity
import app.inkbridge.android.features.canvas.CanvasActivity
import app.inkbridge.android.features.connect.ConnectActivity
import app.inkbridge.android.features.diagnostics.DiagnosticsActivity
import app.inkbridge.android.features.settings.SettingsActivity
import app.inkbridge.android.input.StylusCapabilityProbe
import app.inkbridge.core.client.ClientState
import app.inkbridge.core.connection.ConnectionMode
import app.inkbridge.core.connection.PrimaryAction
import app.inkbridge.core.connection.StatusView
import app.inkbridge.core.connection.Tone
import kotlinx.coroutines.flow.combine

/**
 * The home screen: where am I connected, and one obvious next step.
 *
 * Layout (portrait, top to bottom): wordmark + settings; the status card
 * with the primary action; the drawing card; links to Connect, Settings
 * and Diagnostics. Values update in place and only when they change, so a
 * connected, idle dashboard does not refresh the panel at all.
 */
class DashboardActivity : InkActivity() {
    private lateinit var markHolder: FrameLayout
    private lateinit var title: TextView
    private lateinit var detail: TextView
    private lateinit var primary: FrameLayout
    private lateinit var secondary: LinearLayout
    private lateinit var macRow: View
    private lateinit var viaRow: View
    private lateinit var lastRow: View
    private lateinit var canvasRow: View
    private lateinit var stylusRow: View
    private lateinit var saveProject: View
    private lateinit var saveWhere: View
    private lateinit var saveStatus: View
    private var lastTone: Tone? = null
    private var lastPrimary: Triple<PrimaryAction, Boolean, Boolean>? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(build())
        observe(manager.status) { render(it) }
        // The Mac's resync arrives after onStart; keep the stroke count current.
        observe(manager.client.state) { updateCanvasCount() }
        observe(combine(manager.storage, manager.client.state) { st, cs -> st to cs }) { (st, cs) ->
            val unsent = manager.document.unsentCount
            Ink.setValue(saveProject, st?.let { "${it.project} › ${it.session}" } ?: "Connect to your Mac")
            Ink.setValue(saveWhere, st?.location ?: "—")
            Ink.setValue(saveStatus, when {
                st == null -> if (unsent > 0) "$unsent strokes kept on this tablet" else "—"
                cs !is ClientState.Ready -> "Offline" + if (unsent > 0) " · $unsent strokes waiting" else ""
                st.status == "empty" -> "New session"
                st.status == "saved" -> "Saved" + if (st.savedAtMs > 0) " " + DateUtils.getRelativeTimeSpanString(st.savedAtMs) else ""
                st.status == "saving" -> "Saving…"
                st.status == "unsaved" -> "Changes not saved yet"
                else -> "Save failed — open Projects & storage"
            })
        }
        observe(combine(manager.paired, manager.client.state) { p, s -> p to s }) { (p, s) ->
            Ink.setValue(macRow, p?.name ?: if (manager.settings.mode == ConnectionMode.USB) "Over USB" else "Not paired")
            Ink.setValue(viaRow, via(s))
            Ink.setValue(lastRow, p?.lastConnectedAt?.takeIf { it > 0 }?.let {
                if (s is ClientState.Ready) "Now" else DateUtils.getRelativeTimeSpanString(it).toString()
            } ?: "Never")
        }
    }

    override fun onStart() {
        super.onStart()
        updateCanvasCount()
        canvasRow.postDelayed(::updateCanvasCount, 1_500)  // after a reconnect resync lands
    }

    private fun updateCanvasCount() {
        val n = manager.document.size
        Ink.setValue(canvasRow, if (n == 0) "Empty" else "$n stroke${if (n == 1) "" else "s"}")
    }

    private fun build(): View {
        val c = Ink.column(this)

        // Wordmark row
        c.add(Ink.row(this).apply {
            addView(Ink.icon(this@DashboardActivity, R.drawable.ic_pen, Ink.INK, 30), LinearLayout.LayoutParams(Ink.dp(context, 30), Ink.dp(context, 30)))
            addView(Ink.title(this@DashboardActivity, "InkBridge").apply { setPadding(Ink.dp(context, 12), 0, 0, 0) },
                LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
            addView(Ink.iconButton(this@DashboardActivity, R.drawable.ic_settings, "Settings") { open<SettingsActivity>() })
        })

        // Status card
        val card = Ink.card(this)
        markHolder = FrameLayout(this)
        title = Ink.display(this, "")
        detail = Ink.body(this, "").apply { setTextColor(Ink.GREY) }
        card.add(Ink.row(this).apply {
            addView(markHolder, LinearLayout.LayoutParams(Ink.dp(context, 22), Ink.dp(context, 22)).apply { marginEnd = Ink.dp(context, 14) })
            addView(title, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        })
        card.add(detail)
        macRow = Ink.infoRow(this, "Mac", "")
        viaRow = Ink.infoRow(this, "Connection", "")
        lastRow = Ink.infoRow(this, "Last connected", "")
        card.add(Ink.rule(this), gapBefore = Ink.dp(this, Ink.M))
        card.add(macRow, Ink.dp(this, Ink.S)).add(viaRow, 0).add(lastRow, 0)
        primary = FrameLayout(this)
        card.add(primary, Ink.dp(this, Ink.L))
        secondary = Ink.row(this)
        card.add(secondary, Ink.dp(this, Ink.S))
        c.add(card, Ink.dp(this, Ink.L))

        // Drawing card
        val drawing = Ink.card(this)
        drawing.add(Ink.heading(this, "Drawing"))
        canvasRow = Ink.infoRow(this, "Canvas", "")
        val caps = StylusCapabilityProbe.capabilities()
        stylusRow = Ink.infoRow(this, "Stylus", if (caps.pressure) "Pressure ready" else "No pressure reported")
        drawing.add(canvasRow).add(stylusRow, 0)
        drawing.add(Ink.infoRow(this, "Ink on tablet", if (manager.settings.showLocalInk) "Visible" else "Hidden"), 0)
        c.add(drawing, Ink.dp(this, Ink.M))

        // Saving (the Mac owns the files)
        val saving = Ink.card(this)
        saving.add(Ink.heading(this, "Saving"))
        saveProject = Ink.infoRow(this, "Project", "")
        saveWhere = Ink.infoRow(this, "On your Mac", "")
        saveStatus = Ink.infoRow(this, "Status", "")
        saving.add(saveProject).add(saveWhere, 0).add(saveStatus, 0)
        saving.add(Ink.button(this, "Projects & storage", Ink.ButtonStyle.GHOST) {
            open<app.inkbridge.android.features.storage.StorageActivity>()
        }, Ink.dp(this, Ink.XS))
        c.add(saving, Ink.dp(this, Ink.M))

        // Navigation
        c.add(Ink.section(this, "More"), Ink.dp(this, Ink.S))
        c.add(Ink.listRow(this, R.drawable.ic_wifi, "Connection & pairing", "Find your Mac, pair, or switch to USB") { open<ConnectActivity>() }, 0)
        c.add(Ink.listRow(this, R.drawable.ic_settings, "Settings", "Drawing, display and connection preferences") { open<SettingsActivity>() }, 0)
        c.add(Ink.listRow(this, R.drawable.ic_info, "Diagnostics", "Connection details, latency and stylus readout") { open<DiagnosticsActivity>() }, 0)
        return Ink.page(this, c)
    }

    private fun render(s: StatusView) {
        Ink.setText(title, s.title)
        Ink.setText(detail, s.detail)
        if (s.tone != lastTone) {
            lastTone = s.tone
            markHolder.removeAllViews()
            markHolder.addView(Ink.statusMark(this, s.tone, 22), FrameLayout.LayoutParams(-1, -1, Gravity.CENTER))
        }
        val paired = manager.paired.value != null || manager.settings.mode == ConnectionMode.USB
        val key = Triple(s.primary, paired, manager.paused.value)
        if (lastPrimary != key) {
            lastPrimary = key
            primary.removeAllViews()
            primary.addView(primaryButton(s.primary, paired))
            secondary.removeAllViews()
            secondaryButtons(s.primary, paired).forEachIndexed { i, b ->
                secondary.addView(b, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f).apply {
                    if (i > 0) marginStart = Ink.dp(this@DashboardActivity, Ink.S)
                })
            }
        }
    }

    private fun primaryButton(a: PrimaryAction, paired: Boolean): View = when (a) {
        PrimaryAction.OPEN_CANVAS -> Ink.button(this, "Open canvas", Ink.ButtonStyle.PRIMARY, R.drawable.ic_pen) { open<CanvasActivity>() }
        PrimaryAction.CONNECT_TO_MAC ->
            if (paired && manager.paused.value) Ink.button(this, "Connect", Ink.ButtonStyle.PRIMARY, R.drawable.ic_wifi) { manager.resume() }
            else Ink.button(this, "Connect to Mac", Ink.ButtonStyle.PRIMARY, R.drawable.ic_laptop) { open<ConnectActivity>() }
        PrimaryAction.RETRY -> Ink.button(this, "Try again", Ink.ButtonStyle.PRIMARY, R.drawable.ic_refresh) { manager.restart() }
        PrimaryAction.PAIR_AGAIN -> Ink.button(this, "Pair again", Ink.ButtonStyle.PRIMARY, R.drawable.ic_laptop) { open<ConnectActivity>() }
    }

    /** The canvas is always reachable (it works offline); Disconnect only when something is connected or trying. */
    private fun secondaryButtons(a: PrimaryAction, paired: Boolean): List<View> = buildList {
        if (a != PrimaryAction.OPEN_CANVAS) add(Ink.button(this@DashboardActivity, "Draw offline", Ink.ButtonStyle.SECONDARY) { open<CanvasActivity>() })
        if (paired && !manager.paused.value && a == PrimaryAction.OPEN_CANVAS) {
            add(Ink.button(this@DashboardActivity, "Disconnect", Ink.ButtonStyle.SECONDARY) { manager.disconnect() })
        }
    }

    private fun via(s: ClientState): String {
        val mode = manager.settings.mode
        val label = if (mode == ConnectionMode.USB) "USB cable" else "Wi-Fi"
        return when (s) {
            is ClientState.Ready -> "$label · ${manager.lastAddress ?: ""}".trimEnd(' ', '·')
            else -> label
        }
    }
}
