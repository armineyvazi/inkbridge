# Roadmap

✅ done and tested · 🟡 implemented, hardware verification pending · ⬜ not started

## Phase 0: feasibility

| Deliverable | Status |
|-------------|--------|
| Environment inspection | ✅ |
| USB descriptor and AOA capability probe (`tools/aoa-probe`) | ✅ AOA v2 confirmed |
| BOOX SDK compatibility analysis | ✅ desk research; on-device decision pending stylus tests |
| Stylus diagnostic app (x, y, pressure, tool, rate, timestamp, buttons, tilt, hover, dispatch lag, input-device dump) | ✅ |
| USB and Wi-Fi research | ✅ |
| Feasibility report | ✅ (Wi-Fi-from-tablet rows pending) |

**Exit criteria (met 2026-10-31 on a Note Air 2 Plus):** stylus events received ✅ ·
pressure verified ✅ (0–4095, 360 Hz) · working development connection ✅ (USB via
adb reverse, p50 5 ms). Note Air 3 itself is still untested.

## Phase 1: end-to-end MVP

| Deliverable | Status |
|-------------|--------|
| Shared protocol v1 + cross-language fixtures | ✅ |
| Android drawing surface + stroke processor | ✅ hardware |
| macOS TCP server (loopback + LAN, Bonjour, pairing) | ✅ |
| USB via adb reverse | ✅ hardware |
| Wi-Fi TCP | 🟡 (✅ simulator over LAN IP) |
| Ordered, de-duplicated delivery | ✅ |

## Phase 2: native overlay (built early, because the MVP needs somewhere to draw)

| Deliverable | Status |
|-------------|--------|
| Transparent click-through overlay, all Spaces | 🟡 manual check pending |
| Floating non-activating toolbar | 🟡 |
| Catmull-Rom smoothing, pressure width | ✅ |
| Display selection, remap on display change | 🟡 |

## Phase 3: drawing tools

| Deliverable | Status |
|-------------|--------|
| Pen, highlighter, eraser (stroke), laser | ✅ model / 🟡 UI |
| Undo, redo, recoverable clear | ✅ |
| Global keyboard shortcuts | 🟡 |
| Colors, widths, highlighter opacity, eraser size | 🟡 (opacity setting not yet in the toolbar UI) |

## Phase 2b: shared infinite canvas (ADR-006, 2026-10-31)

| Deliverable | Status |
|-------------|--------|
| Protocol v2 (canvas px, viewport, commands, doc sync) | ✅ |
| Persistent local ink on the tablet, render thread, dirty-rect e-ink updates | ✅ hardware |
| Zoom (pinch, ±), pan (finger), Fit, Home on the tablet; Fit/Home on the Mac | ✅ hardware (buttons); ⏳ pinch with fingers by the owner |
| Mac ↔ tablet document sync (style, erase, undo, clear, resync) | ✅ hardware |
| Adaptive toolbar: 3 sizes, 5 positions, hide, menu-bar reopen | 🟡 built; manual check pending |

## Phase 4: sessions

| Deliverable | Status |
|-------------|--------|
| Autosave + crash recovery | ✅ unit / 🟡 manual |
| Save: native save panel, layered export (full page PNG/JPEG, transparent ink PNG, SVG, strokes.json, background, metadata, mapping) | ✅ unit / 🟡 manual panel run |
| Optional screenshot background (ScreenCaptureKit) | 🟡 |
| Session history UI, SQLite index | ⬜ |
| `session.*` protocol messages acted on | ⬜ |

## Phase 5: productization

| Deliverable | Status |
|-------------|--------|
| `NativeUsbTransport` over AOA (no developer mode) | ⬜ next |
| TLS on Wi-Fi with fingerprint pinning + QR pairing | ✅ v0.3 (see below) |
| Calibration wizard (4-point affine) | ⬜ |
| Onboarding flow (welcome → connect → permissions → display → draw) | ⬜ |
| Diagnostic report export | ✅ Mac / ⬜ tablet export |
| Developer ID signing, notarization, installer | ⬜ |
| Localization | ⬜ |

## v0.3: wireless-first + e-ink UI (2026-10-31)

| Deliverable | Status |
|-------------|--------|
| Protocol v3: TLS (pinned self-signed cert), one-time Connect Device codes, device tokens, `resume_sequence` | ✅ unit + JVM↔Swift e2e + **hardware** |
| Bonjour discovery with host identity (TXT `id`), manual-address fallback | ✅ hardware (discovered the Mac at 13.0.0.156) |
| QR `inkbridge://pair` link (fingerprint pre-pinned) | ✅ unit + deep-link tests; BOOX has no camera |
| Connect Device window on the Mac (code, countdown, QR, paired list, Forget) | 🟡 built; manual check pending |
| Network-change reconnect, lossless replay, stroke continuity across drops | ✅ unit; ✅ hardware Wi-Fi off/on |
| Mac listener restart after wake / path change | 🟡 built; sleep/wake not run |
| Android redesign: dashboard, connect, canvas, settings, diagnostics, design system | ✅ Robolectric + hardware screenshots |
| Wi-Fi from the real InkBridge.app (vs. probe host) on hardware | 🟡 pending: needs a click in Connect Device |
| Router restart / IP change / Mac sleep on hardware | ⬜ |
| Wi-Fi Direct / Mac-hosted network for different-network use | ⬜ future |

## Design studio (2026-11-01 →)

| Phase | Deliverable | Status |
|---|---|---|
| 1 | Dynamic backgrounds: Desktop Overlay / Studio Canvas, presets + custom colour, paper patterns, instant switching, undo, sync both ways (revisioned), persistence, layered export (+ PDF) | ✅ unit + e2e; ⏳ BOOX hardware + Mac UI by hand |
| 2 | Tool sync both ways; pencil, marker, opacity; line, arrow, shapes (new `Shape` object) | ⬜ next |
| 3 | Selection, lasso, move/resize/duplicate, shape recognition, full command history | ⬜ |
| 4 | Layers, ruler, guides, snapping, text | ⬜ |
| 5 | Large-canvas performance (spatial index), e-ink tuning, advanced export | ⬜ |

## Proposed next phase

1. **Hardware session** (blocked only on USB debugging): fill in every pending row of
   hardware-feasibility.md, run the manual overlay checklist, and record tablet
   latency over USB and Wi-Fi.
2. Decide MotionEvent vs. ONYX SDK from those numbers.
3. **AOA transport**: extend `tools/aoa-probe` to the full handshake, then build
   `NativeUsbTransport` on both sides. This removes the developer-mode requirement,
   the biggest blocker for real users.
4. ~~TLS + QR pairing for Wi-Fi~~ done in v0.3.

## AI-native Knowledge & Provider Hub (proposed)

Design docs only as of 2026-11-03 — see [`docs/architecture/ai/`](../architecture/ai/README.md)
and ADRs 011–013. **No Hub/OCR/agent code in the product yet.**

| Phase | Focus | Status |
|-------|--------|--------|
| 0 | Architecture docs, ADRs, diagrams | ✅ docs |
| 1 | PDF/page Source foundation + region mapping | ⬜ |
| 2 | OCR/HTR + annotation associations | ⬜ |
| 3 | AI Context Builder | ⬜ |
| 4 | Provider Hub + OpenRouter + Keychain/Keystore + AI panels | ⬜ |
| 5 | Knowledge Library (Save Answer) | ⬜ |
| 6 | Claude Code CLI adapter | ⬜ |
| 7 | Cursor CLI/SDK adapter | ⬜ |
| 8 | Advanced workflows + eval sets | ⬜ |
