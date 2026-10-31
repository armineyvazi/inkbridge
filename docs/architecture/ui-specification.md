# UI specification

What the interface does today. Screens and controls are described as built
(2026-10-31). Design rules: minimal, unobtrusive, never blocks the content being
annotated, and native on each platform.

## macOS

### Menu-bar icon (always present)

- Icon: `pencil.tip.crop.circle`, filled while a tablet is connected.
- **Left-click with the toolbar hidden → the toolbar reappears.** This is how a hidden
  toolbar comes back.
- Left-click with the toolbar visible, or any right-click / ⌃-click → the menu:

| Group | Items |
|---|---|
| Status | Connected: *device* via USB/Wi-Fi · latency · Connect Device… (⌃⌥K) · last status message |
| Toolbar | Show/Hide Toolbar · Toolbar Size ▸ Expanded/Compact/Minimal · Toolbar Position ▸ Bottom/Top/Left/Right/Where I drag it |
| View | Show/Hide Ink · Fit All Ink · Home View |
| Files | Save… (⌘S in the menu) · Open Autosave Folder |
| App | Settings… · Export Diagnostic Report · Quit InkBridge |

### Floating toolbar

A non-activating panel: clicking it never takes focus from the annotated app. Every
size keeps the essentials (current tool, undo, ••• menu).

| Size | Contents |
|---|---|
| **Expanded** | status (transport, zoom %, RTT, ink latency) · Pen, Highlighter, Eraser, Laser · colour swatches · width slider · Undo, Redo, Clear · Fit all, Home · Hide ink · Save · ••• |
| **Compact** | status dot · tools · colour menu · Undo, Redo · Save · ••• |
| **Minimal** | status dot · tool menu · Undo · ••• |

The ••• menu holds Size, Position, plus whatever the current size leaves out (Redo,
Clear, Hide ink, Save…, Fit all, Home), highlighter opacity, Settings…, and **Hide
toolbar**.

**Position:**
- Bottom and Top centre the toolbar horizontally.
- Left and Right centre it vertically, and the toolbar **lays out vertically**.
- Dragging the toolbar switches to *Where I drag it* and remembers the spot.
- Docked positions follow the selected display's visible frame, so they stay clear of
  the menu bar and Dock.
- Size, position, the floating origin and visibility persist across restarts
  (UserDefaults).

**Hide:** the toolbar disappears completely. The overlay keeps drawing incoming strokes,
hot keys keep working, and the menu-bar icon brings it back.

### Keyboard (global, no Accessibility permission)

| Keys | Action |
|---|---|
| ⌃⌥P / H / E / L | Pen / Highlighter / Eraser / Laser |
| ⌃⌥Z · ⌃⌥⇧Z | Undo · Redo |
| ⌃⌥C | Clear canvas (undoable) |
| ⌃⌥F · ⌃⌥0 | Fit all ink · Home view |
| ⌃⌥O | Hide/show ink |
| ⌃⌥S | Save… |
| ⌃⌥T | Hide/show toolbar |

### Save…

1. **Screenshot first.** If "Include the screen behind the ink" is on and Screen
   Recording is granted, the selected display is captured *before* the dialog opens,
   excluding InkBridge's own windows.
2. **Native `NSSavePanel`:**
   - Default name `InkBridge 2026-10-31 at 15.42.10`, and the last-used folder is
     remembered.
   - **New Folder** is available.
   - The accessory view has the background toggle (it explains when the background is
     unavailable) and the full-page format: **PNG** (lossless) or **JPEG** (smaller).
3. **Overwrites** go through the panel's own "Replace?" confirmation. The write itself
   is atomic: a staging folder is swapped in, so a failure never leaves a half-written
   or damaged folder.
4. **Feedback:**
   - On success, an alert lists what was saved, with **Show in Finder**.
   - If the background was skipped, the alert says why, and when permission is the
     reason it offers **Open Privacy Settings**.
   - On failure, a critical alert reports it and states that nothing at the destination
     changed.

Output layout: see [session-management.md](session-management.md#export-folder).

## Tablet (Android)

### Top bar

`● Mac name · USB · 13 ms · 44 %` (status, transport, RTT, zoom when not 100 %), then
the buttons:

| Button | Action |
|---|---|
| Undo / Redo | `canvas.command` to the Mac. Needs a connection |
| Clear | Connected: the Mac clears (undoable there; saved sessions untouched). Offline: clears only this screen, with a notice, and the Mac's copy returns on reconnect |
| − / + | Zoom out/in ×1.5 around the centre |
| Fit | Fit all ink |
| Home | 100 %, aligned 1:1 with the Mac screen |
| Ink ✓/✗ | Show/hide ink on the tablet only. Strokes still go to the Mac |
| ⋮ | Reconnect · Connection settings… · Device & digitizer |

Below the bar, one monospace diagnostics line (refreshed at most once a second to
spare the e-ink): last sample, rate, pressure range, tools, buttons, dispatch lag.

### Canvas gestures

| Input | Effect |
|---|---|
| Pen (or eraser end) | Draws. Ink appears immediately and stays |
| One finger drag | Pan |
| Two-finger pinch | Zoom around the fingers' midpoint |

While a gesture runs, the canvas shows a cheap transformed preview (≤ 20 fps). On
lift, it redraws once at full quality and tells the Mac the new view.

### Ink appearance on e-ink

The tablet draws monochrome: pens black with pressure width, highlighter translucent
grey, eraser and laser as a thin grey trail that disappears when finished. Colours are
for the Mac. Yellow highlighter, for example, would be invisible on e-ink.
