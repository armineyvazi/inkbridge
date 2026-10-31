# Component library (`design/Ink.kt`)

Every component is built in code from the same tokens, with no AppCompat or Material dependency. See [android-ui-guidelines.md](android-ui-guidelines.md) for the tokens.

| Component | Function | Behaviour |
|---|---|---|
| Text styles | `display`, `title`, `heading`, `body`, `caption`, `text(size,bold,color)` | Scaled by `Ink.textScale` (Text size setting) |
| Button | `button(label, PRIMARY/SECONDARY/GHOST, icon)` | ≥ 56 dp tall. Primary is solid ink with paper text; secondary has a 2 dp ink border; ghost has no border. Pressed state is a light fill (no ripple animation) |
| Icon button | `iconButton(res, label, size)` | Square, labelled (`contentDescription`), 56 dp by default |
| Card | `card()` | 2 dp border, 14 dp radius, 24 dp padding, no shadow |
| Page | `page(content)` | Scrolling, 32 dp margins, max 720 dp wide, no overscroll glow |
| Top bar | `topBar(title, onBack, actions…)` | 64 dp, closed by a 2 dp solid rule |
| Section | `section(title)` | Small caps label with a hairline |
| Rule | `rule()` | 1 dp hairline that measures itself |
| Info row | `infoRow(label, value)` + `setValue` | Label/value pair; updates without relayout when unchanged |
| List row | `listRow(icon, title, subtitle, onClick)` | 64 dp, chevron, pressed fill |
| Segmented control | `segmented(options, selected, onSelect)` | All options visible; the selected one is solid ink. Replaces dropdowns, which need extra refreshes |
| Toggle | `Ink.Toggle(initial, onChange)` | 56×32 dp. On is a filled track with the knob right; off is an outline with the knob left. State is shown twice, by fill and by position |
| Setting row | `setting(title, detail, control, below)` | Title and explanation, with the control on the right or below |
| Status mark | `statusMark(tone)` | GOOD filled dot · BUSY ring with centre · NEUTRAL open ring · PROBLEM inverted "!" square |
| Chip | `chip()` | Rounded 1 dp outline for the canvas status |
| Clean refresh | `EInk.flash(root)` / `InkActivity.cleanRefresh()` | 120 ms black cover |

`InkActivity` is the base screen. It removes transitions, applies the text size, and provides `observe(flow)`, which collects only while the screen is visible.
