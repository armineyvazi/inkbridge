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
