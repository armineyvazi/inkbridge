# Daily Journal & Quick Capture

> **v2.1 (2026-11-03):** Hide / Esc / panel close / ⌃⌥N **leave** the journal and restore the
> previous workspace. Opening forces the canvas on-screen so BOOX ink is visible.
> History discovers days that only have `strokes.log`. See root-cause notes below.

One click (toolbar 📖, **⌃⌥N**, the menu bar, or 📖 on the BOOX canvas) opens today's page. Write, draw or type a note, then **Done** (or Esc / Hide / toggle) returns to exactly what was open before.

## How it works

| Requirement | Implementation |
|---|---|
| Restore the previous workspace exactly | Before opening, the open work is saved, then snapshotted **in memory**: strokes, background, diagram, the **undo/redo history**, session, project, title, view, tool, mouse mode and Engineering state (`StrokeStore.snapshot`). Done restores that snapshot; nothing is reloaded or re-created. If the open work can't be saved, the journal does not open. |
| One document per day | `<journal root>/YYYY/MM/YYYY-MM-DD/`: `journal.json` (title + entries), `session.json` + `strokes.json` / `strokes.log` (editable ink), `attachments/` |
| Same stroke store as Overlay | Journal loads the day into the shared `StrokeStore` / `OverlayView`. There is no separate journal renderer. |
| Canvas always visible while open | `ensureCanvasOnScreen()` clears "Hide ink", orders the overlay front, and invalidates the stroke cache on open / day switch / leave. |
| Calendar days, not 24 h | `JournalCalendar` uses the local calendar. A timer fires at the next local midnight, and `NSCalendarDayChanged` / time-zone changes are also handled. |
| Timestamps | UTC ISO-8601 with milliseconds in `journal.json`; shown in local time. Handwriting sessions group strokes within 2 minutes. |
| History | `JournalStore.days()` / `JournalIndex` include any day with `journal.json`, `strokes.json`, **or** `strokes.log`. |
| Saving | Ink via `StorageController` into the day folder (`journalDir`). Page writes coalesce on a background queue. |
| BOOX | Tablet panel asks with `journal.request`; Mac owns files. Handwriting is normal canvas ink while the Mac journal is active. |

## Leave vs put-away (v2.1)

v2 introduced **hide without leaving**: the canvas was ordered out while the day folder remained the save target. That caused:

1. BOOX writing updated the store and disk but **nothing appeared on the Mac**.
2. Users thought they had returned to their workspace; Esc / 📖 only put the journal away.

**v2.1:** Hide, Esc, panel close, ⌃⌥N toggle, and tablet **Done** all **leave** (`close()`): save the day, restore the in-memory workspace snapshot, show the canvas.

```mermaid
sequenceDiagram
  participant U as User
  participant J as JournalController
  participant S as StrokeStore
  participant W as Overlay window
  U->>J: open (⌃⌥N)
  J->>S: snapshot work; load day
  J->>W: ensureCanvasOnScreen
  U->>S: BOOX strokes (ingest)
  S->>W: strokeDidUpdate / draw
  U->>J: Done / Esc / Hide
  J->>S: restore snapshot
  J->>W: ensureCanvasOnScreen
```

## Root causes fixed (2026-11-03)

| Symptom | Cause | Fix |
|---|---|---|
| BOOX ink not on Mac | Canvas ordered out (Hide ink or put-away) while journal still active | Force canvas on open; leave on Hide/Esc |
| Cannot return to workspace | Toggle cycle open→hide→show never called `close()` | Toggle / Hide / Esc call `close()` |
| History missing recent days | `days()` ignored `strokes.log`-only folders | `hasContent` includes the log |
| Blank day after reopen | `try? SessionArchive.load` swallowed errors; incremental `persisted` not seeded from day | Surface load errors; `enterJournal(dir:)` after `startSession` |

## Not built

- Backup settings and per-day export.
- Images / attachments UI.
- Rich typed text on the canvas.
- Offline journal ownership on the tablet.
