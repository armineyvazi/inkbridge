package app.inkbridge.android.features.canvas

import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import app.inkbridge.android.R
import app.inkbridge.android.design.Ink
import app.inkbridge.core.canvas.ToolSettings
import app.inkbridge.core.canvas.ToolSize
import app.inkbridge.core.canvas.Viewport
import app.inkbridge.core.protocol.InkPoint
import app.inkbridge.core.protocol.Tool
import app.inkbridge.core.protocol.WireStyle
import kotlin.math.ln
import kotlin.math.exp

/** Pen-size controls on the canvas. Sizes are canvas px (page units); see [ToolSettings]. */
object PenControls {
    /** Tools the tablet can pick. The laser is chosen on the Mac. */
    val TOOLS = listOf(Tool.PEN, Tool.HIGHLIGHTER, Tool.ERASER)

    fun icon(t: Tool) = when (t) {
        Tool.PEN -> R.drawable.ic_pen
        Tool.HIGHLIGHTER -> R.drawable.ic_highlighter
        Tool.ERASER -> R.drawable.ic_eraser
        Tool.LASER -> R.drawable.ic_pen
    }

    fun name(t: Tool) = when (t) {
        Tool.PEN -> "Pen"
        Tool.HIGHLIGHTER -> "Highlighter"
        Tool.ERASER -> "Eraser"
        Tool.LASER -> "Laser"
    }

    /** "4", "4.5", "0.5": sizes are on a 0.5 grid below 12 and whole above. */
    fun format(v: Double): String = if (v == Math.floor(v)) v.toInt().toString() else String.format(java.util.Locale.US, "%.1f", v)

    /** What the slider snaps to while dragging. */
    fun snap(v: Double) = if (v < 12) Math.round(v * 2) / 2.0 else Math.round(v).toDouble()
}

/**
 * Toolbar swatch: a dot as thick as the next stroke will look on screen right now
 * (size × zoom; capped so it fits), with the size in page units underneath.
 * The eraser shows its circle. Tapping opens the size panel.
 */
class SizeSwatch(ctx: Context) : View(ctx) {
    var tool: Tool = Tool.PEN; private set
    var size = 4.0; private set
    var zoom = 1.0; private set
    private val dot = Paint(Paint.ANTI_ALIAS_FLAG)
    private val label = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        textAlign = Paint.Align.CENTER
        typeface = android.graphics.Typeface.DEFAULT_BOLD
        textSize = Ink.dp(ctx, 12).toFloat()
        color = Ink.INK
    }

    init {
        isClickable = true
        contentDescription = "Pen size"
        background = Ink.box(ctx, Ink.PAPER, radius = 8)
    }

    fun set(tool: Tool, size: Double?, zoom: Double) {
        val s = size ?: 0.0
        if (tool == this.tool && s == this.size && zoom == this.zoom) return
        this.tool = tool; this.size = s; this.zoom = zoom
        contentDescription = "${PenControls.name(tool)} size ${PenControls.format(s)}"
        invalidate()
    }

    override fun onMeasure(w: Int, h: Int) = setMeasuredDimension(Ink.dp(context, 60), Ink.dp(context, 48))

    override fun onDraw(c: Canvas) {
        val cx = width / 2f
        val cy = height * 0.4f
        val maxD = height * 0.56f
        val d = (if (tool == Tool.ERASER) 2 * size else size) * zoom
        val r = (d.toFloat() / 2).coerceIn(1.5f, maxD / 2)
        when (tool) {
            Tool.ERASER -> { dot.style = Paint.Style.STROKE; dot.strokeWidth = Ink.dp(context, 1.5f).toFloat(); dot.color = Ink.INK }
            Tool.HIGHLIGHTER -> { dot.style = Paint.Style.FILL; dot.color = 0xFFBDBDBD.toInt() }
            else -> { dot.style = Paint.Style.FILL; dot.color = Ink.INK }
        }
        when (tool) {
            Tool.HIGHLIGHTER -> c.drawRect(cx - maxD / 2, cy - r, cx + maxD / 2, cy + r, dot)
            // A short line at the real width reads better than a dot a few px wide.
            Tool.PEN -> {
                dot.style = Paint.Style.STROKE; dot.strokeCap = Paint.Cap.ROUND; dot.strokeWidth = 2 * r
                c.drawLine(cx - maxD / 2, cy, cx + maxD / 2, cy, dot)
            }
            else -> c.drawCircle(cx, cy, r, dot)
        }
        if (tool != Tool.LASER) c.drawText(PenControls.format(size), cx, height - Ink.dp(context, 4).toFloat(), label)
    }
}

/**
 * Size slider on a log scale: small pens get fine control (0.5 → 1 is as far as
 * 12 → 24). Tall touch target, square knob, no animation (e-ink).
 * [onChange] fires while dragging with `final = false`, then once with `final = true`.
 */
class SizeSlider(ctx: Context, private val onChange: (Double, Boolean) -> Unit) : View(ctx) {
    var spec: ToolSize = ToolSize.PEN
        set(v) { field = v; invalidate() }
    var value = 4.0
        set(v) { field = v; invalidate() }
    private val p = Paint(Paint.ANTI_ALIAS_FLAG)
    private val pad get() = Ink.dp(context, 14).toFloat()

    init { isClickable = true; contentDescription = "Size slider" }

    override fun onMeasure(w: Int, h: Int) = setMeasuredDimension(MeasureSpec.getSize(w), Ink.dp(context, 52))

    private fun fraction(v: Double) = (ln(v / spec.min) / ln(spec.max / spec.min)).coerceIn(0.0, 1.0)
    private fun valueAt(x: Float): Double {
        val f = ((x - pad) / (width - 2 * pad)).toDouble().coerceIn(0.0, 1.0)
        return spec.clamp(PenControls.snap(spec.min * exp(f * ln(spec.max / spec.min))))
    }

    override fun onDraw(c: Canvas) {
        val y = height / 2f
        p.style = Paint.Style.STROKE
        p.strokeCap = Paint.Cap.ROUND
        p.color = Ink.RULE
        p.strokeWidth = Ink.dp(context, 4).toFloat()
        c.drawLine(pad, y, width - pad, y, p)
        val x = pad + (fraction(value) * (width - 2 * pad)).toFloat()
        p.color = Ink.INK
        c.drawLine(pad, y, x, y, p)
        // Preset ticks, so the presets are visible on the scale.
        p.strokeWidth = Ink.dp(context, 2).toFloat()
        for (v in spec.presets) {
            val tx = pad + (fraction(v) * (width - 2 * pad)).toFloat()
            c.drawLine(tx, y + Ink.dp(context, 9), tx, y + Ink.dp(context, 14), p)
        }
        p.style = Paint.Style.FILL
        val k = Ink.dp(context, 11).toFloat()
        c.drawRoundRect(x - k, y - k, x + k, y + k, k / 3, k / 3, p)
    }

    override fun onTouchEvent(e: MotionEvent): Boolean {
        when (e.actionMasked) {
            MotionEvent.ACTION_DOWN -> { parent?.requestDisallowInterceptTouchEvent(true); update(e.x, false) }
            MotionEvent.ACTION_MOVE -> update(e.x, false)
            MotionEvent.ACTION_UP -> { update(e.x, true); performClick() }
            MotionEvent.ACTION_CANCEL -> onChange(value, true)
        }
        return true
    }

    override fun performClick(): Boolean = super.performClick()

    private fun update(x: Float, final: Boolean) {
        val v = valueAt(x)
        if (v != value || final) { value = v; onChange(v, final) }
    }
}

/**
 * The real stroke at the current zoom, drawn with [InkPainter]: a pen line with a
 * pressure swell, a highlighter over a line of ink (so its blend shows), or the
 * eraser's band and circle.
 */
class StrokePreview(ctx: Context) : View(ctx) {
    var tool: Tool = Tool.PEN
    var size = 4.0
    var zoom = 1.0
    private val paint = InkPainter.newPaint()
    private val frame = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; color = Ink.RULE }

    override fun onMeasure(w: Int, h: Int) = setMeasuredDimension(MeasureSpec.getSize(w), Ink.dp(context, 96))

    override fun onDraw(c: Canvas) {
        frame.strokeWidth = Ink.dp(context, 1).toFloat()
        c.drawRoundRect(0f, 0f, width.toFloat(), height.toFloat(), 12f, 12f, frame)
        c.save()
        c.clipRect(2, 2, width - 2, height - 2)
        // The preview canvas is in view px; at zoom z a canvas-px stroke is z px wide.
        val v = Viewport(0.0, 0.0, zoom)
        val w = width / zoom
        val h = height / zoom
        fun wave(amp: Double, pressure: (Double) -> Double) = (0..48).map { i ->
            val f = i / 48.0
            InkPoint(w * (0.1 + 0.8 * f), h * 0.5 + amp * h * Math.sin(f * Math.PI * 2), pressure(f), 0)
        }
        when (tool) {
            Tool.HIGHLIGHTER -> {
                InkPainter.drawSegments(c, paint, wave(0.12) { 0.6 }, WireStyle(Ink.INK, 2.0 / zoom), Tool.PEN, v, dark = false)
                InkPainter.drawSegments(c, paint, wave(0.0) { 1.0 }, WireStyle(Ink.INK, size), Tool.HIGHLIGHTER, v, dark = false)
            }
            Tool.ERASER -> {
                InkPainter.drawSegments(c, paint, wave(0.12) { 0.6 }, WireStyle(Ink.INK, 2.0 / zoom), Tool.PEN, v, dark = false)
                val pts = wave(0.0) { 1.0 }.take(30)
                InkPainter.drawSegments(c, paint, pts, WireStyle(Ink.INK, size), Tool.ERASER, v, dark = false)
                frame.color = Ink.INK
                frame.strokeWidth = Ink.dp(context, 1.5f).toFloat()
                c.drawCircle(v.toViewX(pts.last().x), v.toViewY(pts.last().y), (size * zoom).toFloat(), frame)
                frame.color = Ink.RULE
            }
            // Pressure rises and falls along the line, as with a real hand.
            else -> InkPainter.drawSegments(c, paint, wave(0.18) { f -> 0.25 + 0.75 * Math.sin(f * Math.PI) }, WireStyle(Ink.INK, size), Tool.PEN, v, dark = false)
        }
        c.restore()
    }
}

/**
 * The pen-size panel: tool, live preview, − slider +, and XS…XL presets. Changes
 * apply at once to the next stroke; existing strokes keep their own width.
 */
class PenSheet(
    ctx: Context,
    private val onTool: (Tool) -> Unit,
    private val onSize: (Tool, Double, Boolean) -> Unit,
    private val onClose: () -> Unit,
) : LinearLayout(ctx) {
    private val title = Ink.heading(ctx, "")
    private val value: TextView = Ink.text(ctx, "", Ink.HEADING, bold = true).apply { gravity = Gravity.END }
    private val note = Ink.caption(ctx, "")
    private val preview = StrokePreview(ctx)
    private val slider = SizeSlider(ctx) { v, final -> onSize(current, v, final) }
    private val tools = LinearLayout(ctx)
    private val presets = Ink.row(ctx)
    private var current: Tool = Tool.PEN
    private var settings = ToolSettings()

    init {
        orientation = VERTICAL
        background = Ink.box(ctx, Ink.PAPER, Ink.INK, radius = 14)
        setPadding(Ink.dp(ctx, Ink.M), Ink.dp(ctx, Ink.S), Ink.dp(ctx, Ink.S), Ink.dp(ctx, Ink.M))
        isClickable = true
        addView(Ink.row(ctx).apply {
            addView(title, LayoutParams(0, LayoutParams.WRAP_CONTENT, 1f))
            addView(value, LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT).apply { marginEnd = Ink.dp(ctx, Ink.S) })
            addView(Ink.iconButton(ctx, R.drawable.ic_close, "Close", 48) { onClose() })
        })
        addView(tools, lp(Ink.S))
        addView(preview, lp(Ink.S).apply { marginEnd = Ink.dp(ctx, Ink.S) })
        addView(Ink.row(ctx).apply {
            addView(Ink.iconButton(ctx, R.drawable.ic_minus, "Thinner", 52) { step(false) })
            addView(slider, LayoutParams(0, LayoutParams.WRAP_CONTENT, 1f))
            addView(Ink.iconButton(ctx, R.drawable.ic_plus, "Thicker", 52) { step(true) })
        }, lp(Ink.S))
        addView(presets, lp(Ink.S).apply { marginEnd = Ink.dp(ctx, Ink.S) })
        addView(note, lp(Ink.S))
    }

    private fun step(up: Boolean) {
        val spec = ToolSize.of(current) ?: return
        val v = settings.size(current) ?: return
        onSize(current, spec.step(v, up), true)
    }

    fun render(s: ToolSettings, zoom: Double) {
        settings = s
        current = s.tool
        val spec = ToolSize.of(current)
        val size = s.size(current)
        Ink.setText(title, PenControls.name(current) + " size")
        Ink.setText(value, size?.let { PenControls.format(it) + " px" } ?: "")
        preview.tool = current; preview.size = size ?: 0.0; preview.zoom = zoom; preview.invalidate()
        // Rebuild only what changed: every rebuild is an e-ink refresh of that area.
        if (renderedTool != current) { renderedTool = current; renderTools() }
        if (spec != null && size != null) {
            slider.visibility = VISIBLE
            slider.spec = spec
            slider.value = size
            renderPresets(spec, size)
            val zoomNote = if (zoom != 1.0) "Preview at ${(zoom * 100).toInt()} % zoom. " else ""
            Ink.setText(note, if (current == Tool.ERASER) {
                "Radius on the page. ${zoomNote}Every stroke the circle touches is erased."
            } else {
                (if (current == Tool.PEN) "Width on the page at full pressure. " else "Width on the page. ") + zoomNote +
                    "Applies to new strokes; what you already wrote keeps its width."
            })
        } else {
            slider.visibility = INVISIBLE
            presets.removeAllViews()
            renderedPresets = null
            Ink.setText(note, "The laser pointer is chosen on the Mac and has a fixed size. Pick a tool above to write.")
        }
    }

    /** Size-only update while the slider moves (no rebuild, so the drag is not interrupted). */
    fun preview(size: Double) {
        Ink.setText(value, PenControls.format(size) + " px")
        preview.size = size; preview.invalidate()
    }

    private fun renderTools() {
        tools.removeAllViews()
        val ctx = context
        tools.addView(Ink.segmented(ctx, PenControls.TOOLS.map(PenControls::name), PenControls.TOOLS.indexOf(current)) {
            onTool(PenControls.TOOLS[it])
        }, LayoutParams(0, LayoutParams.WRAP_CONTENT, 1f).apply { marginEnd = Ink.dp(ctx, Ink.S) })
    }

    private var renderedTool: Tool? = null
    private var renderedPresets: Pair<ToolSize, Int>? = null

    private fun renderPresets(spec: ToolSize, size: Double) {
        val near = spec.presets.indexOfFirst { it == size }
        if (renderedPresets == spec to near) return
        renderedPresets = spec to near
        presets.removeAllViews()
        val ctx = context
        spec.presets.forEachIndexed { i, v ->
            val on = i == near
            presets.addView(LinearLayout(ctx).apply {
                orientation = VERTICAL
                gravity = Gravity.CENTER
                minimumHeight = Ink.dp(ctx, 56)
                isClickable = true
                contentDescription = "${ToolSize.LABELS[i]}, ${PenControls.format(v)} px"
                background = Ink.box(ctx, if (on) Ink.INK else Ink.PAPER, Ink.INK, radius = 8)
                addView(Ink.text(ctx, ToolSize.LABELS[i], Ink.CAPTION + 1, bold = true, color = if (on) Ink.PAPER else Ink.INK).apply { gravity = Gravity.CENTER })
                addView(Ink.text(ctx, PenControls.format(v), Ink.CAPTION, color = if (on) Ink.PAPER else Ink.GREY).apply { gravity = Gravity.CENTER })
                setOnClickListener { onSize(current, v, true) }
            }, LayoutParams(0, LayoutParams.WRAP_CONTENT, 1f).apply { if (i > 0) marginStart = Ink.dp(ctx, 6) })
        }
    }

    private fun lp(top: Int) = LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT).apply { topMargin = Ink.dp(context, top) }
}

/**
 * The toolbar's pen group: one button per tool (the selected one solid), then
 * − [swatch] +. Every target is 48 dp; − / + change the size one step without
 * opening anything, the swatch opens [PenSheet].
 */
class PenBar(
    ctx: Context,
    private val onTool: (Tool) -> Unit,
    private val onStep: (Boolean) -> Unit,
    onSwatch: () -> Unit,
) : LinearLayout(ctx) {
    private val toolButtons = PenControls.TOOLS.associateWith { t ->
        FrameLayout(ctx).apply {
            minimumWidth = Ink.dp(ctx, 48); minimumHeight = Ink.dp(ctx, 48)
            isClickable = true
            contentDescription = PenControls.name(t)
            setOnClickListener { onTool(t) }
        }
    }
    val swatch = SizeSwatch(ctx).apply { setOnClickListener { onSwatch() } }
    private var shown: Tool? = null

    init {
        orientation = HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        background = Ink.box(ctx, Ink.PAPER, Ink.INK, radius = 16)
        setPadding(Ink.dp(ctx, 6), Ink.dp(ctx, 4), Ink.dp(ctx, 4), Ink.dp(ctx, 4))
        toolButtons.values.forEach { addView(it, LayoutParams(Ink.dp(ctx, 48), Ink.dp(ctx, 44)).apply { marginEnd = Ink.dp(ctx, 2) }) }
        addView(View(ctx).apply { setBackgroundColor(Ink.RULE) }, LayoutParams(Ink.dp(ctx, 1), Ink.dp(ctx, 32)).apply {
            marginStart = Ink.dp(ctx, 4); marginEnd = Ink.dp(ctx, 4)
        })
        addView(Ink.iconButton(ctx, R.drawable.ic_minus, "Thinner", 48) { onStep(false) })
        addView(swatch)
        addView(Ink.iconButton(ctx, R.drawable.ic_plus, "Thicker", 48) { onStep(true) })
    }

    fun render(s: ToolSettings, zoom: Double) {
        if (shown != s.tool) {
            shown = s.tool
            for ((t, b) in toolButtons) {
                val on = t == s.tool
                b.removeAllViews()
                b.background = Ink.box(context, if (on) Ink.INK else Ink.PAPER, radius = 8)
                b.addView(Ink.icon(context, PenControls.icon(t), if (on) Ink.PAPER else Ink.INK, 24),
                    FrameLayout.LayoutParams(Ink.dp(context, 24), Ink.dp(context, 24), Gravity.CENTER))
                b.isSelected = on
            }
        }
        swatch.set(s.tool, s.size(s.tool), zoom)
    }
}
