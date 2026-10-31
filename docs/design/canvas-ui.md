# Canvas UI

```
┌──────────────────────────────────────────────────────────────┐
│ ( ‹ ● Studio Mac · Wi-Fi )        [↶ ↷ │ − 100% + ⛶ │ ⋮]      │
│                                                              │
│                       full-screen ink                        │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

- **Chip (top left):** back arrow, status mark and the short stage ("Studio Mac · Wi-Fi", "Reconnecting…", "Not connected"). Tap it to return to the dashboard. It updates only when the stage changes.
- **Bar (top right):** 48 dp buttons for Undo, Redo, Zoom out, zoom % (tap for actual size), Zoom in, Fit all ink, and ⋮. It is about 350 dp wide, so it never meets the chip in portrait.
- **⋮ menu:**
  - Hide/Show ink on tablet
  - Clear canvas (undoable on the Mac)
  - Refresh screen (clean e-ink refresh)
  - Hide controls (leaves one round ⋮ button)
  - Settings
  - Diagnostics
- **Input:** the pen always draws. One finger pans and two fingers zoom; turn that off with Settings → Pan and zoom with fingers, for palm-heavy writing.
- **Opens at:** Actual size, Fit all ink, or Where I left off (the default; the view is saved when leaving).
- **Background:** blank, dot grid or lines, every 48 canvas px and anchored to the canvas. It is skipped when it would be denser than 12 px on screen, and it is shown on the tablet only.
- **Offline:** drawing works without a connection. Strokes queue (up to 4096 events) and reach the Mac when it reconnects. Undo, Redo and Clear need the Mac, because the Mac owns the document (ADR-006).
- **Persistence:** strokes stay visible because the app-scoped `CanvasDocument` outlives the screen. Leaving the canvas and coming back redraws everything from the mirror.
