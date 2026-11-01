# Storage tests

| Test | How | Result |
|---|---|---|
| Create / rename / duplicate / delete (Trash) / search projects; rename and search sessions; recent sessions | `StorageTests.testProjectLifecycle` | ✅ |
| Path tricks rejected (`../etc`, `.hidden`, `/`, `:`) | same | ✅ |
| Move projects to a new root without overwriting | `testMigrationMovesProjectsWithoutOverwriting` | ✅ |
| Invalid (file) and read-only destinations → useful messages | `testInvalidAndReadOnlyDestinationsAreRejectedWithUsefulMessages` | ✅ |
| Disk full → actionable message | `testDiskFullMapsToAnActionableMessage` | ✅ (mapped from the real error codes; a real full disk was not filled) |
| Interrupted save leaves the last good version | `testInterruptedSaveLeavesTheLastGoodVersionLoadable` | ✅ |
| Autosave in the live app: unsaved → saving → saved, files on disk | Simulator against the real app over USB | ✅ 3 strokes on disk |
| Crash during a session (`kill -9`) → relaunch reopens it and keeps saving | Real app | ✅ 3 + 2 = 5 strokes in the same session |
| No empty session folders | Real app relaunch | ✅ (bug found and fixed) |
| Tablet create_project → Mac creates, switches, broadcasts | Simulator ↔ real app | ✅ |
| Tablet switch project (hardware) | BOOX ↔ real app over Wi-Fi | ✅ Mac config `activeProject` = "My Drawings" |
| Wi-Fi drop mid-session (hardware) | BOOX: 2 strokes, Wi-Fi off, 2 strokes, on | ✅ 4 strokes saved, unique, reconnect 280 ms |
| Tablet storage screen offline / never claims "Saved" offline | `UiTest.storageScreenShowsMacLocationAndRefusesChangesWhileOffline` | ✅ |
| Change location with the GUI picker + migrate prompt | — | ⏳ manual (no UI automation permission) |
| use_location from the tablet | Unit path only; needs ≥ 2 known roots | ⏳ |
