# InkBridge documentation

| | |
|---|---|
| **Start here** | [System overview](architecture/system-overview.md) · [Setup](implementation/setup.md) · [Roadmap](implementation/roadmap.md) · [Contributing](../CONTRIBUTING.md) |
| **Research (Phase 0)** | [Hardware feasibility](research/hardware-feasibility.md) · [BOOX SDK](research/boox-sdk-analysis.md) · [USB](research/usb-research.md) · [Wi-Fi](research/wifi-research.md) |
| **Architecture** | [UI specification](architecture/ui-specification.md) · [Android](architecture/android-architecture.md) · [macOS](architecture/macos-architecture.md) · [Screen lifecycle](architecture/screen-lifecycle.md) · [Transport](architecture/transport-architecture.md) · [Drawing engine](architecture/drawing-engine.md) · [Coordinate mapping](architecture/coordinate-mapping.md) · [Sessions](architecture/session-management.md) · [Security](architecture/security.md) · [AI (proposed)](architecture/ai/README.md) |
| **Protocol** | [Specification](protocol/protocol-specification.md) · [Examples](protocol/message-examples.md) · fixtures in [`/protocol/fixtures`](../protocol/fixtures) |
| **Decisions** | [001](decisions/ADR-001-native-architecture.md) · [002](decisions/ADR-002-usb-transport.md) · [003](decisions/ADR-003-wifi-transport.md) · [004](decisions/ADR-004-drawing-engine.md) · [005](decisions/ADR-005-storage.md) · [006](decisions/ADR-006-infinite-canvas-and-sync.md) · [007](decisions/ADR-007-tls-pairing.md) · [008](decisions/ADR-008-pen-size-model.md) · [009](decisions/ADR-009-writing-pipeline.md) · [010](decisions/ADR-010-workspace-state-machine.md) · [011 AI providers](decisions/ADR-011-ai-provider-agnostic.md) · [012 AI credentials](decisions/ADR-012-secure-ai-credentials.md) · [013 document layers](decisions/ADR-013-three-layer-document.md) |
| **Pen & latency** | [Tablet pen controls](design/tablet-pen-controls.md) · [Writing latency](performance/writing-latency.md) · [Pen size tests](testing/pen-size-tests.md) |
| **Development** | [Code style](development/code-style.md) |
| **Release** | [v0.1.0 notes](release-notes/v0.1.0.md) · [CHANGELOG](../CHANGELOG.md) |
| **Diagrams** (Mermaid) | [System architecture](diagrams/system-architecture.mmd) · [Data flow](diagrams/data-flow.mmd) · [Connection flow](diagrams/connection-flow.mmd) · [Session lifecycle](diagrams/session-lifecycle.mmd) · [Document sync](diagrams/document-sync.mmd) |
| **Operating** | [Testing](implementation/testing.md) · [Troubleshooting](implementation/troubleshooting.md) |

Rule for these docs: describe what is **built**, and mark everything else
*pending*, *planned* or *not implemented*. Hardware claims carry one of three labels:
**Verified (hardware)**, **Verified (sourced)**, or **Pending**.

## Documentation sources

| Location | Role |
|----------|------|
| **This `docs/` tree (GitHub)** | Authoritative for contributors: architecture, protocol, ADRs, setup, release notes |
| **Maintainer Obsidian vault** | Extended engineering journal, hardware run logs, personal status — not required to build |

When behaviour or a public API changes, update GitHub `docs/` (and ADRs) in the same PR.
Mirror important ADRs into Obsidian if the maintainer vault tracks them, but **never** let Obsidian diverge as the only source of truth for something a contributor needs.
