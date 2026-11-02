package app.inkbridge.android.features.canvas

import android.content.Context
import android.graphics.Typeface
import android.text.InputType
import android.view.Gravity
import android.view.View
import android.view.inputmethod.EditorInfo
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import app.inkbridge.android.R
import app.inkbridge.android.design.Ink
import app.inkbridge.core.protocol.JournalItem
import app.inkbridge.core.protocol.Payload
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * The tablet's Daily Journal panel. The Mac owns the journal (files, days,
 * timestamps); this panel shows the open day and asks the Mac to open, put
 * away, close, move between days or add a note/task. Handwriting goes straight
 * onto the canvas like anywhere else and is timestamped by the Mac.
 *
 * Laid out for e-ink: one date header, a time-ordered list (time column, then
 * the entry), one composer row, and the two journal actions at the bottom.
 * No animation and no greys below the panel's readable contrast.
 */
class JournalSheet(
    ctx: Context,
    private val request: (action: String, name: String?) -> Boolean,
    private val onClose: () -> Unit,
) : LinearLayout(ctx) {
    private var asTask = false

    /**
     * One field for the panel's lifetime. The panel is rebuilt on every journal update
     * (new handwriting adds an entry); a new field each time lost a half-typed note.
     */
    private val field: EditText = EditText(ctx).apply {
        textSize = Ink.BODY
        inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES
        imeOptions = EditorInfo.IME_ACTION_DONE
        background = Ink.box(ctx, Ink.PAPER, Ink.INK)
        setPadding(Ink.dp(ctx, 12), Ink.dp(ctx, 10), Ink.dp(ctx, 12), Ink.dp(ctx, 10))
        setOnEditorActionListener { _, _, _ -> addTyped(); true }
    }

    private fun addTyped() {
        val t = field.text.toString().trim()
        if (t.isNotEmpty() && request(if (asTask) "add_task" else "add_note", t)) field.setText("")
    }

    init {
        orientation = VERTICAL
        background = Ink.box(ctx, Ink.PAPER, Ink.INK, radius = 14)
        setPadding(Ink.dp(ctx, Ink.M + 4), Ink.dp(ctx, Ink.S), Ink.dp(ctx, Ink.S), Ink.dp(ctx, Ink.M))
        isClickable = true
    }

    fun render(state: Payload.Journal?, connected: Boolean) {
        removeAllViews()
        val ctx = context
        if (!connected || state == null || !state.active) {
            addView(Ink.row(ctx).apply {
                addView(Ink.heading(ctx, "Daily Journal"), LayoutParams(0, LayoutParams.WRAP_CONTENT, 1f))
                addView(Ink.iconButton(ctx, R.drawable.ic_close, "Close", 48) { onClose() })
            })
            if (!connected) {
                addView(Ink.body(ctx, "The journal is kept on your Mac. Connect to open it. Anything you write now is kept here and sent when you reconnect.")
                    .apply { setTextColor(Ink.GREY) }, lp(Ink.S))
            } else {
                addView(Ink.body(ctx, "Capture a thought on today's page, then come back to exactly what you were doing.")
                    .apply { setTextColor(Ink.GREY) }, lp(Ink.S))
                addView(Ink.button(ctx, "Open today's journal", Ink.ButtonStyle.PRIMARY, R.drawable.ic_book) { request("open", null) }, lp(Ink.M))
            }
            return
        }
        header(state)
        composer()
        entries(state.entries)
        // Hide/Done both leave the journal on the Mac and restore the previous workspace.
        // A former "put away" mode kept routing ink into the day while the Mac canvas was
        // ordered out — writing looked broken. One clear exit path avoids that.
        addView(
            Ink.button(ctx, "Done — back to work", Ink.ButtonStyle.PRIMARY) { request("close", null) },
            lp(Ink.M),
        )
    }

    /** ‹  SUNDAY · TODAY / 1 November 2026  ›   ×  */
    private fun header(state: Payload.Journal) {
        val ctx = context
        val (weekday, date) = formatDay(state.day)
        addView(Ink.row(ctx).apply {
            addView(Ink.iconButton(ctx, R.drawable.ic_back, "Previous day", 48) { request("prev", null) })
            addView(LinearLayout(ctx).apply {
                orientation = VERTICAL
                setPadding(Ink.dp(ctx, 6), 0, Ink.dp(ctx, 6), 0)
                addView(Ink.text(ctx, (weekday + if (state.today) " · Today" else "").uppercase(Locale.getDefault()), Ink.CAPTION, bold = true))
                addView(Ink.text(ctx, date, Ink.HEADING, bold = true))
            }, LayoutParams(0, LayoutParams.WRAP_CONTENT, 1f))
            addView(Ink.iconButton(ctx, R.drawable.ic_chevron, "Next day", 48) { request("next", null) })
            addView(Ink.iconButton(ctx, R.drawable.ic_close, "Close panel", 48) { onClose() })
        })
        if (!state.today) addView(Ink.button(ctx, "Go to today", Ink.ButtonStyle.GHOST) { request("today", null) })
        if (state.title.isNotEmpty()) addView(Ink.body(ctx, state.title), lp(Ink.XS))
    }

    private fun composer() {
        val ctx = context
        field.hint = if (asTask) "Add a task" else "Write a note"
        (field.parent as? android.view.ViewGroup)?.removeView(field)
        addView(Ink.row(ctx).apply {
            addView(Ink.segmented(ctx, listOf("Note", "Task"), if (asTask) 1 else 0) {
                asTask = it == 1
                field.hint = if (asTask) "Add a task" else "Write a note"
            })
            addView(View(ctx), LayoutParams(Ink.dp(ctx, Ink.S), 1))
            addView(field, LayoutParams(0, LayoutParams.WRAP_CONTENT, 1f))
            addView(Ink.iconButton(ctx, R.drawable.ic_check, "Add", 48) { addTyped() })
        }, lp(Ink.S))
    }

    /** Oldest first, like a diary; the newest are next to the composer above when scrolled to the end. */
    private fun entries(items: List<JournalItem>) {
        val ctx = context
        if (items.isEmpty()) {
            addView(Ink.caption(ctx, "Nothing yet. Write anywhere on the page, or type a note above. Every entry keeps its time."), lp(Ink.M))
            return
        }
        val list = LinearLayout(ctx).apply { orientation = VERTICAL }
        for (e in items.takeLast(30)) list.addView(entryRow(e), lp(Ink.XS))
        addView(ScrollView(ctx).apply {
            isVerticalScrollBarEnabled = true
            addView(list)
            post { fullScroll(View.FOCUS_DOWN) }
        }, LayoutParams(LayoutParams.MATCH_PARENT, if (items.size > 8) Ink.dp(ctx, 260) else LayoutParams.WRAP_CONTENT)
            .apply { topMargin = Ink.dp(ctx, Ink.M) })
    }

    private fun entryRow(e: JournalItem): View {
        val ctx = context
        return Ink.row(ctx).apply {
            gravity = Gravity.TOP
            addView(Ink.text(ctx, TIME.get()!!.format(Date(e.createdMs)), Ink.CAPTION, bold = true).apply {
                typeface = Typeface.create(Typeface.MONOSPACE, Typeface.BOLD)
            }, LayoutParams(Ink.dp(ctx, 56), LayoutParams.WRAP_CONTENT))
            val label = when (e.kind) {
                "ink" -> "✎  Handwriting"
                "task" -> (if (e.done) "☑  " else "☐  ") + e.text
                else -> e.text
            }
            addView(Ink.text(ctx, label, Ink.BODY, color = if (e.kind == "ink" || e.done) Ink.GREY else Ink.INK),
                LayoutParams(0, LayoutParams.WRAP_CONTENT, 1f))
        }
    }

    private fun lp(top: Int) = LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT).apply { topMargin = Ink.dp(context, top) }

    companion object {
        private val TIME = ThreadLocal.withInitial { SimpleDateFormat("HH:mm", Locale.getDefault()) }

        /** "2026-11-01" → ("Sunday", "1 November 2026") in the tablet's language. */
        fun formatDay(day: String): Pair<String, String> {
            val d = runCatching { SimpleDateFormat("yyyy-MM-dd", Locale.US).parse(day) }.getOrNull() ?: return "" to day
            return SimpleDateFormat("EEEE", Locale.getDefault()).format(d) to
                SimpleDateFormat("d MMMM yyyy", Locale.getDefault()).format(d)
        }
    }
}
