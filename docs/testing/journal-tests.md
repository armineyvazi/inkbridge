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
