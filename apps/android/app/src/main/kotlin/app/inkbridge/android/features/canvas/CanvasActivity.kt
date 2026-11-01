package app.inkbridge.android.features.canvas

import android.os.Build
import android.os.Bundle
import android.view.Gravity
import android.view.View
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.PopupMenu
import android.widget.TextView
import android.widget.Toast
import app.inkbridge.android.R
import app.inkbridge.android.design.Ink
import app.inkbridge.android.design.InkActivity
import app.inkbridge.android.features.diagnostics.DiagnosticsActivity
import app.inkbridge.android.features.settings.SettingsActivity
import app.inkbridge.android.features.settings.StartView
import app.inkbridge.android.input.AndroidMotionEventSource
import app.inkbridge.core.canvas.Viewport
import app.inkbridge.core.client.ClientState
import app.inkbridge.core.connection.StatusView
import app.inkbridge.core.connection.Tone
import app.inkbridge.core.input.StrokeProcessor
import app.inkbridge.core.protocol.CanvasCommand
import app.inkbridge.core.protocol.Payload
import app.inkbridge.core.protocol.WireStyle

/**
 * The drawing surface: the whole screen is canvas.
 *
 * Controls float in one slim bar along the top edge (back, undo/redo,
 * zoom, fit, ink visibility, more), and can be collapsed to a single
 * button. The connection is a small chip in the bar that changes only when
 * the *stage* changes (never per latency sample), so it does not refresh
 * the panel while you write.
 *
 * Event order for a pen sample (latency first): MotionEvent →
 * StrokeProcessor → client.submit (network) → CanvasDocument (mirror) →
 * renderer request (drawn on its own thread). Works offline too: strokes
 * queue and are sent when the link returns.
 */
class CanvasActivity : InkActivity() {
    private lateinit var canvas: CanvasView
    private lateinit var bar: LinearLayout
    private lateinit var collapsed: View
    private lateinit var chipMark: FrameLayout
    private lateinit var chipText: TextView
    private lateinit var zoomLabel: TextView
    private lateinit var chipView: View
    private var lastTone: Tone? = null
    private val renderer by lazy { CanvasRenderer(manager.document) }
    private val processor = StrokeProcessor(streamTag = java.util.UUID.randomUUID().toString().take(8))
    private val source = AndroidMotionEventSource(processor)
    private var lastViewportSentAt = 0L

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        val s = manager.settings
        processor.pressure = s.pressure
        canvas = CanvasView(this).apply {
            source = this@CanvasActivity.source
            renderer = this@CanvasActivity.renderer
            fingerNavigation = s.fingerNavigation
            onSurfaceChanged = { w, h -> manager.client.updateSurface(w, h); initialView(w, h) }
            onViewport = { v, final -> applyViewport(v, final, fromHost = false) }
        }
        renderer.inkVisible = s.showLocalInk
        source.onEvents = { events ->
            val c = manager.client
            for (e in events) {
                c.submit(e)  // network first: the Mac is where the user looks
                manager.document.applyLocal(e, LOCAL_STYLE)
            }
        }
        // The canvas adds viewport handling; everything else (document, storage, journal…)
        // goes through the shared handler. Regression: handling only document messages here
        // dropped journal/storage updates while the canvas was open.
        manager.client.onHostPayload = { p ->
            if (p is Payload.CanvasViewport) runOnUiThread { applyViewport(p.viewport, final = true, fromHost = true) }
            else manager.defaultHostHandler(p)
        }
        setContentView(FrameLayout(this).apply {
            setBackgroundColor(Ink.PAPER)
            addView(canvas, FrameLayout.LayoutParams(-1, -1))
            journalHeader = Ink.text(this@CanvasActivity, "", Ink.CAPTION + 1, bold = true).apply {
                background = Ink.box(context, Ink.PAPER, Ink.INK, radius = 16, strokeDp = 1)
                setPadding(Ink.dp(context, 14), Ink.dp(context, 8), Ink.dp(context, 14), Ink.dp(context, 8))
                visibility = View.GONE
            }
            addView(journalHeader, FrameLayout.LayoutParams(-2, -2, Gravity.TOP or Gravity.START).apply {
                topMargin = Ink.dp(context, 14); marginStart = Ink.dp(context, 12)
            })
            chipView = chip()
            // Bottom left: status stays readable without sharing the top edge with the tools.
            addView(chipView, FrameLayout.LayoutParams(-2, -2, Gravity.BOTTOM or Gravity.START).apply {
                bottomMargin = Ink.dp(context, 12); marginStart = Ink.dp(context, 12)
            })
            bar = buildBar()
            addView(bar, FrameLayout.LayoutParams(-2, -2, Gravity.TOP or Gravity.END).apply {
                topMargin = Ink.dp(context, 12); marginEnd = Ink.dp(context, 12)
            })
            collapsed = Ink.iconButton(this@CanvasActivity, R.drawable.ic_more, "Show controls") { setControls(true) }.apply {
                background = Ink.box(context, Ink.PAPER, Ink.INK, radius = 28)
                visibility = View.GONE
            }
            addView(collapsed, FrameLayout.LayoutParams(-2, -2, Gravity.TOP or Gravity.END).apply {
                topMargin = Ink.dp(context, 12); marginEnd = Ink.dp(context, 12)
            })
        })
        hideSystemBars()
        observe(manager.status) { renderStatus(it) }
        observe(kotlinx.coroutines.flow.combine(manager.journal, manager.client.state) { j, s -> j to (s is ClientState.Ready) }) { (j, c) ->
            renderJournal(j, c)
        }
    }

    override fun onDestroy() {
        manager.client.onHostPayload = manager.defaultHostHandler
        manager.saveViewport(canvas.viewport)
        renderer.quit()
        super.onDestroy()
    }

    override fun onStop() {
        manager.saveViewport(canvas.viewport)
        super.onStop()
    }

    private var initialized = false

    private fun initialView(w: Int, h: Int) {
        if (initialized) return
        initialized = true
        val s = manager.settings
        val v = when (s.startView) {
            StartView.HOME -> Viewport.HOME
            StartView.FIT -> Viewport.fitting(manager.document.contentBounds(), w, h)
            StartView.LAST -> manager.client.viewport.takeIf { it != Viewport.HOME } ?: s.lastViewport
        }
        applyViewport(v, final = true, fromHost = false)
    }

    // MARK: Controls

    /** Tools, top right: undo/redo, zoom, more. 48dp buttons keep it to ~350dp so it never meets the chip. */
    private fun buildBar(): LinearLayout = Ink.row(this).apply {
        background = Ink.box(context, Ink.PAPER, Ink.INK, radius = 16)
        setPadding(Ink.dp(context, 4), Ink.dp(context, 2), Ink.dp(context, 4), Ink.dp(context, 2))
        val ctx = this@CanvasActivity
        addView(Ink.iconButton(ctx, R.drawable.ic_undo, "Undo", BAR) { command(CanvasCommand.UNDO) })
        addView(Ink.iconButton(ctx, R.drawable.ic_redo, "Redo", BAR) { command(CanvasCommand.REDO) })
        addView(divider())
        addView(Ink.iconButton(ctx, R.drawable.ic_zoom_out, "Zoom out", BAR) { zoomBy(1 / 1.5) })
        zoomLabel = Ink.text(ctx, "100%", Ink.CAPTION, bold = true).apply {
            gravity = Gravity.CENTER
            minWidth = Ink.dp(context, 52)
            minHeight = Ink.dp(context, BAR)
            isClickable = true
            contentDescription = "Zoom level; tap for actual size"
            setOnClickListener { applyViewport(Viewport.HOME, final = true, fromHost = false) }
        }
        addView(zoomLabel)
        addView(Ink.iconButton(ctx, R.drawable.ic_zoom_in, "Zoom in", BAR) { zoomBy(1.5) })
        addView(Ink.iconButton(ctx, R.drawable.ic_fit, "Fit all ink", BAR) { fitAll() })
        addView(divider())
        addView(Ink.iconButton(ctx, R.drawable.ic_book, "Daily Journal", BAR) { toggleJournalSheet() })
        addView(Ink.iconButton(ctx, R.drawable.ic_background, "Background", BAR) { toggleBackgroundSheet() })
        lateinit var more: View
        more = Ink.iconButton(ctx, R.drawable.ic_more, "More", BAR) { showMore(more) }
        addView(more)
    }

    private fun divider() = View(this).apply { setBackgroundColor(Ink.RULE) }.also {
        it.layoutParams = LinearLayout.LayoutParams(Ink.dp(this, 1), Ink.dp(this, 32)).apply {
            marginStart = Ink.dp(this@CanvasActivity, 4); marginEnd = Ink.dp(this@CanvasActivity, 4)
        }
    }

    /** Top left: back + connection stage. Tapping it returns to the dashboard. */
    private fun chip(): View {
        chipMark = FrameLayout(this)
        chipText = Ink.text(this, "", Ink.CAPTION, bold = true).apply { maxWidth = Ink.dp(context, 200); maxLines = 1; ellipsize = android.text.TextUtils.TruncateAt.END }
        return Ink.chip(this).apply {
            minimumHeight = Ink.dp(context, BAR)
            addView(Ink.icon(this@CanvasActivity, R.drawable.ic_back, Ink.INK, 20), LinearLayout.LayoutParams(Ink.dp(context, 20), Ink.dp(context, 20)).apply { marginEnd = Ink.dp(context, 6) })
            addView(chipMark, LinearLayout.LayoutParams(Ink.dp(context, 12), Ink.dp(context, 12)).apply { marginEnd = Ink.dp(context, 8) })
            addView(chipText)
            isClickable = true
            contentDescription = "Connection status"
            setOnClickListener { finish() }
        }
    }

    private fun renderStatus(s: StatusView) {
        Ink.setText(chipText, s.chip)
        if (s.tone != lastTone) {
            lastTone = s.tone
            chipMark.removeAllViews()
            chipMark.addView(Ink.statusMark(this, s.tone, 12), FrameLayout.LayoutParams(-1, -1))
        }
    }

    // MARK: Daily Journal

    private var journalSheet: JournalSheet? = null
    private lateinit var journalHeader: TextView

    private fun toggleJournalSheet() {
        val root = canvas.parent as FrameLayout
        journalSheet?.let { root.removeView(it); journalSheet = null; return }
        sheet?.let { root.removeView(it); sheet = null }
        val panel = JournalSheet(this, request = { a, n -> manager.requestJournal(a, n) }, onClose = ::toggleJournalSheet)
        panel.render(manager.journal.value, manager.client.state.value is ClientState.Ready)
        root.addView(panel, FrameLayout.LayoutParams(Ink.dp(this, 400), -2, Gravity.TOP or Gravity.END).apply {
            topMargin = Ink.dp(this@CanvasActivity, 12 + BAR + 12); marginEnd = Ink.dp(this@CanvasActivity, 12)
        })
        journalSheet = panel
    }

    /** Header across the top while the journal is open: which day the ink goes to. */
    private fun renderJournal(j: app.inkbridge.core.protocol.Payload.Journal?, connected: Boolean) {
        val text = if (j?.active == true) {
            val (weekday, date) = JournalSheet.formatDay(j.day)
            "Daily Journal · $weekday, $date" + (if (j.today) " · Today" else "") + (if (j.hidden) " · put away on Mac" else "")
        } else ""
        Ink.setText(journalHeader, text)
        journalHeader.visibility = if (text.isEmpty()) View.GONE else View.VISIBLE
        journalSheet?.render(j, connected)
    }

    // MARK: Background

    private var sheet: View? = null

    private fun toggleBackgroundSheet() {
        val root = canvas.parent as FrameLayout
        sheet?.let { root.removeView(it); sheet = null; return }
        journalSheet?.let { root.removeView(it); journalSheet = null }
        val panel = BackgroundSheet(this, manager.document.background, onPick = ::setBackground, onClose = ::toggleBackgroundSheet)
        root.addView(panel, FrameLayout.LayoutParams(Ink.dp(this, 380), -2, Gravity.TOP or Gravity.END).apply {
            topMargin = Ink.dp(this@CanvasActivity, 12 + BAR + 12); marginEnd = Ink.dp(this@CanvasActivity, 12)
        })
        sheet = panel
    }

    /**
     * Shown immediately, then sent to the Mac, which applies it as one undo
     * step and answers with a new revision. Offline, the request waits in the
     * outbox and is applied when the link returns.
     */
    private fun setBackground(bg: app.inkbridge.core.canvas.CanvasBackground) {
        val doc = manager.document
        val wasDark = doc.background.isDark
        doc.setBackgroundLocal(bg)
        manager.client.submitBackground(bg, doc.backgroundRevision)
        // Black ⇄ white flips every pixel: one clean refresh avoids a ghost of the old paper.
        if (wasDark != bg.isDark) cleanRefresh()
    }

    private fun setControls(visible: Boolean) {
        bar.visibility = if (visible) View.VISIBLE else View.GONE
        chipView.visibility = bar.visibility
        if (!visible) sheet?.let { (canvas.parent as FrameLayout).removeView(it); sheet = null }
        collapsed.visibility = if (visible) View.GONE else View.VISIBLE
    }

    private fun showMore(anchor: View) {
        PopupMenu(this, anchor).apply {
            menu.add(if (manager.settings.showLocalInk) "Hide ink on tablet" else "Show ink on tablet").setOnMenuItemClickListener { toggleInk(); true }
            menu.add("Clear canvas").setOnMenuItemClickListener { clearCanvas(); true }
            menu.add("Refresh screen").setOnMenuItemClickListener { cleanRefresh(); renderer.requestFull(); true }
            menu.add("Hide controls").setOnMenuItemClickListener { setControls(false); true }
            menu.add("Settings").setOnMenuItemClickListener { open<SettingsActivity>(); true }
            menu.add("Diagnostics").setOnMenuItemClickListener { open<DiagnosticsActivity>(); true }
            show()
        }
    }

    private fun toggleInk() {
        val s = manager.settings.copy(showLocalInk = !manager.settings.showLocalInk)
        manager.update(s)
        renderer.inkVisible = s.showLocalInk
    }

    private fun command(c: CanvasCommand) {
        if (manager.client.state.value is ClientState.Ready) manager.client.submitCommand(c)
        else Toast.makeText(this, "Connect to the Mac to ${c.wire}", Toast.LENGTH_SHORT).show()
    }

    /** Connected: the Mac clears (undoable there). Offline: only this screen; the Mac's copy returns on reconnect. */
    private fun clearCanvas() {
        if (manager.client.state.value is ClientState.Ready) {
            manager.client.submitCommand(CanvasCommand.CLEAR)
            Toast.makeText(this, "Cleared. Undo brings it back.", Toast.LENGTH_SHORT).show()
        } else {
            manager.document.clearLocal()
            Toast.makeText(this, "Cleared on this tablet only. The Mac keeps its copy.", Toast.LENGTH_LONG).show()
        }
        if (manager.settings.cleanRefresh) cleanRefresh()
    }

    private fun fitAll() {
        applyViewport(Viewport.fitting(manager.document.contentBoundsWithDiagram(), canvas.width, canvas.height), final = true, fromHost = false)
        if (manager.settings.cleanRefresh) cleanRefresh()
    }

    private fun zoomBy(f: Double) {
        applyViewport(canvas.viewport.zoomedBy(f, canvas.width / 2f, canvas.height / 2f), final = true, fromHost = false)
    }

    /**
     * Single place the view changes. Gesture moves only preview (and are sent at
     * most every 100 ms); the final viewport is committed, drawn and sent.
     */
    private fun applyViewport(v: Viewport, final: Boolean, fromHost: Boolean) {
        if (!final) {
            val now = System.nanoTime()
            if (now - lastViewportSentAt > 100_000_000) {
                lastViewportSentAt = now
                manager.client.submitViewport(v)
            }
            return
        }
        canvas.viewport = v
        processor.viewport = v
        renderer.setViewport(v)
        if (!fromHost) manager.client.submitViewport(v)
        Ink.setText(zoomLabel, "${(v.zoom * 100).toInt()}%")
    }

    private fun hideSystemBars() {
        if (Build.VERSION.SDK_INT >= 30) {
            window.insetsController?.let {
                it.hide(WindowInsets.Type.systemBars())
                it.systemBarsBehavior = WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            }
        }
    }

    companion object {
        /** Until the Mac styles a stroke (a few ms later), draw it black at 2.5 canvas px. */
        private val LOCAL_STYLE = WireStyle(0xFF000000.toInt(), 2.5)
        private const val BAR = 48
    }
}
