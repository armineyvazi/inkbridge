# Testing

## How to run

| Suite | Command | Count | Last result (2026-10-31) |
|-------|---------|-------|--------------------------|
| Swift unit + integration | `make -C apps/macos test` | 80 | **80 passed** |
| Kotlin `:core` unit + integration | `make -C apps/android test` | 43 | **43 passed** |
| Android lint | `./gradlew :app:lintDebug` | — | 0 errors, 22 warnings (i18n string literals, dependency-update notices) |
| Cross-language E2E, USB path | `scripts/e2e.sh` | 6 strokes | **pass**: 720/720 points, 0 dropped |
| Cross-language E2E, Wi-Fi path | `scripts/e2e.sh wifi` | 6 strokes | **pass**: 720/720 points, 0 dropped, pairing OK |
| Swift benchmarks (release) | `make -C apps/macos bench` | — | see below |

## Hardware scenarios (Note Air 2 Plus, USB, 2026-10-31)

Driven with `adb shell input stylus swipe` / `input tap`, checked by tablet screenshots
(`adb shell screencap`) and the Mac's autosave:

| # | Scenario | Result |
|---|---|---|
| 1 | Persistent local drawing: 3 strokes stay visible | ✅ |
| 2 | Infinite canvas: zoom out ×2 (44 %), draw in empty space at canvas (1598…2160, 2023…2698), earlier ink preserved | ✅ Mac autosave has all 5 strokes in canvas px; Mac viewport = tablet viewport |
| 3 | Sync: tablet Clear → Mac clears (undoable) → tablet empties; tablet Undo → strokes come back **from the Mac**; Fit frames everything | ✅ |
| 7 | Tablet app force-stopped and relaunched → full resync → all ink back | ✅ |
| — | Latency with ink ON (new render thread), 20 injected strokes | ✅ pen→Mac p50 6.4 / p95 14.9 / p99 23.3 ms; on-tablet p95 7.1 ms (old UI-thread renderer: 54.2 ms) |
| 4, 5 | Layered export, native save panel | ✅ unit tests (bundle contents, transparency, JPEG, SVG culling, no-permission path, atomic replace); ⏳ manual run of the panel |
| 6 | Toolbar resize, dock left/right, hide, reopen from menu bar | ⏳ manual check (builds; behaviour not unit-testable) |

## Coverage map

| Area | Swift tests | Kotlin tests |
|------|-------------|--------------|
| Every valid fixture decodes and round-trips; every invalid fixture is rejected | `MessageCodecTests` | `MessageCodecTest` |
| Framing: byte-by-byte, coalesced, oversized, zero-length, 10k-frame compaction | `FrameDecoderTests` | `FramingTest` (+ Swift-framed bytes) |
| Pairing HMAC against the shared vector | `PairingAuthTests` | `PairingAuthTest` |
| Coordinate mapping: fit, stretch, clamp, calibration | `CoordinateMapperTests` | `CoordinateNormalizerTest` |
| Stroke lifecycle, palm rejection, eraser, button, repair, batch split | `StrokeStoreTests`, `StrokeIngestorTests` | `StrokeProcessorTest` |
| Undo / redo / clear / erase order restore / cancel rollback / laser | `StrokeStoreTests` | — |
| Eraser geometry incl. fast-swipe regression | `GeometryTests` | — |
| Smoothing passes through samples, decimation | `SmoothingTests` | — |
| Sequence de-dup across reconnects | `StrokeIngestorTests` | `InkBridgeClientTest.handshakeThenOrderedStrokes` |
| Clock sync, latency stats, peer arbitration | `SessionTests` | — |
| Autosave round trip; old format rejected; export bundle layers, transparency, JPEG, SVG, no-permission path, atomic replace | `SessionTests` | — |
| Viewport math: fit, zoom about focus, clamp, pan, unmap | `CoordinateMapperTests`, `ViewportTests` | `ViewportTest` |
| Document sync: resync, no echo, minimal diffs, eraser drop, chunking; tablet commands | `DocumentSyncTests` | `CanvasDocumentTest`, `InkBridgeClientTest.hostDocumentMessages…` |
| v2 messages and colour hex agree across languages | `MessageCodecTests.testV2Messages` | `MessageCodecTest.v2Messages`, `colorHexMatchesSwift` |
| Server: USB handshake, Wi-Fi auth OK / wrong / missing, strokes before hello, handshake timeout, oversized frame, invalid message survival, ping/pong, idle timeout | `InkServerTests` (real sockets) | — |
| Client: handshake, ordering, pairing, wrong code without retry loop, reconnect < 3 s with queued delivery, RTT, connection refused | — | `InkBridgeClientTest` (real sockets) |
| Backoff and jitter bounds | — | `ReconnectionPolicyTest` |

## Benchmarks

Apple Silicon Mac; Swift numbers from the debug test build unless noted.

| Benchmark | Result | Budget |
|-----------|--------|--------|
| Swift: deframe + decode + validate `stroke.point` (2 samples) | 8.5 µs | 2 ms input processing |
| Swift: map one point | 94 ns | — |
| Swift: render a 2 000-point pressure stroke at 2× | 7.2 ms | only on cache rebuild |
| Kotlin (JVM): process + encode + frame one MotionEvent | 1.9–2.5 µs | 2 ms |
| E2E loopback pen→host p50/p95/p99 | 0.44 / 0.83 / 1.48 ms | 50 ms input-to-visible |

## Verification status

| Item | Unit | Integration | Hardware |
|------|------|-------------|----------|
| Protocol codec + framing | ✅ | ✅ | ✅ (Note Air 2 Plus) |
| Pairing auth | ✅ | ✅ | ⏳ (Wi-Fi from tablet) |
| USB via adb reverse | — | ✅ (loopback, simulator) | ✅ p50 5 ms / p95 16 ms |
| Wi-Fi TCP | — | ✅ (Mac LAN IP, simulator) | ⏳ |
| Bonjour advertise | — | ✅ (`dns-sd -B`) | ⏳ discovery from tablet |
| AOA support | — | — | ✅ protocol v2 |
| Stylus capture / pressure / rate | ✅ (processor logic) | — | ✅ 360 Hz, pressure 0–4095, tilt, hover |
| Eraser end / stylus buttons | ✅ (processor logic) | — | ⏳ (test pen has none) |
| Overlay over normal windows, click-through | — | — | ⏳ manual check |
| Overlay over full-screen apps / Spaces | — | — | ⏳ manual check |
| Multiple displays / resolution change | ✅ (mapper) | — | ⏳ manual check |
| Hot keys | — | — | ⏳ manual check |
| Session save / recovery / export | ✅ | — | ⏳ manual check |
| Screenshot background | — | — | ⏳ manual check (needs permission) |

✅ passed · ⏳ not yet verified

## Manual Mac checklist (overlay)

1. `make -C apps/macos run`, then `make -C apps/android simulate ARGS="--strokes 9"`.
2. While strokes appear: click and scroll in the window underneath. It must respond.
3. Type into another app. Keystrokes must not go to InkBridge.
4. Put Safari full screen (⌃⌘F) and draw again. Ink must appear above it.
5. Switch Spaces. The overlay must follow, and the toolbar stays.
6. ⌃⌥Z / ⌃⌥⇧Z / ⌃⌥C / ⌃⌥O while another app is frontmost.
7. Settings → Draw on → an external display. Ink moves there.
8. Save (⌃⌥S). Finder opens `export.pdf`; check it and `preview.png`.
9. `kill -9` the app mid-session and relaunch. The strokes come back.
