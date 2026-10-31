package app.inkbridge.android.design

import android.content.Context
import android.content.res.ColorStateList
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.Drawable
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.StateListDrawable
import android.text.TextUtils
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import app.inkbridge.core.connection.Tone

/**
 * The InkBridge design system for e-ink (docs/design/component-library.md).
 *
 * Paper and ink only: pure black on white, plus one dark grey for secondary
 * text. Mid-greys are dithered on e-ink and look dirty, so they are avoided
 * for text. Hierarchy comes from size, weight and borders, never colour or
 * shadow. Nothing animates. Pressed states invert briefly instead of fading.
 *
 * Built in code rather than XML so every screen shares exactly these
 * metrics, and so there is no AppCompat/Material dependency to restyle.
 */
object Ink {
    const val INK = Color.BLACK
    const val PAPER = Color.WHITE
    /** Secondary text. Dark enough to render as solid pixels on Carta panels. */
    const val GREY = 0xFF404040.toInt()
    /** Disabled and hairline. The only light grey, used for lines, not text. */
    const val RULE = 0xFFB0B0B0.toInt()
    /** Pressed background. */
    const val PRESSED = 0xFFD8D8D8.toInt()

    // Spacing scale (dp). Everything is a multiple of 4.
    const val XS = 4
    const val S = 8
    const val M = 16
    const val L = 24
    const val XL = 32
    const val XXL = 48

    /** Minimum touch target: larger than Android's 48dp because pens and fingers both hit it. */
    const val TARGET = 56

    // Type scale (sp).
    const val DISPLAY = 34f
    const val TITLE = 24f
    const val HEADING = 19f
    const val BODY = 17f
    const val CAPTION = 14f

    /** Settings → Display → Text size. Applied when a screen is built. */
    @JvmStatic var textScale = 1f

    const val BORDER = 2
    const val RADIUS = 10

    fun dp(ctx: Context, v: Number): Int =
        TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v.toFloat(), ctx.resources.displayMetrics).toInt()

    // MARK: Text

    fun text(ctx: Context, s: CharSequence = "", size: Float = BODY, bold: Boolean = false, color: Int = INK) =
        TextView(ctx).apply {
            text = s
            setTextSize(TypedValue.COMPLEX_UNIT_SP, size * textScale)
            setTextColor(color)
            typeface = if (bold) Typeface.create("sans-serif-medium", Typeface.BOLD) else Typeface.create("sans-serif", Typeface.NORMAL)
            setLineSpacing(0f, 1.15f)
            includeFontPadding = false
        }

    fun display(ctx: Context, s: CharSequence) = text(ctx, s, DISPLAY, bold = true)
    fun title(ctx: Context, s: CharSequence) = text(ctx, s, TITLE, bold = true)
    fun heading(ctx: Context, s: CharSequence) = text(ctx, s, HEADING, bold = true)
    fun body(ctx: Context, s: CharSequence) = text(ctx, s, BODY)
    fun caption(ctx: Context, s: CharSequence) = text(ctx, s, CAPTION, color = GREY)

    /** Section label: small caps-style heading over a hairline. */
    fun section(ctx: Context, s: String) = LinearLayout(ctx).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(0, dp(ctx, L), 0, dp(ctx, S))
        addView(text(ctx, s.uppercase(), CAPTION, bold = true).apply { letterSpacing = 0.08f })
        addView(rule(ctx), LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(ctx, 1)).apply {
            topMargin = dp(ctx, S)
        })
    }

    /** A 1dp hairline. Measures itself, so it can go into any container without layout params. */
    fun rule(ctx: Context): View = object : View(ctx) {
        override fun onMeasure(w: Int, h: Int) = setMeasuredDimension(MeasureSpec.getSize(w), dp(ctx, 1))
    }.apply { setBackgroundColor(RULE) }

    // MARK: Shapes

    fun box(ctx: Context, fill: Int, stroke: Int? = null, radius: Int = RADIUS, strokeDp: Int = BORDER) =
        GradientDrawable().apply {
            setColor(fill)
            cornerRadius = dp(ctx, radius).toFloat()
            stroke?.let { setStroke(dp(ctx, strokeDp), it) }
        }

    private fun pressable(normal: Drawable, pressed: Drawable) = StateListDrawable().apply {
        addState(intArrayOf(android.R.attr.state_pressed), pressed)
        addState(intArrayOf(), normal)
    }

    // MARK: Buttons

    enum class ButtonStyle { PRIMARY, SECONDARY, GHOST }

    /**
     * A full-width button. PRIMARY (solid ink) is used once per screen, for
     * the action most people came to do.
     */
    fun button(ctx: Context, label: String, style: ButtonStyle = ButtonStyle.SECONDARY, icon: Int? = null, onClick: () -> Unit) =
        LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            minimumHeight = dp(ctx, TARGET)
            setPadding(dp(ctx, L), 0, dp(ctx, L), 0)
            isClickable = true
            isFocusable = true
            contentDescription = label
            val fg = if (style == ButtonStyle.PRIMARY) PAPER else INK
            background = when (style) {
                ButtonStyle.PRIMARY -> pressable(box(ctx, INK), box(ctx, GREY))
                ButtonStyle.SECONDARY -> pressable(box(ctx, PAPER, INK), box(ctx, PRESSED, INK))
                ButtonStyle.GHOST -> pressable(box(ctx, PAPER), box(ctx, PRESSED))
            }
            icon?.let {
                addView(icon(ctx, it, fg, 22), LinearLayout.LayoutParams(dp(ctx, 22), dp(ctx, 22)).apply { marginEnd = dp(ctx, S + 2) })
            }
            addView(text(ctx, label, BODY + 1, bold = true, color = fg))
            setOnClickListener { onClick() }
        }

    /** A square icon-only control for toolbars. Always labelled for accessibility. */
    fun iconButton(ctx: Context, res: Int, label: String, sizeDp: Int = TARGET, onClick: () -> Unit) = FrameLayout(ctx).apply {
        val size = dp(ctx, sizeDp)
        minimumWidth = size
        minimumHeight = size
        isClickable = true
        isFocusable = true
        contentDescription = label
        background = pressable(box(ctx, PAPER, radius = 8), box(ctx, PRESSED, radius = 8))
        addView(icon(ctx, res, INK, 26), FrameLayout.LayoutParams(dp(ctx, 26), dp(ctx, 26), Gravity.CENTER))
        setOnClickListener { onClick() }
    }

    fun icon(ctx: Context, res: Int, color: Int = INK, sizeDp: Int = 24) = ImageView(ctx).apply {
        setImageResource(res)
        imageTintList = ColorStateList.valueOf(color)
        minimumWidth = dp(ctx, sizeDp)
        minimumHeight = dp(ctx, sizeDp)
        scaleType = ImageView.ScaleType.FIT_CENTER
    }

    // MARK: Containers

    fun column(ctx: Context, spacingDp: Int = 0) = SpacedColumn(ctx, dp(ctx, spacingDp))

    fun row(ctx: Context) = LinearLayout(ctx).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
    }

    /** A bordered panel. Borders, not shadows: shadows are grey smears on e-ink. */
    fun card(ctx: Context) = SpacedColumn(ctx, dp(ctx, S)).apply {
        background = box(ctx, PAPER, INK, radius = 14)
        setPadding(dp(ctx, L), dp(ctx, L), dp(ctx, L), dp(ctx, L))
    }

    /** A scrolling page with comfortable margins, centred and width-capped for reading. */
    fun page(ctx: Context, content: View) = ScrollView(ctx).apply {
        isFillViewport = true
        setBackgroundColor(PAPER)
        isVerticalScrollBarEnabled = false
        overScrollMode = View.OVER_SCROLL_NEVER
        addView(FrameLayout(ctx).apply {
            addView(content, FrameLayout.LayoutParams(minOf(dp(ctx, 720), ctx.resources.displayMetrics.widthPixels), ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.CENTER_HORIZONTAL))
            setPadding(dp(ctx, XL), dp(ctx, L), dp(ctx, XL), dp(ctx, XXL))
        })
    }

    /** Back arrow, title, optional trailing actions. Separated from content by a solid rule. */
    fun topBar(ctx: Context, title: String, onBack: (() -> Unit)?, vararg actions: View) = LinearLayout(ctx).apply {
        orientation = LinearLayout.VERTICAL
        setBackgroundColor(PAPER)
        val bar = row(ctx).apply {
            minimumHeight = dp(ctx, 64)
            setPadding(dp(ctx, S), 0, dp(ctx, S), 0)
            if (onBack != null) addView(iconButton(ctx, app.inkbridge.android.R.drawable.ic_back, "Back") { onBack() })
            else addView(View(ctx), LinearLayout.LayoutParams(dp(ctx, M), 1))
            addView(text(ctx, title, HEADING + 1, bold = true).apply {
                maxLines = 1
                ellipsize = TextUtils.TruncateAt.END
                setPadding(dp(ctx, S), 0, 0, 0)
            }, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
            actions.forEach { addView(it) }
        }
        addView(bar)
        addView(View(ctx).apply { setBackgroundColor(INK) }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(ctx, BORDER)))
    }

    // MARK: Status

    /**
     * Status is shown by shape, so it survives monochrome: a solid dot for
     * connected, a ring with a centre for in-progress, an open ring for idle,
     * a bordered "!" for problems. Always next to words, never alone.
     */
    fun statusMark(ctx: Context, tone: Tone, sizeDp: Int = 18): View = object : View(ctx) {
        private val p = android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG).apply { color = INK }
        override fun onDraw(c: android.graphics.Canvas) {
            val r = width / 2f
            val sw = dp(ctx, 2).toFloat()
            when (tone) {
                Tone.GOOD -> { p.style = android.graphics.Paint.Style.FILL; c.drawCircle(r, r, r, p) }
                Tone.BUSY -> {
                    p.style = android.graphics.Paint.Style.STROKE; p.strokeWidth = sw; c.drawCircle(r, r, r - sw, p)
                    p.style = android.graphics.Paint.Style.FILL; c.drawCircle(r, r, r * 0.35f, p)
                }
                Tone.NEUTRAL -> { p.style = android.graphics.Paint.Style.STROKE; p.strokeWidth = sw; c.drawCircle(r, r, r - sw, p) }
                Tone.PROBLEM -> {
                    p.style = android.graphics.Paint.Style.FILL; c.drawRect(0f, 0f, width.toFloat(), height.toFloat(), p)
                    p.color = PAPER; p.textAlign = android.graphics.Paint.Align.CENTER; p.textSize = height * 0.8f
                    p.typeface = Typeface.DEFAULT_BOLD
                    c.drawText("!", r, height * 0.8f, p); p.color = INK
                }
            }
        }
    }.apply { layoutParams = LinearLayout.LayoutParams(dp(ctx, sizeDp), dp(ctx, sizeDp)) }

    /** A compact pill: status mark + short label. Used on the canvas. */
    fun chip(ctx: Context) = row(ctx).apply {
        background = box(ctx, PAPER, INK, radius = 20, strokeDp = 1)
        setPadding(dp(ctx, 12), dp(ctx, 6), dp(ctx, 14), dp(ctx, 6))
    }

    // MARK: Rows and controls

    /** Label on the left, value on the right; for facts, not actions. */
    fun infoRow(ctx: Context, label: String, value: String) = row(ctx).apply {
        minimumHeight = dp(ctx, 36)
        addView(caption(ctx, label), LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 0.42f))
        addView(body(ctx, value).apply { tag = VALUE_TAG }, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 0.58f))
    }

    const val VALUE_TAG = "value"

    /** Updates an [infoRow]'s value without relayout when unchanged (every redraw costs an e-ink refresh). */
    fun setValue(row: View, value: String) {
        (row.findViewWithTag<TextView>(VALUE_TAG))?.let { if (it.text.toString() != value) it.text = value }
    }

    fun setText(v: TextView, value: CharSequence) {
        if (v.text.toString() != value.toString()) v.text = value
    }

    /** A tappable list row: icon, title, optional subtitle, chevron. */
    fun listRow(ctx: Context, iconRes: Int?, title: String, subtitle: String? = null, onClick: () -> Unit) = row(ctx).apply {
        minimumHeight = dp(ctx, 64)
        setPadding(dp(ctx, XS), dp(ctx, S), dp(ctx, XS), dp(ctx, S))
        isClickable = true
        isFocusable = true
        contentDescription = title
        background = pressable(box(ctx, PAPER, radius = 8), box(ctx, PRESSED, radius = 8))
        iconRes?.let { addView(icon(ctx, it, INK, 26), LinearLayout.LayoutParams(dp(ctx, 26), dp(ctx, 26)).apply { marginEnd = dp(ctx, M) }) }
        addView(LinearLayout(ctx).apply {
            orientation = LinearLayout.VERTICAL
            addView(text(ctx, title, BODY, bold = true))
            subtitle?.let { addView(caption(ctx, it).apply { tag = VALUE_TAG; setPadding(0, dp(ctx, 2), 0, 0) }) }
        }, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        addView(icon(ctx, app.inkbridge.android.R.drawable.ic_chevron, INK, 20), LinearLayout.LayoutParams(dp(ctx, 20), dp(ctx, 20)))
        setOnClickListener { onClick() }
    }

    /**
     * Choose one of a few options. Every option is visible (no dropdown to
     * open, so no extra refresh), and the chosen one is solid ink.
     */
    fun segmented(ctx: Context, options: List<String>, selected: Int, onSelect: (Int) -> Unit): LinearLayout {
        val group = row(ctx).apply { background = box(ctx, PAPER, INK) }
        fun paint() {
            for (i in 0 until group.childCount) {
                val cell = group.getChildAt(i) as TextView
                val on = cell.tag == true
                cell.setTextColor(if (on) PAPER else INK)
                cell.background = if (on) box(ctx, INK, radius = RADIUS - 2) else null
            }
        }
        options.forEachIndexed { i, label ->
            group.addView(text(ctx, label, CAPTION + 1, bold = true).apply {
                gravity = Gravity.CENTER
                minimumHeight = dp(ctx, 48)
                setPadding(dp(ctx, S), 0, dp(ctx, S), 0)
                tag = i == selected
                isClickable = true
                contentDescription = label
                setOnClickListener {
                    if (tag == true) return@setOnClickListener
                    for (j in 0 until group.childCount) group.getChildAt(j).tag = j == i
                    paint()
                    onSelect(i)
                }
            }, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f).apply { setMargins(dp(ctx, 3), dp(ctx, 3), dp(ctx, 3), dp(ctx, 3)) })
        }
        paint()
        return group
    }

    /** On/off switch drawn as a bordered track; the knob position and fill both carry the state. */
    class Toggle(ctx: Context, initial: Boolean, private val onChange: (Boolean) -> Unit) : View(ctx) {
        var checked = initial
            private set
        private val p = android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG)
        private val sw = dp(ctx, 2).toFloat()

        init {
            isClickable = true
            setOnClickListener { checked = !checked; invalidate(); onChange(checked) }
        }

        override fun onMeasure(w: Int, h: Int) = setMeasuredDimension(dp(context, 56), dp(context, 32))

        override fun onDraw(c: android.graphics.Canvas) {
            val r = height / 2f
            p.style = android.graphics.Paint.Style.FILL
            p.color = if (checked) INK else PAPER
            c.drawRoundRect(sw / 2, sw / 2, width - sw / 2, height - sw / 2, r, r, p)
            p.style = android.graphics.Paint.Style.STROKE; p.strokeWidth = sw; p.color = INK
            c.drawRoundRect(sw / 2, sw / 2, width - sw / 2, height - sw / 2, r, r, p)
            p.style = android.graphics.Paint.Style.FILL
            p.color = if (checked) PAPER else INK
            c.drawCircle(if (checked) width - r else r, r, r - sw * 2.5f, p)
        }
    }

    /** Title + explanation on the left, a control on the right (or below, for segmented controls). */
    fun setting(ctx: Context, title: String, detail: String?, control: View, below: Boolean = false) = SpacedColumn(ctx, dp(ctx, S)).apply {
        setPadding(0, dp(ctx, 12), 0, dp(ctx, 12))
        val head = row(ctx)
        head.addView(LinearLayout(ctx).apply {
            orientation = LinearLayout.VERTICAL
            addView(text(ctx, title, BODY, bold = true))
            detail?.let { addView(caption(ctx, it).apply { setPadding(0, dp(ctx, 2), dp(ctx, M), 0) }) }
        }, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        if (!below) head.addView(control)
        add(head)
        if (below) add(control)
    }
}

/** A vertical LinearLayout that puts [spacing] px between children. */

class SpacedColumn(ctx: Context, private val spacing: Int) : LinearLayout(ctx) {
    init {
        orientation = VERTICAL
    }

    fun add(v: View, gapBefore: Int? = null, width: Int = ViewGroup.LayoutParams.MATCH_PARENT): SpacedColumn {
        val lp = LayoutParams(width, ViewGroup.LayoutParams.WRAP_CONTENT)
        if (childCount > 0) lp.topMargin = gapBefore ?: spacing
        addView(v, lp)
        return this
    }
}
