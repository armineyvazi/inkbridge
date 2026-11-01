# Daily Journal tests

| Scenario | How | Result |
|---|---|---|
| Crossing local midnight | `JournalTests.testCrossingLocalMidnightChangesTheDay` (Tehran 23:59:30 → 00:00) | ✅ |
| Calendar day, not 24 h (DST) | `testDaylightSavingDayIsNotTwentyFourHours` (New York 2026-11-01 = 25 h) | ✅ |
| Time-zone change | `testTimeZoneChangeUsesTheNewLocalDate` | ✅ |
| Day navigation and validation (path-safe ids) | `testDayNavigationAndValidation` | ✅ |
| Timestamps survive save/reopen; UTC stored; created ≠ modified | `testTimestampsSurviveSaveAndReload` | ✅ (found and fixed: whole-second storage lost milliseconds) |
| Handwriting sessions, erase keeps original time | `testHandwritingIsGroupedIntoTimestampedSessions` | ✅ |
| Days independent, searchable, usage | `testDaysAreIndependentAndSearchable` | ✅ |
| Exact workspace restore incl. undo/redo | `testSnapshotRestoresTheWorkspaceExactly` | ✅ |
| Protocol fixtures (Swift + Kotlin), invalid action rejected | `ProtocolTests`, `DiagramTest.journalMessagesUseTheSharedFixtures` | ✅ |
| Tablet panel offline / header shows open day | `UiTest.journalPanelExplainsOfflineAndHeaderShowsTheOpenDay` | ✅ |
| Journal updates arrive while the canvas is open | `UiTest.journalAndStorageUpdatesArriveWhileTheCanvasIsOpen` | ✅ (bug found on hardware) |
| Real app, simulated tablet: draw 2 in work → open journal → stroke + note → close | simulator `--journal-flow` | ✅ work kept 2 strokes; journal day got its stroke + ink entry + note with ms UTC timestamps; recovery points back at the work (bug found and fixed) |
| Crash inside the journal (`kill -9`) | real app | ✅ reopened the journal day with every entry |
| **BOOX hardware** over Wi-Fi: work → open journal from the tablet → handwriting + keyboard note → close | adb-driven | ✅ note saved with timestamp; Mac restored the work session; **before/after screens byte-identical** |
| Real midnight while open | — | ⏳ logic unit-tested; not run across a real midnight |
| Mac journal panel and history window by hand | — | ⏳ needs real clicks |

## v2: redesign, hide/show, performance

| Scenario | How | Result |
|---|---|---|
| Hide → write while hidden → show → close (real app, simulated tablet) | simulator `--journal-flow --journal-hide` | ✅ saving continued while hidden (`saving → saved` in the day folder); 2 strokes + 3 entries; work restored with its own title |
| Journal start time is its own; work title not leaked | same run, files on disk | ✅ (both bugs found in real use) |
| Typed draft survives journal updates; put-away banner; Show on Mac sends `show` | `UiTest.journalSheetShowsPutAwayStateAndKeepsATypedNoteAcrossUpdates` | ✅ |
| Dashboard journal card only when open and connected | `UiTest.dashboardJournalCardOnlyWhileTheJournalIsOpenAndConnected` | ✅ |
| `hidden` optional on the wire, `hide`/`show` valid (both platforms) | `JournalProtocolTests`, `JournalProtocolTest` | ✅ |
| Incremental save: append/full decision, reload order, no duplicates, torn line, compaction | `IncrementalSaveTests` (3) | ✅ |
| History over 400 days | `JournalPerformanceTests.testHistoryWithHundredsOfDays` | ✅ index once (283 ms, background), search 2.4 ms per keystroke vs 273 ms re-reading disk |
| Culled stroke rendering is pixel-identical | `testCulledStrokeIsPixelIdenticalInTheDirtyRect` | ✅ |
| Handwriting previews | `JournalIndexTests.testThumbnailDrawsInkAndIsEmptyForNoInk` | ✅ |
| Panel design review (light/dark, empty state) | `InkBridge --render-journal DIR [--dark]` | ✅ reviewed; fixed wrapped times and preview sizing |
| Tablet sheet design review | `make -C apps/android screenshots` → `7-journal.png` | ✅ reviewed; removed a duplicate button |
| **BOOX:** latency, online vs Wi-Fi off | on-device recorders | ✅ identical (30.3 vs 29.7 ms p50) |
| **BOOX:** lock-then-drain A/B | `inkrun.sh 1` vs `0`, 2 rounds | ✅ p50 48.3 → 28.2 ms, p95 60 → 40 ms; ink complete |
| **BOOX:** redesigned journal sheet on hardware, Done from the tablet | adb | ✅ renders as designed; Done closed the Mac journal and returned to the work session |
| Mac panel/history by real clicks | — | ⏳ no Accessibility permission here |
