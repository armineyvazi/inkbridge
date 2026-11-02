# Changelog

All notable changes to InkBridge are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project uses [Semantic Versioning](https://semver.org/).

## [0.1.0] — 2026-11-02

First public developer-preview release.

### Added

- Native macOS host (Swift): transparent click-through overlay, adaptive toolbar, hot keys.
- Native Android / BOOX client (Kotlin): e-ink dashboard, canvas, Connect to Mac, Settings, Diagnostics.
- Protocol v3: length-prefixed JSON over USB (`adb reverse`) or Wi-Fi (TLS + certificate pinning, one-time pairing).
- Shared infinite canvas (canvas px), zoom/pan, Fit/Home, host-owned document sync.
- Drawing tools: pen (pressure), highlighter, stroke eraser, laser; per-tool sizes in canvas px with tablet controls.
- Daily Journal (⌃⌥N): per-day pages, hide without leaving, history.
- Engineering workspace (⌃⌥G): components, smart connectors, templates.
- Dynamic backgrounds (Desktop Overlay ⇄ Studio Canvas) with paper patterns.
- Projects & storage, incremental autosave, layered export (PNG/JPEG/SVG/PDF).
- Workspace state model (ADR-010) for Overlay / Studio / Engineering / Journal transitions.
- Automated tests: Swift unit + TLS integration; Kotlin core + Robolectric UI; protocol fixtures; `scripts/e2e.sh`.

### Known limitations

- USB still requires developer mode (`adb reverse`); AOA transport is planned.
- No PAKE; pairing codes are short-lived but offline brute force of a sniffed handshake remains an open risk.
- Note Air 3 and eraser-end pens are not hardware-verified (developed on Note Air 2 Plus).
- BOOX local ink latency is bound by the ~40 Hz panel; firmware raw-handwriting mode is not used yet.
- The tablet does not mirror the Mac screen (by design).

[0.1.0]: https://github.com/armineyvazi/inkbridge/releases/tag/v0.1.0
