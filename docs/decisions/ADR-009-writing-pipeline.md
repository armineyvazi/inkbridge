# ADR-009: Writing pipeline: native canvas with incremental dirty-rect frames; compositor bypass deferred

- **Status:** accepted (v0.4, 2026-11-02)
- **Related:** ADR-004 (drawing engine), `docs/performance/writing-latency.md`

## Context

Local ink on the BOOX goes:
1. `MotionEvent` (with historical samples, unbuffered dispatch) → `StrokeProcessor` on the UI thread;
2. `client.submit` (outbox) + `CanvasDocument.applyLocal`;
3. the render thread draws new segments into a cached bitmap, locks a dirty rect with a margin (`lockCanvas`), drains late samples and posts.

Measured per stage on the Note Air 2 Plus (Android 11, 40 Hz panel), final build:

| Stage | p50 | p95 | p99 |
|---|---|---|---|
| Input delivery (sample → `onTouchEvent`, injected stylus) | 2.4 ms | 4.8 ms | 8.4 ms |
| UI-thread processing per `MotionEvent` | 0.9 ms | 2.0 ms | 2.7 ms |
| Handoff to render thread | 0.9 ms | 3.5 ms | 4.8 ms |
| Draw new segments | 0.3 ms | 0.7 ms | 1.2 ms |
| `lockCanvas` (waiting for the 40 Hz panel frame) | 18.6 ms | 29.0 ms | 34.7 ms |
| Copy + post | 3.5 ms | 4.9 ms | 6.6 ms |
| **Oldest sample in a frame → posted** | **28.3 ms** | **39.5 ms** | **45.4 ms** |

Posting happens at most once per 25 ms panel frame. The oldest sample in a frame has therefore waited
up to one frame, plus post: about 28.5 ms. **The app is at the floor of the compositor path.**
App-controlled work is about 5 ms of each frame.

## Problem

Choose the rendering architecture for each platform that minimises input-to-visible-ink latency without
breaking stroke accuracy, e-ink partial refresh, or cross-device consistency.

## Alternatives considered

| Alternative | Evaluation | Result |
|---|---|---|
| `lockHardwareCanvas` / OpenGL ES / Vulkan | Draw is 0.3 ms, so the GPU can save at most that. Hardware canvas has no dirty rect, so the whole surface would be redrawn and damaged every frame, which triggers larger e-ink updates. Not built (theoretical). | Rejected |
| Front-buffered rendering (`androidx.graphics.lowlatency`, API 29+) | Would remove the 18 ms `lockCanvas` wait from *our* metric. Whether the EPD shows ink sooner depends on when the firmware scans out a front-buffer layer, which software timestamps can't show. Needs a high-speed-camera test. | Deferred (measurement first) |
| BOOX raw handwriting (Onyx SDK / hidden View APIs) | The only known path below one panel frame: the EPD controller draws the trail. Firmware-dependent, own pen look, reported freezes when changing width often, and can leave raw mode active over other apps. | Deferred (opt-in candidate) |
| Motion prediction (`androidx.input`) | Wrong predictions must be erased; on e-ink that leaves ghosts and extra refreshes. | Rejected for e-ink |
| RGB_565 surface | Measured: lock 20.1 vs 20.3 ms, copy unchanged. | Rejected (measured) |
| Lock-then-drain frame order | Measured: p50 48 → 28 ms. | Adopted (v0.3.x) |
| Per-run `Path` instead of per-segment `drawLine` | Fixes notched edges on thick lines (overlapping anti-aliased round caps). Draw p50 unchanged (0.3 ms). | Adopted |
| Mac: Metal instead of Core Graphics | Mac draws 0.03 ms per frame after dirty-rect culling. Nothing to gain. | Rejected |

## Decision

- Keep native `Canvas` with an incremental cached bitmap, dirty-rect `lockCanvas` and lock-then-drain on the BOOX; Core Graphics with dirty-rect culling on the Mac. One rendering engine per platform.
- The critical path stays free of network and disk:
  - `client.submit` only enqueues;
  - Mac persistence runs on background queues;
  - tool requests are queued like strokes.
- Every stage is instrumented (`perf …` in logcat, Diagnostics screen) so regressions are visible.
- Compositor bypass (front buffer, BOOX raw mode) is the next step. It's gated on a **photon-level** measurement on the Note Air 3. Software timestamps would report a gain that may not exist on the panel.

## Consequences

- On this hardware, local latency stays panel-bound: about 28 ms p50 / 40 ms p95 from the oldest sample to posted, plus the e-ink waveform (not measurable without a camera).
- Large tools cost slightly more (highlighter 72 px: p50 29.2 ms, p95 41.3 ms; draw 0.5 ms, post 4.0 ms).

## Validation

- `make -C apps/android test`: `BenchmarkTest.localPenPathPercentiles` (UI-thread path, p99 < 1 ms budget on the JVM; measured p99 1.6 µs).
- Hardware runs with `scripts/latency-run.sh` (60 injected strokes): baseline and final builds, two rounds each, plus a run at highlighter 72.
