# BOOX drawing experience

Built through Phase 1:

- **Layout:**
  - Full-screen canvas.
  - Status pill moved to **bottom left** (back + connection stage), so the top edge holds only tools.
  - Top-right bar: undo, redo, −, zoom %, +, fit, **background**, ⋮. It hides completely through ⋮ → Hide controls, leaving one round button.
- **Background panel:** a single bordered panel with every option visible: mode, four presets (plus "Custom" if set on the Mac), and paper. Choices show immediately, before the Mac confirms.
- **E-ink rules:**
  - A background change is one full redraw.
  - Black ⇄ white adds one clean flash.
  - Pattern lines are skipped when denser than 8 px.
  - Ink colour flips to white on dark paper.
  - Writing stays incremental.

Planned:

| Phase | Additions |
|---|---|
| 2 | Tool strip with pen/pencil/highlighter/marker/eraser/laser/line/arrow/shapes, quick colour presets (shown as greys plus names), size steps |
| 3 | Select / lasso |
| 4 | Layer picker |

The tablet UI will not copy the Mac toolbar: it keeps one compact strip plus expandable panels.
