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

## Phase 4: sessions

| Deliverable | Status |
|-------------|--------|
| Autosave + crash recovery | ✅ unit / 🟡 manual |
| Save: strokes.json + PNG + PDF | ✅ |
| Optional screenshot background (ScreenCaptureKit) | 🟡 |
| Session history UI, SQLite index | ⬜ |
| `session.*` protocol messages acted on | ⬜ |

## Phase 5: productization

| Deliverable | Status |
|-------------|--------|
| `NativeUsbTransport` over AOA (no developer mode) | ⬜ next |
| TLS on Wi-Fi with fingerprint pinning + QR pairing | ⬜ |
| Calibration wizard (4-point affine) | ⬜ |
| Onboarding flow (welcome → connect → permissions → display → draw) | ⬜ |
| Diagnostic report export | ✅ Mac / ⬜ tablet export |
| Developer ID signing, notarization, installer | ⬜ |
| Localization | ⬜ |

## Proposed next phase

1. **Hardware session** (blocked only on USB debugging): fill in every pending row of
   hardware-feasibility.md, run the manual overlay checklist, and record tablet
   latency over USB and Wi-Fi.
2. Decide MotionEvent vs. ONYX SDK from those numbers.
3. **AOA transport**: extend `tools/aoa-probe` to the full handshake, then build
   `NativeUsbTransport` on both sides. This removes the developer-mode requirement,
   the biggest blocker for real users.
4. **TLS + QR pairing** for Wi-Fi.
