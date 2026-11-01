# Drawing tools

| Tool | Status | Notes |
|---|---|---|
| Pen (colour, width, pressure) | Built (earlier) | Pressure curve set on the tablet (Off/Soft/Normal/Firm) |
| Highlighter (colour, width, opacity) | Built (earlier) | Mac toolbar |
| Eraser (stroke eraser, size, undo) | Built (earlier) | Segment hit test in canvas px |
| Laser pointer (trail, fades) | Built (earlier) | Never saved |
| Pencil, marker, opacity per tool | Phase 2 | Needs `tool.state` sync and per-style opacity |
| Line, arrow, shapes (rect, rounded rect, circle, ellipse, triangle, diamond, polygon) | Phase 2 | New object type `Shape` in the shared model |
| Pixel-style eraser | Phase 2 (investigate) | Must keep editable data: likely splits strokes rather than masking pixels |
| Text | Phase 4 | |

Tool selection is not yet synced between the devices. That is the first item of Phase 2.
