# Dynamic backgrounds (Phase 1, built)

**Goal:** whatever is on the Mac (a video, PDF, Figma, documentation), switch InkBridge to a black, white or custom drawing surface instantly and back again, without losing ink, the view or the session.

| Mode | What you see | Clicks |
|---|---|---|
| **Desktop Overlay** (default) | Transparent; ink over the current app | Pass through to the app |
| **Studio Canvas** | An opaque surface in the chosen colour, with optional paper, covering the drawing display | Caught by the canvas (no accidental clicks into hidden apps) |

Underlying apps and web pages are never modified: the background belongs to InkBridge's own window.

## Controls

| Where | Control |
|---|---|
| Mac toolbar (every size) | Background swatch → panel: Desktop Overlay \| Studio Canvas; White, Black, Light gray (#F2F2F2), Dark gray (#202020); custom colour (system colour picker); paper: None, Grid, Dots, Graph, Engineering |
| Mac keys | **⌃⌥B** Overlay ⇄ Studio (last studio colour); **⌃⌥⇧B** Studio black ⇄ white; **⌃⌥Z** undoes a background change |
| BOOX canvas bar | Background button → panel with the same modes, presets and paper. A custom colour picked on the Mac shows as "Custom" |

Every switch is instant and:
- keeps all strokes, their positions, the zoom/pan and the session (no new session, nothing unsaved is lost);
- is one undo step;
- is saved with the session;
- appears on the other device.

## Choices made

- **Patterns are anchored to the canvas**, not the screen, so they zoom and pan with the ink and stay aligned with diagrams.
- **The tablet shows colours as greys.** Very dark surfaces become solid black with white ink; near-white becomes clean paper. The real colour is kept and exported.
- **Studio catches clicks.** In overlay mode the Mac stays fully usable underneath. In studio the surface is a separate workspace, so clicks belong to it. Press ⌃⌥B to go back.
- **Templates** (beyond the paper patterns) are not built yet.
