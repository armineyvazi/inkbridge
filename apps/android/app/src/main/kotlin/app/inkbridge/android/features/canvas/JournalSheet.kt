package app.inkbridge.android.features.canvas

import android.content.Context
import android.text.InputType
import android.view.View
import android.view.inputmethod.EditorInfo
import android.widget.EditText
import android.widget.LinearLayout
import app.inkbridge.android.R
import app.inkbridge.android.design.Ink
import app.inkbridge.core.protocol.Payload
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * The tablet's Daily Journal panel. The Mac owns the journal (files, days,
 * timestamps); this panel shows the open day and asks the Mac to open,
 * close, move between days or add a note/task. Handwriting goes straight
 * onto the canvas like anywhere else and is timestamped by the Mac.
 */
class JournalSheet(
    ctx: Context,
    private val request: (action: String, name: String?) -> Boolean,
    private val onClose: () -> Unit,
) : LinearLayout(ctx) {
    private val time = SimpleDateFormat("HH:mm", Locale.getDefault())

    init {
        orientation = VERTICAL
        background = Ink.box(ctx, Ink.PAPER, Ink.INK, radius = 14)
        setPadding(Ink.dp(ctx, Ink.M + 4), Ink.dp(ctx, Ink.S), Ink.dp(ctx, Ink.S), Ink.dp(ctx, Ink.M))
        isClickable = true
    }

    fun render(state: Payload.Journal?, connected: Boolean) {
        removeAllViews()
        val ctx = context
        addView(Ink.row(ctx).apply {
            addView(Ink.heading(ctx, "Daily Journal"), LayoutParams(0, LayoutParams.WRAP_CONTENT, 1f))
            addView(Ink.iconButton(ctx, R.drawable.ic_close, "Close", 48) { onClose() })
        })
        if (!connected) {
            addView(Ink.body(ctx, "The journal is kept on your Mac. Connect to open it; anything you draw now is kept and sent when you reconnect.")
                .apply { setTextColor(Ink.GREY) }, lp(Ink.S))
            return
        }
        if (state == null || !state.active) {
            addView(Ink.body(ctx, "Capture a thought on today's page, then come back to exactly what you were doing.")
                .apply { setTextColor(Ink.GREY) }, lp(Ink.S))
            addView(Ink.button(ctx, "Open today's journal", Ink.ButtonStyle.PRIMARY, R.drawable.ic_book) { request("open", null) }, lp(Ink.M))
            return
        }
        addView(Ink.row(ctx).apply {
            addView(Ink.iconButton(ctx, R.drawable.ic_back, "Previous day", 48) { request("prev", null) })
            addView(Ink.text(ctx, state.day + if (state.today) "  ·  Today" else "", Ink.BODY, bold = true).apply {
                gravity = android.view.Gravity.CENTER
            }, LayoutParams(0, LayoutParams.WRAP_CONTENT, 1f))
            addView(Ink.iconButton(ctx, R.drawable.ic_chevron, "Next day", 48) { request("next", null) })
        }, lp(Ink.XS))
        if (!state.today) addView(Ink.button(ctx, "Go to today", Ink.ButtonStyle.GHOST) { request("today", null) })
        if (state.title.isNotEmpty()) addView(Ink.body(ctx, state.title), lp(Ink.XS))

        val field = EditText(ctx).apply {
            hint = "Quick note…"
            textSize = Ink.BODY
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES
            imeOptions = EditorInfo.IME_ACTION_DONE
            background = Ink.box(ctx, Ink.PAPER, Ink.INK)
            setPadding(Ink.dp(ctx, 12), Ink.dp(ctx, 10), Ink.dp(ctx, 12), Ink.dp(ctx, 10))
        }
        fun add(action: String) {
            val t = field.text.toString().trim()
            if (t.isNotEmpty() && request(action, t)) field.setText("")
        }
        field.setOnEditorActionListener { _, _, _ -> add("add_note"); true }
        addView(field, lp(Ink.S))
        addView(Ink.row(ctx).apply {
            addView(Ink.button(ctx, "Add note", Ink.ButtonStyle.SECONDARY) { add("add_note") }, LayoutParams(0, LayoutParams.WRAP_CONTENT, 1f))
            addView(View(ctx), LayoutParams(Ink.dp(ctx, Ink.S), 1))
            addView(Ink.button(ctx, "Add task", Ink.ButtonStyle.SECONDARY) { add("add_task") }, LayoutParams(0, LayoutParams.WRAP_CONTENT, 1f))
        }, lp(Ink.XS))

        addView(Ink.caption(ctx, "ENTRIES"), lp(Ink.M))
        if (state.entries.isEmpty()) addView(Ink.caption(ctx, "Nothing yet — write anywhere on the page."))
        for (e in state.entries.takeLast(12).reversed()) {
            val label = when (e.kind) {
                "ink" -> "Handwriting"
                "task" -> (if (e.done) "☑ " else "☐ ") + e.text
                else -> e.text
            }
            addView(Ink.infoRow(ctx, time.format(Date(e.createdMs)), label), lp(0))
        }
        addView(Ink.button(ctx, "Close journal — back to my work", Ink.ButtonStyle.PRIMARY) { request("close", null) }, lp(Ink.M))
    }

    private fun lp(top: Int) = LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT).apply { topMargin = Ink.dp(context, top) }
}
