# Pen size and writing-performance tests (v0.4)

## Automated

| Suite | Test | Covers |
|---|---|---|
| Swift `ToolSettingsTests` | `testLimitsAndPresetsMatchSharedFixture`, `testStepVectorsMatchSharedFixture` | Mac limits/presets/steps = `protocol/fixtures/tool-sizes.json` |
| | `testEachToolKeepsItsOwnSize`, `testSizesAreClamped` | per-tool memory, range, NaN |
| | `testWireRoundTrip` | `tool.state` / `tool.request` codec |
| | `testChangingSizeDoesNotRestyleExistingStrokes` | existing strokes keep their width |
| Kotlin `ToolSettingsTest` | the same fixture checks, per-tool memory, wire round-trip | tablet = Mac |
| | `staleRepliesAreSkippedLatestIsAdopted` | slider drag doesn't jump back; Mac-side changes merge |
| | `macRestartIsAdoptedAfterReconnect`, `unacknowledgedEditIsResentInFullOnReconnect` | reconnect rules |
| | `localInkUsesSelectedToolAndSize`, `sizeChangeDoesNotRestyleExistingStrokes` | local ink before the Mac answers |
| Kotlin `UiTest.penSizeControlsArePerToolAndApplyToTheNextStrokeOnly` | real toolbar buttons, real stylus `MotionEvent`s, saved preferences | |
| Kotlin `BenchmarkTest.localPenPathPercentiles` | UI-thread pen path, p99 < 1 ms budget | writing responsiveness regression |
| Protocol fixtures | `valid/tool.state.json`, `valid/tool.request.json`, `invalid/bad-tool-size*.json` | both decoders (32 valid fixtures) |
| Screenshots | `8-pen-pen.png`, `8-pen-highlighter.png`, `8-pen-eraser.png` | panel and toolbar group |

## On hardware (Note Air 2 Plus + Mac, 2026-11-02)

| Check | Result |
|---|---|
| Pen 4 / 5.5 / 11 at 100 % | 4 / 6 / 12 px on screen |
| Pen 11 at 150 % | 16 px on screen; the Mac stored 11 for both strokes |
| Highlighter over ink | even grey band, ink stays black |
| Switch pen → highlighter → eraser → pen | pen kept 11; highlighter kept 32 |
| Preset S, slider drag | Mac received 3, then 16 |
| Mac changed while quit (7, then 8), relaunch | tablet adopted 8 (after the reconnect fix) |
| Tablet + + while the Mac was quit (8 → 10), relaunch | Mac adopted 10 |
| Latency, final build vs baseline | p50 28.3 vs 28.3–28.8 ms; p95 39.2–39.5 vs 39.2–40.5 ms; 0 dropped samples |
| Latency with highlighter 72 | p50 29.2 ms, p95 41.3 ms |

**Not verified:**
- the Note Air 3 (not available);
- real Mac clicks on the toolbar slider (no Accessibility permission). The Mac → tablet path was tested through saved preferences and a relaunch;
- a real pen's input delivery (runs use `adb input` injection).
