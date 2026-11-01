# Engineering feature tests

| Test | Result |
|---|---|
| `EngineeringTests.testConnectorsAttachToFacingSidesAndFollowMovedNodes` (orthogonal segments, re-attachment after moves) | ✅ |
| `testConnectorsSharingASideGetSeparatePorts` | ✅ |
| `testCurvedAndStraightRoutes` | ✅ |
| `testDeletingANodeRemovesItsConnectors` (no dangling connectors) | ✅ |
| `testTemplatesAreEditableAndConsistent` (all 5 templates: references valid, unique IDs, no overlaps) | ✅ |
| `testAlignDistributeAndDuplicate` (connectors between duplicated nodes duplicated) | ✅ |
| `testComponentLibrarySearch` | ✅ |
| `testDiagramEditsAreUndoableAndSeparateFromInk` (a live drag is one undo step) | ✅ |
| `testDiagramPersistsWithTheSessionAndOnTheWire` (+ shared fixture) | ✅ |
| `testExportIncludesTheDiagram` (pixel check in the composite) | ✅ |
| Kotlin `DiagramTest` (shared fixture, mirror, stale revision, Persian and empty labels) | ✅ |
| Rendered with the real renderer (`InkBridge --render-template`): microservices, flowchart (dark), CQRS | ✅ visually reviewed; fixed: overlapping ports, busy grid, diamond ports |
| Real app → BOOX over Wi-Fi (`--demo-template microservices`) | ✅ rendered on e-ink |
| Real app save with diagram (normal and after `kill -9`) | ✅ |
| Mouse editing in the panel and canvas | ⏳ needs real clicks |
| Bug found: empty connector labels were rejected by the codec | fixed + covered |
