# Engineering Workspace: research and plan

**Status: planned. Nothing here is built yet.** The "Engineering" paper pattern is only a background, as you pointed out.

## What the best tools do, and what is worth adopting

| Tool | Worth adopting | Why it matters here |
|---|---|---|
| Excalidraw / tldraw | Hand-drawn feel; **bindings**: arrows bound to shapes, re-routed on move; quick shape keys; JSON scene format | Fits pen input; bindings are the core of "smart connectors" |
| draw.io / Lucidchart | Orthogonal routing with ports; large shape libraries (AWS/K8s/network) | Architecture diagrams need clean orthogonal edges and recognisable components |
| FigJam / Miro | Sticky notes, stamps, templates, sections | Lightweight thinking tools; templates speed up common architectures |
| Eraser | **Diagram-as-code** next to the canvas, with icon libraries | Engineers like text; round-tripping text ⇄ diagram |
| Mermaid / PlantUML | Text-defined sequence, ER, class and state diagrams | Sequence and ER are tedious to draw by hand and natural as text |
| C4 model | System context → container → component zoom levels | Gives architecture diagrams structure, not just boxes |

**Out of scope for now:** real-time multi-user collaboration, cloud sync, and AI features without clear value. Handwriting → structure stays opt-in and non-destructive.

## Architecture (fits the shared drawing model)

```text
Document
├── Background layer                      (built)
├── Ink layer: strokes                    (built)
└── Diagram layer                         (P2)
    ├── Node {id, kind (component id), frame, label, properties{}, style}
    ├── Connector {id, from: NodeRef+anchor, to: NodeRef+anchor, route: straight|orthogonal|curved,
    │              kind: http|async|db|queue|dataflow|dependency, label, arrowheads}
    ├── Table {id, name, columns[{name, type, pk, fk→Table.col, unique, nullable}]}   (P3: ER)
    ├── Sequence {participants[], messages[{from, to, kind sync|async|reply, label, order}]}  (P3)
    └── CodeBlock / MermaidBlock {source, language, rendered cache}  (P4)
```

- **Connectors are first-class:** they store node references, not coordinates. A route is computed (pure function `route(fromFrame, toFrame, style) → path`), so moving a node re-routes. The route is shared Swift ⇄ Kotlin with fixtures, so both devices draw identical paths.
- **Sync:** `object.add / object.update / object.remove` with per-object revisions (designed in [../protocol/drawing-state-events.md](../protocol/drawing-state-events.md)). The Mac stays the single writer.
- **Rendering:** the Mac draws the full design; the BOOX draws a monochrome preview (labels, outlines, routes), icons as simple glyphs.
- **SQL:** a CREATE TABLE subset parser (tables, columns, types, PK, FK, UNIQUE, NOT NULL) with line/column error messages. Export generates DDL. Nothing is executed.
- **Mermaid:** rendering needs Mermaid's JS. On the Mac, an offline `WKWebView` with a bundled, pinned `mermaid.min.js` (MIT) renders to SVG, and the source stays editable. On the BOOX the rendered image is shown. PlantUML needs Java plus Graphviz, so only an investigation is planned.

## Delivery order and acceptance

| Phase | Deliverable | Acceptance |
|---|---|---|
| P2 | Diagram layer + selection/move/resize + component library (searchable, ~40 components) + smart connectors (straight/orthogonal) + alignment/snap + serialization + sync | Scenario A without templates: place services, DB, queue, LB; connect; move; connectors stay attached on both devices |
| P3 | Templates (microservices, event-driven, CQRS…), C4 levels, sequence builder, ER editor + table editor, flowchart shapes, network/infra components | Scenarios A and B |
| P4 | Code blocks (syntax highlighting), Mermaid render, SQL import/export, auto-layout, opt-in handwriting → components | Scenario C, B (SQL) |
