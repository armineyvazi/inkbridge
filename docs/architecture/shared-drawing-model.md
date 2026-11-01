# Shared drawing model

The Mac and the BOOX hold **one logical document**, described the same way in Swift
(`InkBridgeCore`) and Kotlin (`:core`) and kept equal by protocol messages. The Mac owns it
(ADR-006); the tablet keeps a mirror and renders a monochrome preview of it.

The target model for the design-studio work is below. **Built** marks the parts that exist
today, and the phase number marks the planned parts.

```text
Document (Mac: StrokeStore · tablet: CanvasDocument)
├── Background layer            CanvasBackground {mode, color, pattern} + revision     Built (Phase 1)
├── Layers [ordered]                                                                    Phase 4
│   └── Layer {id, name, visible, locked}
│       └── Objects [z-ordered]
│           ├── Stroke  {id, tool, style{color, width, opacity}, points[canvas px]}    Built (pen/highlighter); more tools Phase 2
│           ├── Shape   {id, kind, rect/points, stroke, fill, opacity, rotation}        Phase 2
│           └── Text    {id, string, font size/weight, color, origin}                   Phase 4
├── Command history             undo/redo of add / erase / clear / background           Built; move/resize/layer ops Phase 3–4
└── (not part of the document)
    ├── Viewport {x, y, zoom}   shared view, independent of stored coordinates          Built (ADR-006)
    └── Tool state {tool, color, width, opacity}                                        Phase 2 (sync)
```

## Invariants

1. **Coordinates are canvas px.** One unit is one tablet pixel at zoom 1, and the range is unbounded. Nothing stored depends on screen resolution, Retina scale, zoom, pan or display size.
2. **Layers stay separate.** The background is never rasterised into strokes, and strokes are never rasterised into the background. Export writes each layer separately and composites them only for the "full page" files.
3. **Single writer.** Only the Mac mutates the document. The tablet sends requests (strokes, commands, background), and the Mac applies them and answers. Optimistic display on the tablet is allowed, but the Mac's answer always wins.
4. **Ordering.**
   - Strokes are ordered by per-stream sequence numbers, with deduplication on the Mac.
   - State objects (the background now; tools and layers later) carry a monotonically increasing **revision**. A receiver ignores anything older than what it holds.
5. **Incremental by default.** Changes go as diffs (`DocumentSync`). A full snapshot is sent only on (re)connect.

## Background (Phase 1, built)

| Field | Values | Notes |
|---|---|---|
| `mode` | `overlay` / `studio` | Overlay: transparent over the desktop. Studio: an opaque surface |
| `color` | sRGB `#rrggbbaa` | Used in studio mode. Presets: #FFFFFF, #000000, #F2F2F2, #202020, and any custom colour |
| `pattern` | `none`, `grid` (48), `dots` (48), `graph` (12 / 60), `engineering` (10 / 100) | Spacing in canvas px (minor / major), anchored to the canvas so it pans and zooms with the ink |

- `StrokeStore.setBackground` is one undo step. `backgroundRevision` increments on every change, including undo and redo.
- The background is persisted in `session.json` (`SessionMetadata.background`). Sessions saved without it load as overlay.

See [background-rendering.md](background-rendering.md) and [drawing-synchronization.md](drawing-synchronization.md).
