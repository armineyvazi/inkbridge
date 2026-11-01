# Engineering Workspace: research and plan

**Status (2026-11-01): P2 foundation built and tested.** Remaining phases are below.

## Built (P2)

| Capability | Where | Verified |
|---|---|---|
| Diagram layer separate from ink and background: nodes + first-class connectors (references, not coordinates) | `InkBridgeCore/Engineering/Diagram.swift` | unit tests |
| Component library: 46 components in 8 categories (application, infrastructure incl. Docker/K8s, data incl. PostgreSQL/MySQL/MongoDB/Redis/Elasticsearch, messaging incl. Kafka/RabbitMQ, network, people & C4, flowchart, notes), searchable | `ComponentCatalog` | unit tests |
| Smart connectors: attach to facing sides, re-route when nodes move, **separate ports** when several share a side, straight/orthogonal/curved, 10 kinds (HTTP, gRPC, GraphQL, WebSocket, async, event, queue, database, data flow, dependency) with dashed/dotted conventions, labels, arrows | `ConnectorRouter`, `Diagram.path` | unit tests + rendered images |
| Templates (editable objects): Microservices, Event-driven, Three-tier, CQRS, Flowchart | `DiagramTemplate` | unit tests (consistent references, no overlaps) + rendered images |
| Editing on the Mac: select, ⇧-select, marquee, move (snap 10 px), resize handle, double-click rename, connect by dragging, inspector (label, details/columns, connector kind/route), align ×6, distribute ×2, duplicate, delete, nudge, ⌘A, V/C tools; every gesture one undo step | `InkCoordinator+Engineering`, `EngineeringPanel` | ⏳ by hand (needs real mouse) |
| Persistence (`diagram.json` per session), export (PNG/JPEG/PDF composite and transparent annotations, `annotations/diagram.json`) | `SessionArchive` | unit tests (pixel check) + real app save, crash recovery |
| Sync to the BOOX: `diagram.state` snapshot with routed paths; monochrome e-ink preview; Fit includes the diagram | protocol, `CanvasRenderer.drawDiagram` | **hardware: microservices template rendered on the Note Air over Wi-Fi** |

**Not yet:** editing diagrams on the tablet (preview only); obstacle-avoiding routing (a connector can cross a node); sequence-diagram builder; ER relationships with cardinality notation; SQL import/export; code blocks; Mermaid; auto-layout; handwriting → components.


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
| P2 ✅ | Diagram layer + selection/move/resize + component library (searchable, ~40 components) + smart connectors (straight/orthogonal) + alignment/snap + serialization + sync | Scenario A without templates: place services, DB, queue, LB; connect; move; connectors stay attached on both devices |
| P3 | Templates (microservices, event-driven, CQRS…), C4 levels, sequence builder, ER editor + table editor, flowchart shapes, network/infra components | Scenarios A and B |
| P4 | Code blocks (syntax highlighting), Mermaid render, SQL import/export, auto-layout, opt-in handwriting → components | Scenario C, B (SQL) |
