# InkBridge documentation

| | |
|---|---|
| **Start here** | [System overview](architecture/system-overview.md) · [Setup](implementation/setup.md) · [Roadmap](implementation/roadmap.md) |
| **Research (Phase 0)** | [Hardware feasibility](research/hardware-feasibility.md) · [BOOX SDK](research/boox-sdk-analysis.md) · [USB](research/usb-research.md) · [Wi-Fi](research/wifi-research.md) |
| **Architecture** | [UI specification](architecture/ui-specification.md) · [Android](architecture/android-architecture.md) · [macOS](architecture/macos-architecture.md) · [Transport](architecture/transport-architecture.md) · [Drawing engine](architecture/drawing-engine.md) · [Coordinate mapping](architecture/coordinate-mapping.md) · [Sessions](architecture/session-management.md) · [Security](architecture/security.md) |
| **Protocol** | [Specification](protocol/protocol-specification.md) · [Examples](protocol/message-examples.md) · fixtures in [`/protocol/fixtures`](../protocol/fixtures) |
| **Decisions** | [001 Native + stroke events](decisions/ADR-001-native-architecture.md) · [002 USB](decisions/ADR-002-usb-transport.md) · [003 Wi-Fi](decisions/ADR-003-wifi-transport.md) · [004 Rendering](decisions/ADR-004-drawing-engine.md) · [005 Storage](decisions/ADR-005-storage.md) · [006 Infinite canvas + sync](decisions/ADR-006-infinite-canvas-and-sync.md) · [007 TLS pairing](decisions/ADR-007-tls-pairing.md) · [008 Pen size model](decisions/ADR-008-pen-size-model.md) · [009 Writing pipeline](decisions/ADR-009-writing-pipeline.md) |
| **Pen & latency (v0.4)** | [Tablet pen controls](design/tablet-pen-controls.md) · [Writing latency](performance/writing-latency.md) · [Pen size tests](testing/pen-size-tests.md) |
| **Diagrams** (Mermaid) | [System architecture](diagrams/system-architecture.mmd) · [Data flow](diagrams/data-flow.mmd) · [Connection flow](diagrams/connection-flow.mmd) · [Session lifecycle](diagrams/session-lifecycle.mmd) · [Document sync](diagrams/document-sync.mmd) |
| **Operating** | [Testing](implementation/testing.md) · [Troubleshooting](implementation/troubleshooting.md) |

Rule for these docs: describe what is **built**, and mark everything else
*pending*, *planned* or *not implemented*. Hardware claims carry one of three labels:
**Verified (hardware)**, **Verified (sourced)**, or **Pending**.
