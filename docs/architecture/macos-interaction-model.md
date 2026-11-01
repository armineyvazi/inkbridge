# macOS interaction model

## Audit (2026-11-01): what was wrong and why

| Symptom | Root cause | Fix |
|---|---|---|
| "I clicked my monitor and nothing worked" | With "follow the screen I click" on, the **opaque, click-catching Studio Canvas moved onto whichever monitor was clicked**, covering the app the user was trying to use | Following clicks is allowed **only while the window is click-through** (Desktop Overlay in pointer mode) |
| Clicking the Studio Canvas did nothing | The studio window caught mouse events but had no mouse behaviour | Studio: mouse drag pans (pointer mode) or draws (draw mode); scroll pans; pinch zooms |
| No way to draw with the Mac mouse, and no visible state for what a click does | No explicit model | A `PointerMode` (pointer / draw) toggle on the toolbar, plus ⌃⌥D and the menu bar |
| Esc / ⌘Z did nothing on the studio | The window could never become key | The studio may become key; the overlay never does, so typing keeps going to the annotated app |
| Ink jumped between monitors | The fallback used `NSScreen.main`, which follows window focus | Fall back to the primary display |
| Toolbar drifted right | Moves made by macOS or SwiftUI were treated as user drags → "floating" with the left edge pinned | Only moves with the mouse button held count; re-centre on resize |

## The model (`WindowInteraction.resolve`, InkBridgeCore)

| Workspace | Mouse mode | Window | Mouse | Keyboard | Follows clicks |
|---|---|---|---|---|---|
| Desktop Overlay | **pointer** (default) | click-through | goes to apps underneath (play/pause, browse) | stays with the app | yes |
| Desktop Overlay | draw | catches the mouse on its display only | draws; other displays untouched | stays with the app | no |
| Studio Canvas | pointer | catches the mouse | drag pans; scroll pans; pinch zooms | Esc back to the desktop, ⌘Z/⇧⌘Z, +/−/0, D | no |
| Studio Canvas | draw | catches the mouse | draws; scroll and pinch still navigate | same | no |

- **The tablet pen always draws**, whatever the mouse mode.
- The toolbar (a panel above the overlay) always works. Global ⌃⌥ shortcuts (Carbon hot keys, no Accessibility permission needed) always work.
- Workflow D: draw over YouTube with the pen → click Play with the mouse (pointer mode, click-through) → keep drawing with the pen. There is no mode switch to forget, because the mouse never intercepts in pointer mode.

## Multiple displays

- Overlay windows are placed at `NSScreen.frame` in global coordinates. Displays may have negative or non-zero origins and mixed scales.
- Drawing uses view-local points through `CoordinateMapper`, so neither the display origin nor the backing scale enters the maths.
- The mode is either follow-click (default) or a pinned display; the fallback is the primary display.
- Screen-parameter changes (connect/disconnect, resolution, arrangement) re-run `relayoutOverlay`.

## Verification

- **Unit (InteractionTests):** policy invariants ("only click-through may follow"; "studio always does something on click"), mouse → canvas mapping on two display geometries, and mouse strokes being undoable.
- **In-process self-test (`InkBridge --self-test`)** on the owner's real 3-display setup: built-in 1512×982 @2×, MSI 1920×1080 @1× at (840, 982), MSI at (−1080, 982). **18/18 pass:**
  - the overlay lands exactly on each display, after moving from another;
  - the window flags match the policy in all 4 modes;
  - synthetic mouse events reach the view and map to the canvas and back within 0.5 pt.
- **Not automatable here:** real clicks on the hardware (no Accessibility permission for event injection). See [../testing/macos-interaction-matrix.md](../testing/macos-interaction-matrix.md).
