# Daily Journal & Quick Capture

> **v2 (2026-11-01, late):** redesigned panel and History, **hide without leaving** (📖 / ⌃⌥N cycle
> open → put away → back), handwriting previews, incremental saving. See *Redesign* below and
> `docs/performance/writing-latency.md`.

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

## Redesign (v2)

Reviewed against Apple Notes, Apple Journal, Goodnotes, Craft, Notion and Obsidian. What we took from them is interaction patterns, not looks:
- The page is the writing surface. The panel is a narrow companion, never a second editor.
- One date header with the day relative to today ("TODAY · SUNDAY"), and ‹ › to move between days.
- One timeline in writing order. Each entry has its time, a small rail dot by kind, and its content. Handwriting shows as a preview of the ink.
- Actions appear in context: on hover, in a right-click menu, or under ⋯. They don't take permanent space.
- A single composer at the bottom. Return adds the entry, and the Note/Task switch sits inside the field.
- A quiet save state: Saved, Saving…, Edited, or a red "Not saved" with the reason.

| Area | Mac | BOOX |
|---|---|---|
| Navigation | ‹ date › (click the date for a calendar), Today (⌘T), ⌘[ / ⌘], 🔍 History (⌘F), ⋯ menu | ‹ date › and "Go to today" |
| Entries | time column, previews of handwriting (click → the page pans to it), editable notes/tasks, hover delete | time column (monospace), ✎ / ☐ / ☑, last 30 |
| Capture | composer: note ↔ task, Return | Note/Task segmented + field + ✓; a typed draft survives updates |
| Hide | panel close button, **Hide**, 📖, ⌃⌥N | "Hide on Mac" / "Show on Mac"; leaving the canvas keeps the journal open and the dashboard shows **Continue writing** |
| Leave | **Done** (⌘Return), menu "Close Daily Journal (Back to Work)" | "Done — back to work" |
| History | sidebar: search, month (dots on days with entries), day list with counts; detail: the day's timeline with previews, **Open in Journal** | — (the Mac owns history) |

## Hide without leaving

- **Hiding:** puts away the canvas window and the panel. Nothing is unloaded. The day, ink, entries, view, tool, selection, panel scroll and a half-typed draft all stay in memory. A save starts but nothing waits for it. Autosave and tablet sync keep running, so the tablet can keep writing into the hidden journal and every stroke is saved.
- **Showing:** brings both windows back exactly as they were.
- **Protocol:** `journal.state` carries `hidden`, and `journal.request` accepts `hide` and `show`.
- **Verified on the real app** with the simulated tablet. Open, write, add a note, hide, write a stroke and a note while hidden, show, close. The day ends up with 2 strokes and 3 timestamped entries, and the work session is restored with its own title and strokes.

## Bugs found in real use and fixed

- **Work session renamed:** after closing the journal, the work session was renamed "Journal <day>". The title field commits when its panel hides, and the edit landed after close. Edits now require the journal to be open.
- **Wrong start times:** every session recorded the app's launch time as its start, and the journal day inherited the work session's. Each session now keeps its own start.
- **Lost draft on the tablet:** a half-typed note on the tablet was lost whenever new ink arrived. The field is now kept across updates (UI test).
