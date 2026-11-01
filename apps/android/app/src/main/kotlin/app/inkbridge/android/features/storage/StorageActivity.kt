package app.inkbridge.android.features.storage

import android.os.Bundle
import android.text.format.DateUtils
import android.view.View
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.TextView
import app.inkbridge.android.R
import app.inkbridge.android.design.Ink
import app.inkbridge.android.design.InkActivity
import app.inkbridge.android.design.SpacedColumn
import app.inkbridge.core.client.ClientState
import app.inkbridge.core.protocol.StorageState
import kotlinx.coroutines.flow.combine

/**
 * Projects & storage on the tablet.
 *
 * The Mac owns the files, so this screen shows where the Mac saves (a Mac
 * path, labelled as such) and asks the Mac for changes; the Mac validates
 * them and answers. Local tablet data (offline strokes not yet sent) is
 * shown separately. Nothing here pretends the tablet can open Mac folders.
 */
class StorageActivity : InkActivity() {
    private lateinit var body: SpacedColumn

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        body = Ink.column(this)
        setContentView(LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Ink.PAPER)
            addView(Ink.topBar(this@StorageActivity, "Projects & storage", onBack = ::finish))
            addView(Ink.page(this@StorageActivity, body), LinearLayout.LayoutParams(-1, 0, 1f))
        })
        observe(combine(manager.storage, manager.client.state, manager.storageRequest) { a, b, c -> Triple(a, b, c) }) { (st, cs, req) ->
            render(st, cs is ClientState.Ready, req)
        }
    }

    private var lastKey: Any? = null

    private fun render(st: StorageState?, connected: Boolean, pending: String?) {
        val unsent = manager.document.unsentCount
        val key = listOf(st, connected, pending, unsent)
        if (key == lastKey) return  // e-ink: redraw only on real change
        lastKey = key
        body.removeAllViews()
        if (st == null) {
            body.add(Ink.title(this, "Not connected yet"))
            body.add(Ink.body(this, "Your Mac keeps your projects. Connect to it to see where your drawings are saved.").apply { setTextColor(Ink.GREY) })
            body.add(unsentRow(unsent), Ink.dp(this, Ink.L))
            return
        }
        body.add(Ink.caption(this, "NOW SAVING TO"))
        body.add(Ink.title(this, st.project), Ink.dp(this, Ink.XS))
        body.add(Ink.body(this, st.session), 0)
        val card = Ink.card(this)
        card.add(Ink.infoRow(this, "On your Mac", st.location))
        card.add(Ink.infoRow(this, "Status", statusText(st, connected)), 0)
        card.add(Ink.infoRow(this, "Last saved", if (st.savedAtMs > 0) DateUtils.getRelativeTimeSpanString(st.savedAtMs).toString() else "—"), 0)
        card.add(unsentRow(unsent), 0)
        st.error?.let { card.add(problem(it)) }
        body.add(card, Ink.dp(this, Ink.M))

        if (!connected) {
            body.add(Ink.body(this, "Offline: changes to projects need your Mac. Drawing still works; it is kept here and sent when you reconnect.")
                .apply { setTextColor(Ink.GREY) }, Ink.dp(this, Ink.M))
        }
        pending?.let { body.add(Ink.body(this, "Asked your Mac… (${it.replace('_', ' ')})"), Ink.dp(this, Ink.M)) }

        val enabled = connected && pending == null
        body.add(Ink.row(this).apply {
            addView(button("Save now", enabled) { manager.requestStorage("save_now") }, LinearLayout.LayoutParams(0, -2, 1f))
            addView(View(context), LinearLayout.LayoutParams(Ink.dp(context, Ink.S), 1))
            addView(button("New session", enabled) { manager.requestStorage("new_session") }, LinearLayout.LayoutParams(0, -2, 1f))
        }, Ink.dp(this, Ink.L))

        body.add(Ink.section(this, "Projects on your Mac"))
        for (p in st.projects) {
            val active = p == st.project
            body.add(Ink.listRow(this, if (active) R.drawable.ic_check else R.drawable.ic_laptop, p,
                if (active) "Open now" else "Tap to switch (saves the current session first)") {
                if (!active && enabled) manager.requestStorage("switch_project", p)
            }, 0)
        }
        val name = EditText(this).apply {
            hint = "New project name"
            textSize = Ink.BODY
            background = Ink.box(context, Ink.PAPER, Ink.INK)
            setPadding(Ink.dp(context, Ink.M), Ink.dp(context, 12), Ink.dp(context, Ink.M), Ink.dp(context, 12))
            isEnabled = enabled
        }
        body.add(Ink.row(this).apply {
            addView(name, LinearLayout.LayoutParams(0, -2, 1f))
            addView(View(context), LinearLayout.LayoutParams(Ink.dp(context, Ink.S), 1))
            addView(button("Create", enabled) {
                val n = name.text.toString().trim()
                if (n.isNotEmpty()) manager.requestStorage("create_project", n)
            })
        }, Ink.dp(this, Ink.S))

        if (st.locations.size > 1) {
            body.add(Ink.section(this, "Storage folder on your Mac"))
            body.add(Ink.caption(this, "Folders this Mac has used. Choosing one asks the Mac to switch; it checks the folder first. To add a new folder, use Projects & Storage on the Mac."), 0)
            for (loc in st.locations) {
                val current = st.location.startsWith(loc)
                body.add(Ink.listRow(this, if (current) R.drawable.ic_check else R.drawable.ic_laptop, loc,
                    if (current) "In use" else "Use this folder") {
                    if (!current && enabled) manager.requestStorage("use_location", loc)
                }, 0)
            }
        }
    }

    private fun statusText(st: StorageState, connected: Boolean) = when {
        !connected -> "Offline — Mac status unknown"
        st.status == "empty" -> "New session — nothing to save yet"
        st.status == "saved" -> "Saved"
        st.status == "saving" -> "Saving…"
        st.status == "unsaved" -> "Changes not saved yet"
        else -> "Save failed"
    }

    private fun unsentRow(n: Int) = Ink.infoRow(this, "On this tablet", if (n == 0) "Everything sent" else "$n stroke${if (n == 1) "" else "s"} waiting to send")

    private fun button(label: String, enabled: Boolean, onClick: () -> Unit) =
        Ink.button(this, label, Ink.ButtonStyle.SECONDARY) { if (enabled) onClick() }.apply { alpha = if (enabled) 1f else 0.4f }

    private fun problem(text: String) = TextView(this).apply {
        this.text = "Save failed: $text"
        textSize = Ink.BODY
        setTypeface(typeface, android.graphics.Typeface.BOLD)
        setTextColor(Ink.INK)
    }
}
