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
