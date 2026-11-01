# Writing latency: investigation and results (2026-11-01, round 2 on 2026-11-02)

Everything here was measured; nothing was optimised on assumption. Mac numbers come from
`make -C apps/macos bench` (release, `JournalPerformanceTests`). Tablet numbers come from the app's own
recorders (`CanvasRenderer.inkLatency/frameTime/drawTime/lockTime/postTime`, shown in Diagnostics and
logged as `perf …` every 200 frames) on a **BOOX Note Air 2 Plus** (Android 11), with 40–60 injected
stylus strokes per run (`adb shell input stylus swipe`). No Note Air 3 was available.

## Pipeline and where the time goes

| Stage | BOOX | Mac |
|---|---|---|
| Input acquisition | `MotionEvent` with batched historical samples (already used) | tablet samples over the network, or the mouse |
| Event processing → document | < 0.1 ms per sample | < 0.1 ms per sample |
| Drawing new segments | **0.3 ms p50 / 0.7 ms p95** (incremental, into a cached bitmap) | **0.03 ms** per frame after culling (was up to 1.5 ms) |
| Waiting for a display frame (`lockCanvas`) | **20.3 ms p50 / 32 ms p95**: the panel refreshes at **40 Hz** (25 ms, `dumpsys SurfaceFlinger`) | — |
| Copy + post | 2.6 ms p50 / 3.7 ms p95 | — |
| E-ink waveform (pixels physically change) | not measurable without a camera; firmware-controlled | — |
| Network | **not in the ink path**: online and Wi-Fi-off runs are identical (30.3 vs 29.7 ms p50) | tablet → Mac p95 13.6 ms (v0.3) |
| Disk | never on the drawing path (background queues) | see Persistence |

**Conclusion for the BOOX:** the app spends under 4 ms of each frame. The rest is the 40 Hz panel.
A 16 ms target can't be met through Android's compositor on this device. The measurable
app-side latency (stylus sample → frame posted) is **p50 ≈ 30 ms, p95 ≈ 44 ms**, about 1–2 panel frames.

## Changes and their measured effect

### Mac: per-frame redraw work

| Measurement (one frame while writing) | Before | After |
|---|---|---|
| Live stroke, 1000 points, in the dirty rect | 0.49 ms | **0.03 ms** (only the touched runs are re-smoothed; pixel-identical, tested) |
| Diagram with 108 components behind the ink | 1.24 ms | **0.17 ms** (objects culled to the dirty rect) |
| Journal time labels (30 sessions, 72k points) | 0.22 ms (scanned every point every frame) | **~0 ms** (positions cached when the ink changes) |

### Mac: persistence off the drawing path

| Operation | Before | After |
|---|---|---|
| Journal page write (300 entries) | **82 ms on the main thread** after every stroke (a date formatter was created per timestamp) | **1.3 ms**, on a background queue, coalesced |
| Autosave after a stroke, 2000-stroke session | full rewrite, ~200 ms (background) | **append one line: 0.30 ms p50 / 0.41 ms p95** (`strokes.log`) |
| `strokes.json` encoding | pretty-printed | compact (−17 % time) |

Incremental saving (`IncrementalSave`):
- **When it appends:** if the strokes already saved are an unchanged prefix of the current strokes, only the new ones are appended.
- **When it writes everything:** undo, erase, background or diagram changes, and logs over 400 strokes cause a full write. A full write also folds the log in.
- **Loading:** replays the log in order, skips duplicates (a retried save), and skips a torn last line (a crash mid-append). Tests in `IncrementalSaveTests`.

### BOOX: frame ordering (measured 2026-11-02)

Samples that arrived while the render thread waited ~20 ms for a frame used to miss that frame. Now:
1. The region around the new ink is locked with a 96 px margin.
2. Samples that arrived during the wait are drawn before posting.
3. Ink outside the margin is carried to the next frame.

The A/B switch is `adb shell setprop debug.inkbridge.legacyframe 1|0`. Each run was 60 strokes and 600 frames, two rounds each, measuring the **oldest** new sample in each frame (the worst case the frame contains):

| Stylus sample → frame posted | p50 | p95 | p99 |
|---|---|---|---|
| Old order | 48.3 ms | 60.1 ms | 65.5–69.5 ms |
| **New order (default)** | **28.2 ms** | **39.8–40.9 ms** | **46 ms** |

That's about 20 ms faster, almost one 40 Hz panel frame. Frame cost is unchanged (23 ms p50, dominated by the panel). A screenshot after the run shows every stroke complete.

(The earlier "30 ms" baseline measured the *newest* sample in each frame, which hides the wait. From here on, the oldest sample is reported.)

### Tried and reverted

- **16-bit surface and cache (RGB_565):** lock time 20.1 ms vs 20.3 ms, and copy time unchanged. No gain, so it was reverted.


## Round 2 (2026-11-02): per-stage breakdown, pen sizes, final build

Same tablet (Note Air 2 Plus, Android 11, 40 Hz panel), same runner (`scripts/latency-run.sh`,
60 injected stylus strokes = 600 frames per run). New recorders split the path into stages:
`input` (sample time → `onTouchEvent`), `process` (UI thread per `MotionEvent`), `handoff`
(first new sample in the document → render frame starts), `draw`, `lock`, `copy+post`, plus
CPU share, heap and dropped samples (`PerfProbe`).

### Baseline vs final (two runs each)

| Oldest sample → posted | p50 | p95 | p99 |
|---|---|---|---|
| Baseline (`e2daf68`, installed build) | 28.8 / 28.3 ms | 39.2 / 40.5 ms | 45.7 / 45.8 ms |
| **Final (v0.4)** | **28.3 / 28.3 ms** | **39.2 / 39.5 ms** | **44.1 / 45.4 ms** |
| Final, highlighter at 72 px (largest dirty rects) | 29.2 ms | 41.3 ms | 44.8 ms |

### Final build, per stage

| Stage | p50 | p95 | p99 | Kind |
|---|---|---|---|---|
| Input delivery (digitizer/injector → app) | 2.4 ms | 4.8 ms | 8.4 ms | input acquisition (system) |
| UI-thread processing per `MotionEvent` | 0.9 ms | 2.0 ms | 2.7 ms | app |
| Handoff to render thread | 0.9 ms | 3.5 ms | 4.8 ms | app |
| Draw new segments | 0.3 ms | 0.7 ms | 1.2 ms | local rendering |
| `lockCanvas` (panel frame) | 18.6 ms | 29.0 ms | 34.7 ms | display presentation (40 Hz) |
| Copy + post | 3.5 ms | 4.9 ms | 6.6 ms | local rendering |
| E-ink waveform | n/a | n/a | n/a | needs a high-speed camera |
| CPU while writing continuously | 35–37 % of one core | | | |
| Heap after a run | Java 5.5–8.2 MB, native 19.8–21.2 MB | | | |
| Dropped input samples | **0** of 2 676 / 2 781 | | | |

**Bottleneck:** the panel. Posts happen at most once per 25 ms frame, so the oldest sample in a
frame waits up to one frame. 25 ms + 3.5 ms post ≈ the measured 28.3 ms p50. App-controlled work is
about 5 ms per frame. Input numbers come from `adb input` injection; a real pen's digitizer delivery
may differ.

**Not re-measured this round (unchanged code paths):**
- network: tablet → Mac p95 13.6 ms (v0.3), and the network is not in the local ink path (Wi-Fi-off run identical, round 1);
- persistence: append 0.30 ms p50 / 0.41 ms p95 (round 1).

JVM regression guard: `BenchmarkTest.localPenPathPercentiles` runs the UI-thread path
(processor + local document with the selected tool/size) over 10 000 events with fast/slow
hands, direction changes and size changes: **p50 0.7 µs, p95 1.1 µs, p99 1.6 µs**. The budget
is p99 < 1 ms.

### Found and fixed

- **Perf log on every frame:** it logged when `frameTime.size % 200 == 0`, but the recorder stops growing at 2 000 samples. After 2 000 frames that was true on every frame, logging from the render thread. Now a separate counter.
- **Handoff measurement:** samples drained late inside a frame were counted as waiting for the next one (p50 15.6 ms reported, 0.9 ms real).
- **Notched thick lines:** each segment was drawn with its own round caps, and the overlapping anti-aliased caps darkened every joint. Equal-width runs are now one `Path`. Draw time unchanged.
- **Highlighter look:** a translucent grey drawn per segment compounds alpha where caps overlap. Now opaque grey with a DARKEN blend (LIGHTEN on dark paper). Even band, ink underneath stays black. Verified on the device.

### Alternatives evaluated

| Option | Problem it targets | Status | Evidence |
|---|---|---|---|
| Historical samples, unbuffered dispatch | input batching | in use | input delivery p50 2.4 ms |
| Lock-then-drain, dirty rect + margin | samples missing a frame | in use | 48 → 28 ms (round 1) |
| One `Path` per equal-width run | stroke quality | adopted | draw p50 0.3 ms unchanged |
| RGB_565 | copy cost | rejected | no gain (round 1) |
| GPU canvas / GL / Vulkan | draw cost | rejected | draw is 0.3 ms; no dirty rects → larger e-ink updates (theoretical) |
| Front-buffered layer (`androidx.graphics.lowlatency`, API 29+) | the 18 ms frame wait | deferred | needs a photon-level test; software timestamps would show a false win |
| BOOX raw handwriting | sub-frame ink | deferred, opt-in candidate | firmware-dependent; see below |
| Motion prediction | perceived latency | rejected for e-ink | wrong predictions leave ghosts |
| Spatial index for strokes | full-redraw culling | not needed | linear bounds culling; no measured cost on the drawing path |
| Mac: Metal | Mac frame cost | rejected | 0.03 ms per frame already |

## BOOX e-ink controls (investigated, not used)

The firmware exposes hidden methods on `android.view.View` (found by reflection on the device):
- `setEpdTurbo`;
- `applyAppScopeUpdate(String, boolean, boolean, int, int)`, i.e. app-wide fast/A2 mode;
- `refreshScreen(...)`;
- `setScreenHandWritingPenState` and `setScreenHandWritingRegionLimit`: firmware "raw" handwriting, where the EPD controller draws the pen trail itself, bypassing the compositor.

The raw handwriting mode is the only way below one 25 ms panel frame. BOOX's own notes app uses it.

It isn't used yet because:
- it is undocumented and differs per firmware;
- the firmware draws its own pen style, so the ink would visibly change once our stroke replaces it;
- a wrong region limit can leave the device drawing ink over other apps until the mode is reset.

This is a candidate for an opt-in "fast ink (BOOX)" setting, tested on the Note Air 3 itself.

## Targets vs results

| Target | Result |
|---|---|
| Local input → visible ink ≤ 16 ms p95 | **Not achievable on this BOOX via Android**: the panel is 40 Hz. App share ≈ 4 ms/frame; sample → posted p95 60 → **40 ms** (frame ordering). Mac render path ≤ 0.2 ms/frame |
| Frame time ≤ 16.7 ms p95 | Mac: < 1 ms of drawing per frame. BOOX: bounded by the 25 ms panel frame |
| No avoidable main-thread blocking | Journal page save (82 ms) moved off the main thread; saves are background, appends are sub-millisecond |
| Zero network dependency for local ink | **Verified on hardware** (Wi-Fi off: same latency) |
| Zero lost acknowledged strokes | Append log + crash tests; `kill -9` recovery test |
| No full redraw per input point | Mac: dirty-rect culling for strokes, diagram, labels. BOOX: incremental since v0.3 |
