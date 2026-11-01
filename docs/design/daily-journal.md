# Daily Journal & Quick Capture

One click (toolbar 📖, **⌃⌥N**, the menu bar, or 📖 on the BOOX canvas) opens today's page. Write, draw or type a note, then **Done** returns to exactly what was open before.

## How it works

| Requirement | Implementation |
|---|---|
| Restore the previous workspace exactly | Before opening, the open work is saved, then snapshotted **in memory**: strokes, background, diagram, the **undo/redo history**, session, project, title, view, tool, mouse mode and Engineering state (`StrokeStore.snapshot`). Done restores that snapshot; nothing is reloaded or re-created. If the open work can't be saved, the journal does not open. |
| One document per day | `<journal root>/YYYY/MM/YYYY-MM-DD/`: `journal.json` (title + entries), `session.json` + `strokes.json` (editable ink), `attachments/` |
| Calendar days, not 24 h | `JournalCalendar` uses the local calendar. A timer fires at the next local midnight, and `NSCalendarDayChanged` / time-zone changes are also handled. An open "today" moves to the new day; a deliberately opened older day stays; previous days are never touched. On launch the date is computed fresh |
| Timestamps | Every note, task and handwriting session has `createdAt` and `modifiedAt`, stored as **UTC ISO-8601 with milliseconds** and shown in local time. Handwriting is grouped into capture sessions: strokes within 2 minutes of the session's last stroke join it (09:15 → 09:22 is one entry). Erasing or undoing strokes removes them from their entry; timestamps stay with the original content. "Times on page" toggles the HH:mm labels on the canvas |
| History | Journal History window: month calendar (days with content are bold and shaded, today is outlined), the selected day's entries, search across all days, and Open-and-edit any day |
| Saving | Ink autosaves through the normal storage path (atomic; "Saved" only after the files are on disk). The page (`journal.json`) is written atomically on every change. Crash recovery reopens the journal day if it was open |
| Separate storage | Default `~/Documents/InkBridge Journal`, chosen on first use (Use This Folder / Choose…). Projects & Storage → Daily Journal shows the folder, Change… (never moves or deletes; optionally copies existing days), Show in Finder, and usage |
| BOOX | 📖 opens a panel: Open today, ◀ ▶ days, Go to today, entries with local times, Add note / Add task (keyboard), Close journal. While open, a header shows "Daily Journal · date · Today". The Mac owns the journal: the tablet asks with `journal.request` and shows `journal.state`. Offline it says so, and ink is kept and sent on reconnect |

## Not built

- **Backup settings and per-day export.** Save… exports the open day like any session, but there is no dedicated "export journal" yet.
- **Images and attachments.** The folder exists; there is no UI yet.
- **Rich typed text on the canvas.** Typed notes live in the panel list, not on the page.
- **An offline journal on the tablet.** Offline ink goes to whatever document the Mac has open when the tablet reconnects.
- **Simultaneous edits** are resolved by the Mac applying requests in arrival order.
