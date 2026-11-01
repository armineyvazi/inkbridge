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

| Dots visible on black (regression: too faint on non-Retina HDMI monitors) | `BackgroundPatternTests.testDotsAreVisibleOnBlack`; pattern contrast raised | ✅ |
| Tablet mirrors the Mac's resync while the canvas screen is closed (regression) | `UiTest.hostDocumentIsMirroredEvenWhenTheCanvasWasNeverOpened` | ✅ |
| Toolbar stays centred (regression) | Measured on the owner's Mac: centre 756 = screen centre 756 | ✅ |
| Multi-display follow / pin | Logic checked against the owner's 3 displays (built-in + 2× MSI MD271P) | ⏳ by hand: needs real clicks |

Totals after Phase 1: 96 Swift, 63 Kotlin core and 13 Robolectric UI tests, all passing; Android lint clean.
