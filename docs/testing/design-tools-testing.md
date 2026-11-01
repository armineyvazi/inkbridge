# Design tools testing

## Phase 1: dynamic backgrounds

| Requirement | Test | Result |
|---|---|---|
| Overlay → black → white → custom → overlay, strokes preserved, stroke cache untouched | `BackgroundTests.testSwitchingPreservesStrokesAndIsOneUndoStep` (Swift) | ✅ |
| Background is one undo step, interleaves with stroke undo | `testBackgroundAndStrokeUndoInterleave` | ✅ |
| Wire format + invalid mode rejected (shared fixture) | `testWireFormatRoundTrips`, `BackgroundTest.sharedFixtureDecodesAndRoundTrips` | ✅ |
| Save/restore background; old sessions load as overlay | `testSessionPersistsBackground`, `testOldSessionsWithoutBackgroundLoadAsOverlay` | ✅ |
| Transparent annotation export never contains the studio colour; composite does; background exported alone; PDF written | `testStudioExportKeepsLayersSeparate` (pixel checks) | ✅ |
| Overlay without a pattern writes no background image | `testOverlayExportWithoutPatternHasNoBackgroundImage` | ✅ |
| Stale revision ignored; tablet's optimistic choice replaced by a newer Mac answer | `BackgroundTest.hostRevisionsOnlyMoveForward`, `localChoiceIsShownAtOnceThenTheMacsAnswerWins` | ✅ |
| Strokes kept on the tablet across switches | `switchingBackgroundsKeepsStrokes` | ✅ |
| E-ink monochrome mapping keeps the real colour | `einkRenderingIsMonochromeButTheColourIsKept` | ✅ |
| Tablet panel: switch, strokes kept, zoom kept | `UiTest.backgroundPanelSwitchesInstantlyAndKeepsStrokesAndView` (Robolectric) | ✅ |
| Sync tablet → Mac and Mac → tablet, over TLS, across a reconnect | `scripts/e2e.sh wifi` (Kotlin simulator ↔ Swift probe) | ✅ request → revision 1; Mac push → revision 2, re-sent after reconnect |
| Same over USB | `scripts/e2e.sh` | ✅ |
| **On the BOOX hardware** | — | ⏳ The tablet was not on USB/adb during this phase. Install with `make -C apps/android install` |
| **Mac UI by hand** (toolbar panel, ⌃⌥B, studio covering a video, clicks caught) | — | ⏳ Needs a person (no screen-recording or accessibility permission for automation) |

Totals after Phase 1: 95 Swift, 63 Kotlin core and 12 Robolectric UI tests, all passing; Android lint clean.
