# Canvas UI

```
┌──────────────────────────────────────────────────────────────┐
│                           [↶ ↷ │ − 100% + ⛶ │ ◐ ⋮]           │
│                       full-screen ink                        │
│                                                              │
│ ( ‹ ● Studio Mac · Wi-Fi )                                   │
└──────────────────────────────────────────────────────────────┘
```

- **Chip (bottom left since Phase 1):** back arrow, status mark and the short stage ("Studio Mac · Wi-Fi", "Reconnecting…", "Not connected"). Tap it to return to the dashboard. It updates only when the stage changes.
- **Bar (top right):** 48 dp buttons for Undo, Redo, Zoom out, zoom % (tap for actual size), Zoom in, Fit all ink, **Background** (◐, shared with the Mac, see dynamic-backgrounds.md), and ⋮.
- **⋮ menu:**
  - Hide/Show ink on tablet
  - Clear canvas (undoable on the Mac)
  - Refresh screen (clean e-ink refresh)
  - Hide controls (leaves one round ⋮ button)
  - Settings
  - Diagnostics
- **Input:** the pen always draws. One finger pans and two fingers zoom; turn that off with Settings → Pan and zoom with fingers, for palm-heavy writing.
- **Opens at:** Actual size, Fit all ink, or Where I left off (the default; the view is saved when leaving).
- **Background:** the shared background layer (overlay or studio colour shown as grey, plus grid/dots/graph/engineering paper), chosen with ◐ and synced with the Mac.
- **Offline:** drawing works without a connection. Strokes queue (up to 4096 events) and reach the Mac when it reconnects. Undo, Redo and Clear need the Mac, because the Mac owns the document (ADR-006).
- **Persistence:** strokes stay visible because the app-scoped `CanvasDocument` outlives the screen. Leaving the canvas and coming back redraws everything from the mirror.
