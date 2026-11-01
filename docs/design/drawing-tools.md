# Drawing tools

| Tool | Status | Notes |
|---|---|---|
| Pen (colour, width, pressure) | Built (earlier); size on the tablet since v0.4 | Pressure curve set on the tablet (Off/Soft/Normal/Firm). Size in canvas px |
| Highlighter (colour, width, opacity) | Built (earlier) | Mac toolbar |
| Eraser (stroke eraser, size, undo) | Built (earlier) | Segment hit test in canvas px |
| Laser pointer (trail, fades) | Built (earlier) | Never saved |
| Pencil, marker, opacity per tool | Phase 2 | `tool.state` exists now; needs new stroke styles in both renderers |
| Line, arrow, shapes (rect, rounded rect, circle, ellipse, triangle, diamond, polygon) | Phase 2 | New object type `Shape` in the shared model |
| Pixel-style eraser | Phase 2 (investigate) | Must keep editable data: likely splits strokes rather than masking pixels |
| Text | Phase 4 | |

Since v0.4, tool selection and per-tool sizes are shared between the devices (`tool.state` / `tool.request`), and the tablet has its own controls: see `tablet-pen-controls.md` and ADR-008.
