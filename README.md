# InkBridge

[![CI](https://github.com/armineyvazi/inkbridge/actions/workflows/ci.yml/badge.svg)](https://github.com/armineyvazi/inkbridge/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Release](https://img.shields.io/github/v/release/armineyvazi/inkbridge?include_prereleases)](https://github.com/armineyvazi/inkbridge/releases)

**v0.1.0** — developer preview.

Use a **BOOX** e-ink tablet (target: Note Air 3; verified on Note Air 2 Plus) as a pen
tablet for macOS. Write on the tablet; strokes stay on the tablet **and** appear as
native vector ink **over whatever is on the Mac’s screen** (videos, PDFs, browsers,
Figma, slides). The overlay is click-through, so the app underneath keeps working.

InkBridge does **not** mirror the screen. The tablet sends pen samples (normalized
position, pressure, time). The Mac renders them in a transparent overlay. Traffic is
about 30 KB/s while drawing. Everything stays on your local network or USB cable.

```mermaid
flowchart LR
  Pen[BOOX stylus] --> A["Android app<br/>MotionEvent → strokes"]
  A -- "USB / Wi-Fi TLS" --> M["Mac host<br/>validate → StrokeStore"]
  M --> O["Transparent click-through overlay"]
```

## Status

| | |
|---|---|
| Phase | Developer preview (`v0.1.0`) |
| Verified hardware | BOOX Note Air 2 Plus over USB and Wi-Fi |
| Pending hardware | Note Air 3; AOA USB without developer mode |
| License | [MIT](LICENSE) |

Claims in this README match what is **built and tested**. Hardware claims are labelled
in `docs/` as Verified (hardware), Verified (sourced), or Pending.

## Features

| Area | Capability |
|------|------------|
| Canvas | Shared infinite canvas; zoom/pan on tablet; Fit / Home; ink persists on tablet |
| Tools | Pen (pressure), highlighter, eraser, laser; **tablet pen-size** controls; sizes in canvas px shared with Mac |
| Editing | Undo/redo of strokes; clear is undoable |
| Overlay | Transparent, click-through, any display, above full-screen apps |
| Daily Journal | ⌃⌥N — per-day pages, hide without leaving, history |
| Studio & Engineering | Backgrounds; Engineering (⌃⌥G): components, connectors, templates |
| Storage | Projects, incremental autosave, layered Save… (PNG/JPEG/SVG/PDF) |
| Connection | Wi-Fi first (Bonjour, TLS pin, one-time code); optional USB via `adb reverse` |

## Quick start

```bash
git clone https://github.com/armineyvazi/inkbridge.git
cd inkbridge

# Mac host
make install-macos

# Tablet (USB debugging on; see docs/implementation/setup.md)
make install-android
scripts/adb-usb.sh --watch
```

**Wi-Fi (no cable):** Mac menu-bar pen → Connect Device… (⌃⌥K). On the tablet: Connect
to Mac → pick the Mac → enter the code. Details: [setup](docs/implementation/setup.md).

No tablet? `scripts/e2e.sh` runs the Kotlin client against the Swift host with a
simulated pen.

## Repository layout

```text
apps/android/     Kotlin: :core (pure JVM), :app, :simulator
apps/macos/       Swift: InkBridgeCore, InkBridge.app, inkbridge-probe
protocol/         Shared fixtures for both test suites
scripts/          e2e.sh, adb-usb.sh, latency-run.sh
docs/             Architecture, protocol, ADRs, testing, release notes
tools/aoa-probe   USB AOA capability probe (C, libusb)
```

The layout follows platform boundaries already used in development. Do not invent
extra `domain/` / `infrastructure/` layers unless a concrete need appears.

## Development

```bash
make help
make test          # macOS + Android tests
make lint          # swift-format lint + Android lintDebug
make check         # lint + test (CI entry point)
make format        # apply Swift formatting
```

Prerequisites and permissions: [docs/implementation/setup.md](docs/implementation/setup.md).  
Contributing: [CONTRIBUTING.md](CONTRIBUTING.md).

## Documentation

| Start here | |
|---|---|
| [docs/README.md](docs/README.md) | Doc index |
| [Architecture overview](docs/architecture/system-overview.md) | System design |
| [Protocol](docs/protocol/protocol-specification.md) | Wire format |
| [ADRs](docs/decisions/) | Design decisions (001–010) |
| [Release notes v0.1.0](docs/release-notes/v0.1.0.md) | This release |
| [Security](SECURITY.md) · [security architecture](docs/architecture/security.md) | Threat model & reporting |

Maintainer engineering notes may also live in a private Obsidian vault. **GitHub `docs/`
is authoritative for contributors.** See [docs/README.md](docs/README.md#documentation-sources).

## Tests

```bash
make test-macos      # Swift unit + TLS integration
make test-android    # Kotlin core + Robolectric UI
scripts/e2e.sh && scripts/e2e.sh wifi
```

BOOX panel latency and real stylus behaviour require hardware; CI covers logic and
loopback transport, not photon-level e-ink timing.

## Known limitations

- USB needs developer mode for now (AOA planned; see ADR-002).
- Pairing has no PAKE yet (see [security](docs/architecture/security.md)).
- No calibration wizard yet.
- On BOOX, local ink is bound by the ~40 Hz panel ([writing latency](docs/performance/writing-latency.md)).
- The tablet does not show the Mac’s screen (by design).
- Note Air 3 and eraser-end pens are not yet hardware-verified.
- Tablet ink is monochrome; colours appear on the Mac.

## License

[MIT](LICENSE) © 2026 Armin Eyvazi
