# ADR-006: Infinite canvas, a shared document, and protocol v2

- Status: accepted
- Date: 2026-10-31
- Supersedes: the coordinate section of the v1 protocol

## Context

New requirements (owner, 2026-10-31):

- Ink stays visible on the tablet.
- The tablet is an infinite canvas with zoom and pan.
- Tablet and Mac stay synchronized.
- Clearing or hiding never loses saved work.
- Exports keep the background, the annotation layer and the vector data separate.

v1 could not support this:

| v1 property | Problem |
|---|---|
| Points normalized 0…1 to the tablet *screen*, x and y scaled separately | No room outside the screen. Zoom and pan would rewrite stroke data. Rotation distorts shapes |
| One-way stream, tablet → Mac | The tablet can't learn about Mac-side erase, undo, clear, or a restored session |
| Local ink drawn on the UI thread | Measured: p95 pen→Mac rose from 16 to 59 ms |

## Decision

### 1. Four coordinate spaces, one permanent

| Space | Unit | Owner | Persisted? |
|---|---|---|---|
| Stylus input | tablet view px | Android `MotionEvent` | no |
| **Canvas** | **canvas px**: 1 unit = 1 tablet px at zoom 1; unbounded, isotropic, y down | the document | **yes: the only coordinates stored in strokes** |
| Viewport | `{x, y, zoom}`: canvas point at the view's top-left corner, plus the scale | each view; synced | session metadata only |
| Mac display | AppKit points on the selected display | `CoordinateMapper` | no |

- input → canvas: `canvas = viewport.origin + px / zoom`
- canvas → Mac: the viewport's canvas rect (`origin`, size `surfacePx / zoom`) is aspect-fitted onto the display, then calibrated.

The home view is `{0, 0, 1}`. In it, canvas px equal tablet px, so the Mac overlay lines up exactly as in v1. Zoom and pan change only the viewport. Stroke data never changes.

Stroke **width is stored in canvas units**, so ink scales with zoom like real ink on paper.

### 2. The Mac owns the document; the tablet mirrors it

The Mac's `StrokeStore` holds the authoritative document: tool resolution, eraser, undo/redo, clear, sessions. The tablet holds a **mirror** (`CanvasDocument`) for display.

- **Tablet → Mac:**
  - `stroke.*`, as before, with canvas coordinates
  - `canvas.viewport` (pan or zoom)
  - `canvas.command` (`undo` / `redo` / `clear` buttons on the tablet)
- **Mac → tablet:**
  - `stroke.style`: the Mac decided a tablet stroke is highlighter, laser or eraser
  - `doc.remove {ids}`: erase, undo, clear
  - strokes the tablet lacks, sent as `stroke.begin(style) / stroke.point / stroke.end` (undo of an erase, redo, a restored session)
  - `doc.reset`, sent once per connection before a full resync
  - `canvas.viewport` from Mac-side "Fit all" or "Reset view"
- **Diff, never snapshot:** `DocumentSync` tracks which stroke IDs the tablet has. After every document change it sends only the difference. A full transfer happens only on (re)connect.
- **Optimistic local ink:** the tablet draws its own strokes immediately, without waiting for the Mac. On `doc.reset` the tablet keeps strokes it has not yet finished sending, so ink drawn during an outage does not blink away.

### 3. Local rendering on the tablet is off the UI thread

A `SurfaceView` with a dedicated render thread:

- The UI thread only forwards input to the network and queues points.
- The render thread draws new segments into a cached bitmap of the current viewport and posts **only the dirty rect**.
- A full redraw happens only when the viewport or the document changes (pan/zoom end, undo, erase, sync). During a pinch, the cached bitmap is transformed instead of re-rendered.
- This avoids full-screen e-ink refreshes while writing.

**Pen draws, fingers navigate:** one finger pans, two fingers pinch-zoom. On-screen buttons cover zoom in/out, *Fit all* and *Home*.

### 4. Layers in export

**Layers are never merged destructively.** A save writes:

- the composite (`full-page.png` or `.jpg`)
- `annotations.png` (transparent) and `annotations.svg`
- `strokes.json` (vector, every stroke on the infinite canvas)
- the background screenshot, as its own file
- the viewport and coordinate mapping, as metadata

If Screen Recording is not granted, or content is DRM-blocked, the background and composite are skipped and **everything else is still written**.

## Alternatives considered

- **Mac mirrors the tablet's screen region only** (no infinite canvas on the Mac): rejected; the brief requires synchronization.
- **Tablet as document owner:** rejected. Erasing, undo, tool styles and sessions already live on the Mac, and the Mac can hold larger documents.
- **ONYX `TouchHelper` raw drawing for local ink:** fastest e-ink path, but it takes over input, adds a closed-source dependency served over HTTP, and does not support our own pan/zoom rendering. Kept as a future option if the SurfaceView path proves too slow.
- **Periodic full-document snapshots:** simple, but at ~80 KB per long stroke they would flood the link. Rejected in favour of ID diffs.

## Consequences

- **Protocol bumps to v2.** v1 and v2 peers refuse each other with a clear error.
- Sessions saved before this change (normalized coordinates) are not loaded (format 1). They exist only from development on 2026-10-31.
- Annotating Mac screen content lines up only in the home view. When zoomed or panned, the overlay is a whiteboard. That is by design, and *Home* returns to the 1:1 alignment.
