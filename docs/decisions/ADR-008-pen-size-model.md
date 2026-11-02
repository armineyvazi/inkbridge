# ADR-008: Pen size model: per-tool preferences in canvas px, Mac as source of truth

- **Status:** accepted (v0.4, 2026-11-02)
- **Related:** ADR-006 (infinite canvas, canvas px), `docs/design/tablet-pen-controls.md`, protocol §3 *Tool settings*

## Context

Until v0.4 the tool and its width could only be changed on the Mac toolbar. Widths were
**Mac screen points**, converted to canvas px when a stroke began (`width / mapper.scale`).
`mapper.scale` depends on the viewport zoom **and on which Mac display shows the overlay**.
Measured on 2026-11-02: the Mac's "3 pt" pen stored strokes **5.72 canvas px** wide on the
current display. The same setting gives a different page thickness on a laptop screen, an
external monitor, or another zoom level. The tablet drew a fixed placeholder (black, 2.5 px)
until the Mac's `stroke.style` arrived. Sizes were not persisted.

## Problem

1. Let the writer change size quickly on the BOOX itself, per tool.
2. Give every size a meaning that doesn't depend on device, display or zoom.
3. Keep preferences separate from document data: changing a size must never restyle existing strokes.
4. Keep the two devices consistent, online and offline, with a defined conflict rule.

## Alternatives considered

| Option | Why not |
|---|---|
| Keep screen points (screen-constant width) | Same setting → different page thickness per display and zoom (measured 5.72 px for "3 pt"). The tablet and Mac would disagree about what "3" means. |
| Physical units (mm / pt at 72 dpi) | Needs a per-device DPI in the document model. Canvas px are already defined as tablet px at 100 % (ADR-006); the Note Air 2 Plus and Note Air 3 share the same 1404×1872 / 227 ppi grid. |
| Tablet owns the settings, sends `style` with each stroke | Two writers for stroke style. The Mac already resolves every stroke (colour, highlighter opacity, laser). Mac toolbar changes would need the reverse path anyway. |
| Store the size in the document/session | Sizes would change when switching sessions/journal days, and a preference would end up in user files. |
| Timestamp-based last-writer-wins | Needs synchronised wall clocks. Arrival order at a single owner gives the same result without them. |

## Decision

- **Unit:** sizes are **canvas px**, the document unit (1 = one tablet pixel at 100 % zoom).
  Pen and highlighter: line width at full pressure. Eraser: radius. Renderers convert at the
  boundary: `× zoom` on the tablet, `× mapper.scale` on the Mac. Strokes copy the width at
  `stroke.begin`.
- **Model:** `ToolSettings {tool, pen, highlighter, eraser}`, in both cores (Swift `InkBridgeCore/Drawing/ToolSettings.swift`, Kotlin
  `core/canvas/ToolSettings.kt`). Limits, defaults, XS–XL presets and the − / + step rule live in
  `protocol/fixtures/tool-sizes.json`. Both test suites assert their code matches it.
- **Source of truth:** the Mac (UserDefaults keys `tool`, `sizePen`, `sizeHighlighter`, `sizeEraser`).
  The tablet caches the last agreed state in SharedPreferences for startup and offline use.
- **Sync:** `tool.request` (device → host: `seq`, optional `tool`, partial `sizes`) and `tool.state`
  (host → device: full settings, `revision`, `ack`). The Mac applies requests in arrival order and
  broadcasts every change, coalesced to one message per run-loop turn.
- **Conflicts:** last change to reach the Mac wins, per field (requests carry only what changed).
  The tablet is optimistic. It skips states whose `ack` is lower than its latest `seq` (replies to
  superseded slider steps). On every new connection it re-baselines (`ToolSync.connected`):
  - everything acknowledged → adopt the Mac's state;
  - an unacknowledged edit (offline, or lost on a dead link) → re-send only the dirty
    fields, so a tablet pen change never overwrites a Mac highlighter change.
- `tool.request` is in the device's resend log, so a size change always reaches the Mac before
  the strokes drawn after it on the same ordered stream.

## Consequences

- One size means the same page thickness everywhere. Zooming in makes new ink look thicker on screen,
  as on paper under a magnifier. The size panel says "Preview at N % zoom".
- The Mac toolbar slider now shows canvas px (pen 0.5–24, highlighter 6–96, eraser radius 4–160).
  The default pen is 4 px (≈ 0.45 mm on a 227 ppi BOOX).
- Old strokes keep their stored widths; nothing is migrated (sizes were never persisted before).
- Laser width became 8 canvas px (was 5 screen pt).
- The tablet's first local ink now has the right tool and width immediately (previously 2.5 px black).

## Validation

- Shared-fixture tests (limits, presets, 9 step vectors) on both platforms; clamp, per-tool memory, wire round-trip, ToolSync ordering, reconnect re-baseline (dirty fields only).
- UI test: tool buttons, − / +, next stroke uses the new size, earlier stroke unchanged, persisted.
- Eraser `stroke.style` carries the radius (`valid/stroke.style.eraser.json`); width 0 is rejected.
- Hardware (Note Air 2 Plus + Mac, 2026-11-02):
  - widths 4 / 5.5 / 11 drew 4 / 6 / 12 px at 100 %, and 11 drew 16 px at 150 %;
  - the Mac stored 11 for both;
  - Mac → tablet after a Mac restart; offline tablet edit won after reconnect;
  - preset and slider reached the Mac.
