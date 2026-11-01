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
