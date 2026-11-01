# Regression tests added in this iteration

| Bug | Test |
|---|---|
| Studio followed clicks onto other monitors | `InteractionTests.testStudioCatchesTheMouseAndNeverFollows` |
| Fit zoomed to 1138 % on small drawings (found on hardware) | `CanvasTest.fitNeverMagnifiesPastActualSize`, `InteractionTests.testFitNeverMagnifiesPastActualSize` |
| Tablet dropped the Mac's resync unless the canvas was open | `UiTest.hostDocumentIsMirroredEvenWhenTheCanvasWasNeverOpened` |
| Dots invisible on black | `BackgroundPatternTests.testDotsAreVisibleOnBlack` |
| Empty session folders after relaunch | Verified on the real app; `isPristine` guard |
| "Changes not saved yet" on an untouched session | New `empty` status on both sides (fixture validation) |
| Toolbar drift | Measured on the owner's Mac |
| Inspector label typing: one undo step per keystroke | `EngineeringTests.testTypingALabelIsOneUndoStep` |
| Esc in Engineering with nothing selected left an inconsistent state | Esc now leaves Engineering |
| Tablet strokes never marked as sent (ink survived document switches) — found on hardware | `UiTest.sentStrokesLeaveTheTabletWhenTheMacSwitchesDocuments` |
| Canvas screen dropped journal/storage messages — found on hardware | `UiTest.journalAndStorageUpdatesArriveWhileTheCanvasIsOpen` |
| Journal timestamps lost milliseconds on save | `JournalTests.testDaysAreIndependentAndSearchable` / ms storage |
| Crash recovery pointed at a closed journal | Verified on the real app |
| Empty connector labels rejected by the codec | `EngineeringTests.testDiagramPersistsWithTheSessionAndOnTheWire` |
| Journal title field committed after close and renamed the work session (real use) | guarded edits; verified with `--journal-hide` run |
| Every session recorded the app launch time as its start | verified on disk (journal 18:26:08 vs work 18:26:00) |
| Tablet journal draft lost when new ink arrived | `UiTest.journalSheetShowsPutAwayStateAndKeepsATypedNoteAcrossUpdates` |
| Journal page save blocked the main thread ~80 ms per stroke | `JournalPerformanceTests.testPersistenceCost` (now 1.3 ms, background) |
| Tablet ignored the Mac's tool settings forever after a Mac restart (found on hardware, v0.4) | `ToolSettingsTest.macRestartIsAdoptedAfterReconnect`; verified on hardware |
| Offline tablet size change lost on reconnect | `ToolSettingsTest.unacknowledgedEditIsResentInFullOnReconnect`; verified on hardware (8 → 10 while the Mac was quit) |
| Same Mac pen setting stored a different width per display/zoom (3 pt → 5.72 px) | `ToolSettingsTests.testChangingSizeDoesNotRestyleExistingStrokes` + unit change (ADR-008) |
| Perf log fired on every frame after 2 000 frames | separate frame counter in `CanvasRenderer.logPerf` |
| Notched edges on thick tablet strokes (overlapping caps) — found on hardware | `InkPainter` draws equal-width runs as one Path; verified on hardware screenshots |
