# ADR-005: Session storage: a folder per session with JSON strokes now; SQLite index later

- Status: accepted (JSON part implemented)
- Date: 2026-10-31

## Context

The brief recommends SQLite for metadata and asks whether JSON is good enough for
strokes.

## Decision

- **Now:** one folder per session: `session.json` (metadata), `strokes.json`
  (vector strokes, normalized coordinates), `preview.png`, `export.pdf`, and an
  optional `background.png`. Autosave writes only the JSON, atomically
  (`Data.write(options: .atomic)`).
- **When the Session History UI lands (Phase 4):** add a SQLite index
  (`sessions(id, title, started_at, saved_at, device, stroke_count, folder)`) for
  listing and search. The folders stay the source of truth, and the index can be
  rebuilt from them.
- **If sessions grow large:** move `strokes.json` to a compact binary format. The
  estimate is 5–8× smaller (float16 deltas, or fixed 16-byte points versus ~40 bytes
  of JSON per point).

## Consequences

- Sessions are inspectable and diffable, and can be exported by copying a folder.
- Rewriting the whole `strokes.json` every 5 s is O(session size). At the estimated
  2–3 MB per dense hour that is fine. An append-only log would remove the cost if it
  ever matters.
