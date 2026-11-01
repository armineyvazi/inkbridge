package app.inkbridge.android.features.canvas

import android.content.Context
import android.view.Gravity
import android.view.View
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import app.inkbridge.android.R
import app.inkbridge.android.design.Ink
import app.inkbridge.core.canvas.CanvasBackground
import app.inkbridge.core.canvas.CanvasBackground.Mode
import app.inkbridge.core.canvas.CanvasBackground.Pattern

/**
 * The canvas's background panel: Desktop Overlay / Studio Canvas, the four
 * presets, and paper patterns. Choices apply at once (shown here first, then
 * confirmed by the Mac) and are shared with the Mac.
 *
 * Built as one bordered panel with every option visible (no nested menus),
 * so opening it is a single e-ink refresh. Colours that are not presets
 * (picked on the Mac) appear as "Custom".
 */
class BackgroundSheet(ctx: Context, current: CanvasBackground, private val onPick: (CanvasBackground) -> Unit, onClose: () -> Unit) :
    LinearLayout(ctx) {
    private var bg = current

    private val presets = listOf(
        "White" to CanvasBackground.WHITE, "Black" to CanvasBackground.BLACK,
        "Light" to CanvasBackground.LIGHT_GRAY, "Dark" to CanvasBackground.DARK_GRAY,
    )

    init {
        orientation = VERTICAL
        background = Ink.box(ctx, Ink.PAPER, Ink.INK, radius = 14)
        val pad = Ink.dp(ctx, Ink.M + 4)
        setPadding(pad, Ink.dp(ctx, Ink.S), Ink.dp(ctx, Ink.S), pad)
        isClickable = true  // taps inside never reach the canvas
        render(onClose)
    }

    private fun render(onClose: () -> Unit) {
        removeAllViews()
        val ctx = context
        addView(Ink.row(ctx).apply {
            addView(Ink.heading(ctx, "Background"), LayoutParams(0, LayoutParams.WRAP_CONTENT, 1f))
            addView(Ink.iconButton(ctx, R.drawable.ic_close, "Close", 48) { onClose() })
        })
        addView(Ink.segmented(ctx, listOf("Desktop overlay", "Studio canvas"), if (bg.mode == Mode.OVERLAY) 0 else 1) { i ->
            pick(if (i == 0) bg.copy(mode = Mode.OVERLAY) else bg.copy(mode = Mode.STUDIO), onClose)
        }, margins(top = Ink.S))

        addView(Ink.caption(ctx, "STUDIO COLOUR"), margins(top = Ink.M))
        val swatches = Ink.row(ctx)
        val custom = bg.mode == Mode.STUDIO && presets.none { it.second == bg.argb }
        for ((name, argb) in presets) swatches.addView(swatch(name, argb, bg.mode == Mode.STUDIO && bg.argb == argb, onClose))
        if (custom) swatches.addView(swatch("Custom", bg.argb, true, onClose))
        addView(swatches, margins(top = Ink.XS))

        addView(Ink.caption(ctx, "PAPER"), margins(top = Ink.M))
        val patterns = Pattern.entries
        addView(Ink.segmented(ctx, listOf("None", "Grid", "Dots", "Graph", "Eng."), patterns.indexOf(bg.pattern)) { i ->
            pick(bg.copy(pattern = patterns[i]), onClose)
        }, margins(top = Ink.XS))
        addView(Ink.caption(ctx, "Shared with the Mac. Colours show as greys on this screen; the Mac shows the real colour. Undo reverts a change."),
            margins(top = Ink.S))
    }

    private fun swatch(name: String, argb: Int, selected: Boolean, onClose: () -> Unit): View {
        val ctx = context
        val shown = CanvasBackground.studio(argb).einkPaper
        return LinearLayout(ctx).apply {
            orientation = VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            isClickable = true
            contentDescription = "$name background"
            setPadding(0, 0, Ink.dp(ctx, 10), 0)
            addView(FrameLayout(ctx).apply {
                background = Ink.box(ctx, shown, Ink.INK, radius = 8, strokeDp = if (selected) 4 else 1)
            }, LayoutParams(Ink.dp(ctx, 52), Ink.dp(ctx, 44)))
            addView(TextView(ctx).apply {
                text = name
                textSize = Ink.CAPTION * Ink.textScale
                setTextColor(Ink.INK)
                if (selected) setTypeface(typeface, android.graphics.Typeface.BOLD)
            })
            setOnClickListener { pick(CanvasBackground.studio(argb, bg.pattern), onClose) }
        }
    }

    private fun pick(next: CanvasBackground, onClose: () -> Unit) {
        if (next == bg) return
        bg = next
        onPick(next)
        render(onClose)
    }

    private fun margins(top: Int) = LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT).apply {
        topMargin = Ink.dp(context, top)
    }
}
