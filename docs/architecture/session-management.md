# Session management

Status: autosave, crash recovery, manual save, and PNG/PDF/vector export are
**implemented and unit tested**. Session history UI, the SQLite index and the
`session.*` protocol messages are **not implemented** (Phase 4).

## Lifecycle

See [`diagrams/session-lifecycle.mmd`](../diagrams/session-lifecycle.mmd).

- Each launch starts a session `session-YYYYMMDD-HHMMSS`, unless the previous run
  crashed (next section).
- Every 5 s, if `StrokeStore.revision` changed, **autosave** writes `strokes.json`
  and `session.json`. It writes no renders, so it is cheap.
- **Crash recovery**: `cleanExit` is set to `false` at launch and `true` in
  `applicationWillTerminate`. If the next launch finds it `false`, it reopens the last
  session ID and reloads its strokes ("Recovered unsaved session" appears in the menu).
  At most 5 s of strokes can be lost.
- **Save** (⌃⌥S or the toolbar) writes the vector strokes and renders, then reveals
  the PDF in Finder.

## On disk

```
~/Library/Application Support/InkBridge/
├── Sessions/
│   └── session-20261031-143210/
│       ├── session.json     metadata (below)
│       ├── strokes.json     [Stroke] in normalized coordinates: the source of truth
│       ├── preview.png      2× raster, white or screenshot background
│       ├── export.pdf       vector page at canvas size
│       └── background.png   only if "Include a screenshot" is on
└── Diagnostics/
    └── diagnostics-YYYYMMDD-HHMMSS.txt
```

`session.json` holds: `id`, `title`, `startedAt`, `savedAt`, `deviceName`,
`displayName`, canvas size, surface size, `fit`, `calibration`, `strokeCount`. That is
everything needed to re-render the strokes exactly as they appeared
(`SessionMetadata.mapper`).

**Vector preservation.** `strokes.json` keeps every sample (x, y, pressure, time)
plus style. PDF output is vector paths. A reloaded session is fully editable
(undo/redo history starts fresh).

## Screenshots are opt-in

Screenshots are off by default. When enabled (Settings → Saving), saving calls
`ScreenCaptureKit` (`SCScreenshotManager`, macOS 14+) for the selected display,
**excluding InkBridge's own windows** so the ink is not baked in twice:

- macOS asks for Screen Recording permission the first time. If it is denied or
  unavailable, the save still succeeds without a background, and the menu says so.
- DRM-protected content shows up blacked out by the OS. InkBridge does not try to
  work around it.

## Storage format evaluation

JSON is the current format for `strokes.json`. A 2 000-point stroke is about 80 KB,
so an hour of dense annotation (~200 strokes × 300 points) is about 2–3 MB. That is
fine for autosave every 5 s. A future binary encoding (fixed-width records, or
float16 deltas) would cut this by about 5–8×. See
[`ADR-005`](../decisions/ADR-005-storage.md) for when SQLite and a binary format
become worth it (session history and search).
