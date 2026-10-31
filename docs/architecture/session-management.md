# Session management and export

Status (2026-10-31):
- **Implemented and unit tested:** autosave, crash recovery, layered export through a
  native save panel, PNG/JPEG full page, transparent ink layer, SVG and vector
  strokes.
- **Not implemented** (Phase 4): the session history UI, the SQLite index, and the
  `session.*` protocol messages.

## What is stored, and where

The storage model keeps these apart (ADR-006). **The viewport is never part of
stroke coordinates.**

| Data | Where | Format |
|---|---|---|
| Original vector strokes (canvas px, every sample: x, y, pressure, time; tool; style) | `strokes.json` | JSON array of `Stroke` |
| Viewport at save time | `metadata.json` → `viewport` | `{x, y, zoom}` |
| Canvas dimensions (tablet view px = canvas px at zoom 1) and page size | `metadata.json` | numbers |
| Coordinate mapping (how canvas px land on the page) | `coordinate-mapping.json` | formula plus parameters |
| Background screenshot | `background/screen.png` | PNG, display resolution |
| Exported annotation layer | `annotations/annotations.png`, `annotations.svg` | transparent PNG, SVG |
| Session metadata | `metadata.json`, `manifest.json` | JSON |

## Autosave and recovery

- Every 5 s, if the document changed, InkBridge writes `strokes.json` and
  `session.json` to `~/Library/Application Support/InkBridge/Sessions/<session-id>/`.
- `cleanExit` is false while the app runs. After a crash, the next launch reopens the
  last session, including its viewport. At most 5 s can be lost.
- Format: `session.json` has `"format": 2` (canvas px). Format-1 sessions (normalized
  coordinates, from the first day of development) are **rejected rather than
  misread**.

## Nothing destroys saved work

| Action | Effect on the live document | Effect on disk |
|---|---|---|
| Clear (Mac or tablet) | strokes removed, **undoable** | none until the next autosave; exported folders never touched |
| Hide ink (Mac or tablet) | none (display only) | none |
| Hide toolbar | none | none |
| Tablet disconnects or restarts | none; the tablet gets a full resync on reconnect | none |
| Mac app quits or crashes | restored from autosave | none |
| Export to an existing folder | — | only after the save panel's own "Replace?" confirmation; atomic swap |

## Export folder

Save… (⌃⌥S) opens the native save panel (see the [UI specification](ui-specification.md#save)).
The chosen name becomes a folder:

```text
InkBridge 2026-10-31 at 15.42.10/
├── full-page.png | full-page.jpg   screen + ink composite, display pixel resolution   (needs background)
├── preview.png                     composite, or ink on white if there is no background
├── annotations/
│   ├── annotations.png             ink only, transparent, same pixel grid as full-page
│   ├── annotations.svg             ink only, vector, same coordinates (points)
│   └── strokes.json                every stroke on the infinite canvas: the editable source
├── background/
│   └── screen.png                  the screenshot alone                                  (if captured)
├── session/
│   ├── metadata.json               session, devices, viewport, canvas size, calibration
│   └── coordinate-mapping.json     canvas px → page transform and its parameters
└── manifest.json                   file list, plus what was skipped and why
```

Choices against the brief's suggested layout:
- The background has its own folder: it is a layer, like the annotations.
- `manifest.json` makes a partial export self-describing.
- The page images and SVG show **the current view**, the page the user saw.
  `strokes.json` holds **the whole canvas**, including ink outside the view.

**Permissions and DRM.**
- Without Screen Recording permission, or with the background turned off: the
  background and full page are skipped, and the manifest and success alert say so.
  The annotation layer, SVG, strokes and metadata are still written.
- DRM-protected content is blacked out by macOS in the background layer. InkBridge does
  not work around that.

**Atomicity.** The export writes into a hidden staging folder next to the destination,
then moves it into place (or `replaceItemAt` when replacing). A failure leaves the
destination exactly as it was.

## Storage format

JSON stays the right choice for now. A dense hour of writing is about 2–3 MB, and
autosave rewrites it in milliseconds. See [ADR-005](../decisions/ADR-005-storage.md)
for when to move to SQLite and a binary format.
