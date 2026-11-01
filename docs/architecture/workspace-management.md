# Workspace management

There are three workspace concepts, from cheapest to richest:

| Workspace | State | Status |
|---|---|---|
| Desktop Overlay | `CanvasBackground.mode = overlay` + `PointerMode` | Built |
| Studio Canvas | `mode = studio` + colour / paper | Built |
| Engineering Workspace | studio + a diagram object layer + component library | **Planned (P2–P3)**, see [../engineering/engineering-workspace.md](../engineering/engineering-workspace.md) |

The workspace is document state (background, synced, undoable). `PointerMode` is local UI state on the Mac, because a tablet has no Mac mouse. The window behaviour follows from both through `WindowInteraction`, never from scattered flags.
