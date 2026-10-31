# Android UI tests

| Layer | Where | Runs on | Count |
|---|---|---|---|
| Connection state model (stages, wording, primary action, failures) | `core/.../ConnectionStatusTest.kt` | JVM | 4 |
| QR link parsing, pressure curves | `core/.../ConnectionStatusTest.kt` | JVM | 3 |
| Screens (Robolectric, API 30) | `app/src/test/.../UiTest.kt` | JVM | 9 |
| Screen renders at 1404×1872 / 240 dpi | `ScreenshotTest` (`make -C apps/android screenshots`) | JVM, native graphics | pictures, not assertions |

Run with `make -C apps/android test`, which covers `:core:test` and `:app:testDebugUnitTest`.

## What the Robolectric tests check

| Test | Requirement covered |
|---|---|
| `dashboardWhenNotPairedLeadsToConnect` | Dashboard renders state, "Not paired", and the primary action opens Connect |
| `dashboardNavigatesToSettingsDiagnosticsAndOfflineCanvas` | Navigation |
| `settingsApplyImmediatelyAndPersist` | Settings sections; segmented choices persist and reach the live manager |
| `manualPairingFormatsTheCodeAndStartsPairing` | Pairing workflow: address → code (auto-formatted `K7QW-M3XP`) → pairing request |
| `shortCodeIsRejectedLocally` | Error state before any network traffic |
| `qrLinkPairsWithThePinnedCertificate` | `inkbridge://pair` deep link pre-pins the certificate |
| `expiredQrLinkExplainsWhatToDo` | Error state |
| `canvasIsFullScreenWithCompactControls` | Canvas visibility, full-screen surface, every control labelled, zoom works |
| `diagnosticsNeverShowsSecrets` | No token or code in the diagnostics text |

## Verified on hardware (BOOX Note Air 2 Plus, 2026-10-31)

All of these were driven with `adb shell input` taps and stylus swipes, and checked with `screencap`.

| Check | Result |
|---|---|
| Dashboard renders on e-ink (contrast, hierarchy, no grey wash) | ✅ |
| Connect: discovery list shows the Mac at its LAN address | ✅ |
| Code entry auto-formats; wrong code → "Wrong code…", stays on the screen | ✅ |
| Done screen → Start drawing → canvas with chip "InkBridge Probe · Wi-Fi" | ✅ |
| Strokes stay visible on the canvas | ✅ |
| Certificate changed → "Mac identity changed" + Pair again | ✅ |
| Mac forgot the tablet → "Pair again · The Mac no longer recognises this tablet", pairing cleared | ✅ (after a fix found on hardware) |
| Real-pen feel, pinch/pan, e-ink ghosting over long sessions | ⏳ needs a person with the pen |

Two bugs were found on hardware and fixed:

- **Failed pairing still offered as "Paired" on the Connect screen.** Tapping it retried the failing pairing.
- **"Pair again" reason lost when the Mac forgot the tablet.** The dashboard fell back to "Mac found".

An earlier APK also showed a hairline that expanded to fill a card. That was caught in the Robolectric screenshots first.
