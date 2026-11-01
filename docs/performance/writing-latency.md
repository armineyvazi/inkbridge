# Writing latency: investigation and results (2026-11-01)

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

### BOOX: frame ordering (pending a measurement on hardware)

Samples that arrived while the render thread waited ~20 ms for a frame used to miss that frame. Now:
1. The region around the new ink is locked with a 96 px margin.
2. Samples that arrived during the wait are drawn before posting.
3. Ink outside the margin is carried to the next frame.

The old order is still available for A/B measurement with
`adb shell setprop debug.inkbridge.legacyframe 1`.

**Not yet measured on the tablet:** the tablet locked with a PIN during this work, and I don't enter PINs.
Run `scratchpad/inkrun.sh 1` and then `inkrun.sh 0` (see Testing) to compare.

### Tried and reverted

- **16-bit surface and cache (RGB_565):** lock time 20.1 ms vs 20.3 ms, and copy time unchanged. No gain, so it was reverted.

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
| Local input → visible ink ≤ 16 ms p95 | **Not achievable on this BOOX via Android**: the panel is 40 Hz. App share ≈ 4 ms/frame; sample → posted p95 ≈ 44 ms. Mac render path ≤ 0.2 ms/frame |
| Frame time ≤ 16.7 ms p95 | Mac: < 1 ms of drawing per frame. BOOX: bounded by the 25 ms panel frame |
| No avoidable main-thread blocking | Journal page save (82 ms) moved off the main thread; saves are background, appends are sub-millisecond |
| Zero network dependency for local ink | **Verified on hardware** (Wi-Fi off: same latency) |
| Zero lost acknowledged strokes | Append log + crash tests; `kill -9` recovery test |
| No full redraw per input point | Mac: dirty-rect culling for strokes, diagram, labels. BOOX: incremental since v0.3 |
