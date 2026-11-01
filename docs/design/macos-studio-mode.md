# macOS Studio mode

- **Background button** at the start of the toolbar. It shows a dashed rectangle in overlay mode, or the studio colour. A popover holds the panel described in [dynamic-backgrounds.md](dynamic-backgrounds.md).
- **Window behaviour:** studio makes the overlay window opaque and click-catching. The toolbar (panel level above) remains usable. Menu-bar icon, toolbar sizes and docking are unchanged.
- **Shortcuts:**
  - ⌃⌥B studio on/off
  - ⌃⌥⇧B black ⇄ white
  - existing: ⌃⌥P/H/E/L tools, Z/⇧Z undo/redo, C clear, F fit, 0 home, S save, T toolbar, K connect
- **Save:**
  - In studio, the save options say the full page uses the canvas background, and no screenshot is taken.
  - The bundle adds `background/background.json`, `background/canvas-background.png` and `full-page.pdf`.
  - `annotations/annotations.png` stays transparent.

## Planned grouping (Phases 2–4)

The spec suggests these groups: Workspace · Background · Drawing · Geometry · Editing · Layers · Session. They will be grouped popovers on the existing adaptive toolbar, not a longer bar. Only the Background group exists today.

## Multiple displays (2026-11-01)

- **Default: Follow the screen I click.** Ink, Studio Canvas and the toolbar move to the display the user last clicked on. Global and local mouse-button monitors drive this; they need no Accessibility permission. The drawing is one canvas, so its strokes are re-mapped onto the new display, and nothing is lost or moved in canvas px.
- **Pinned display:** toolbar ••• → Display, the menu-bar menu → Draw On, or Settings. "Otherwise draw on" is used when following is off.
- The fallback is the **primary display** (the one with the menu bar), never `NSScreen.main`. `NSScreen.main` follows the focused window, which made ink jump between monitors.
- Studio Canvas covers only the active display; the others stay usable.
- A docked toolbar re-centres on the new display. A floating toolbar keeps its offset from the display's corner.

## Toolbar position bug (fixed 2026-11-01)

- **Symptom:** the toolbar moved off-centre, to the right, by itself.
- **Cause:** `windowDidMove` treated moves that macOS and SwiftUI make on their own (content resizes, display changes) as a user drag. That switched the dock to "floating" and pinned the left edge, so a wider bar grew to the right.
- **Fix:**
  - Only a move with the mouse button held counts as a drag.
  - A docked bar re-centres when its width changes.
  - Layout measures the updated content.
  - Installs that had been switched to floating by mistake are reset once to bottom-centre.
