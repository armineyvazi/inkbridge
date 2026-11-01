# Storage architecture

```text
Storage (Mac is authoritative)                     Tablet
├── StorageConfig (UserDefaults)                   ├── mirror of storage.state (display only)
│   rootPath · exportsPath? · activeProject        ├── local cache: CanvasDocument
│   recentRoots                                    └── pending: strokes not yet sent (unsentCount)
├── ProjectStore(root)                                   + outbox / sent log (InkBridgeClient)
│   Projects/<name>/project.json
│   Projects/<name>/sessions/<id>/{session,strokes}.json
│   Projects/<name>/exports/
└── StorageController (app): active session, async autosave, status, requests
```

| Rule | How |
|---|---|
| The Mac owns the files | The tablet never sees or sends a raw Mac path. It receives display strings (`~/Documents/…`) and asks with `storage.request`; the Mac validates and answers with `storage.state` |
| Saving never blocks drawing | Snapshot on the main thread (value types), write on a utility queue. Saves are coalesced (`saveAgain`) |
| "Saved" means on disk | `saved(Date)` is set only after both files were written atomically (temp + rename). A failure becomes `failed(reason)` with an actionable message (permissions, disk full, missing folder) |
| Nothing at risk is shown honestly | New untouched sessions are `empty` and create no folder |
| Crash recovery | The last saved project and session id are recorded after each successful save; a launch after an unclean exit reopens that session |
| No silent moves | Changing location asks: *Move projects* / *Leave them here* / Cancel. Migration never overwrites (" (moved)" suffix) |
| Delete is recoverable | Projects go to the Trash |
| Old data is kept | v1 autosaves (`~/Library/Application Support/InkBridge/Sessions`) are **copied** once into the project "Imported Sessions" |
| Export ≠ project storage | `exportsPath` is separate. Save… opens there, or in the project's `exports/` |

## Protocol (additive in v3)

- `storage.state` (H→D): `project`, `session`, `location`, `status` (empty / saved / saving / unsaved / failed), `saved_at_ms`, `error?`, `projects[]`, `locations[]`, `revision`.
- `storage.request` (D→H): `action` ∈ {save_now, new_session, switch_project, create_project, use_location}, plus `name?`. Unknown actions are rejected at decode time.
- Fixtures: `valid/storage.state.json`, `valid/storage.request.json`, `invalid/bad-storage-action.json`.
