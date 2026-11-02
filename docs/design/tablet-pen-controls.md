# Tablet pen controls (v0.4)

Decision record: [ADR-008](../decisions/ADR-008-pen-size-model.md). Protocol: `tool.state` / `tool.request`.

## On the canvas toolbar (top left)

`[✎ Pen] [▱ Highlighter] [◇ Eraser] | [−] [swatch] [+]`

- **Tool buttons** (48 dp): the selected one is solid ink. A tool switch restores that tool's own size.
- **− / +**: one step for the selected tool, applied to the next stroke. Steps grow with the size:
  0.5 below 6, 1 below 12, 2 below 24, 4 below 48, then 8. Off-grid values snap.
- **Swatch:** the next stroke as it will look on screen right now (size × zoom, capped), with the size
  underneath. Pen: a short line. Highlighter: a grey band. Eraser: its circle. Tap to open the panel.
- The journal header moved under the pen group.

## Size panel

Tool switch, live preview, `−  slider  +`, XS/S/M/L/XL presets with their values, and a note.
- The preview is drawn by `InkPainter`, the renderer's own code, at the current zoom:
  - pen: a pressure swell;
  - highlighter: over a line of ink, so the blend shows;
  - eraser: its band and circle.
- The slider is logarithmic, so small pens get fine control. It snaps to 0.5 below 12 and to whole values above.
  While dragging, only the preview updates; the value is sent on release.
- The laser (chosen on the Mac) has a fixed size; the panel says so.

| Tool | Default | Range | XS | S | M | L | XL |
|---|---|---|---|---|---|---|---|
| Pen (width at full pressure) | 4 | 0.5–24 | 1.5 | 3 | 4.5 | 7 | 11 |
| Highlighter (width) | 36 | 6–96 | 16 | 24 | 36 | 52 | 72 |
| Eraser (radius) | 28 | 4–160 | 8 | 16 | 28 | 48 | 80 |

Units are canvas px: 1 = one tablet pixel at 100 % zoom (≈ 0.11 mm on a 227 ppi BOOX). The
source of these numbers is `protocol/fixtures/tool-sizes.json`.

## Rendering on the tablet (e-ink)

| Tool | Look | Width on screen |
|---|---|---|
| Pen | black (white on dark paper), round caps/joins | `size × zoom × (0.3 + 0.7 × pressure)`, min 1 px |
| Highlighter | opaque grey `#BDBDBD`, DARKEN blend (LIGHTEN `#5C5C5C` on dark) | `size × zoom` |
| Eraser | light band `#DCDCDC`, DARKEN, while the pen is down | `2 × radius × zoom` |
| Laser | dark grey 2 px trail | fixed |

On the Mac the same stored width is drawn `× mapper.scale` in colour, with Catmull-Rom smoothing.
Eraser `stroke.style.width` is the radius (never 0): the tablet draws the sweep band from it.
