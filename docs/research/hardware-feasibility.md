# Hardware feasibility report: BOOX tablets (tested on a Note Air 2 Plus)

Last updated: 2026-10-31. Every statement is labelled **Verified (hardware)**,
**Verified (sourced)** (from vendor or retailer documentation, not observed), or
**Pending**.

> **Correction.** The brief targets the Note Air 3, and the early sections of this
> project assumed the connected tablet was one. Once USB debugging was enabled, the
> unit identified itself as a **BOOX Note Air 2 Plus** (`ro.product.model=NoteAir2P`)
> running **Android 11 (API 30)**. All hardware results below are from that unit.
> Note Air 3 figures (Android 12) are sourced only. The code targets API 26+ and
> uses only standard Android input APIs, so it is not model-specific.

## 1. Environment

| Item | Value | How |
|------|-------|-----|
| Mac | macOS 27.2 (26B123), Apple Silicon | `sw_vers` |
| Xcode / Swift | Xcode 27.1, Swift 6.4 | `xcodebuild -version` |
| Android SDK | platform `android-34`, build-tools 34.0.0 at `/opt/homebrew/share/android-commandlinetools` | `ls` |
| JDK | 17.0.21 (Homebrew). The shell default is JDK 11, so the Makefile pins 17 | `java -version` |
| Gradle | wrapper 8.11.1 (AGP 8.7.3, Kotlin 2.0.21) | `gradle-wrapper.properties` |
| ADB | 1.0.41 / platform-tools 37.0.1 | `adb version` |
| Tablet link | USB-C through a VIA Labs USB hub | `ioreg` |

## 2. Device facts (test unit)

| Fact | Status | Detail |
|------|--------|--------|
| Model | **Verified (hardware)** | ONYX `NoteAir2P` (BOOX Note Air 2 Plus), board `bengal` (Qualcomm), firmware `D60_SMT_V02_2022_0309`, fingerprint `ONYX/BOOX/BOOX:11/RKQ1.210614.002/200:userdebug/release-keys` |
| Android | **Verified (hardware)** | 11, API 30 |
| Display | **Verified (hardware)** | 1404 × 1872 px, 240 dpi (portrait) |
| USB-C, default | **Verified (hardware)** | `18d1:4ee1` "ONYX" / "BENGALP-IOT-IDP", MTP only; with USB debugging on, ADB serial `16180A09` |
| Android Open Accessory | **Verified (hardware)** | `ACCESSORY_GET_PROTOCOL` → **v2**, with USB debugging off |
| Note Air 3: Android 12, 4 096 pressure levels | **Verified (sourced)** | not observed; no Note Air 3 available |

## 3. Stylus input (hardware verified on the Note Air 2 Plus)

Kernel device `onyx_emp_Wacom I2C Digitizer` (`/dev/input/event3`, vendor `0x2d1f`,
product `0x012b`), read with `getevent -pl`, plus the app's `StylusCapabilityProbe`
and a 90 s raw `getevent -lt` capture while writing.

| Capability | Result |
|------------|--------|
| Raw axes | `ABS_X` 0–20966, `ABS_Y` 0–15725 (landscape-native panel), `ABS_PRESSURE` 0–4095, `ABS_DISTANCE` 0–255 (hover height), `ABS_TILT_X/Y` −63…63 |
| Android axes (`MotionRange`) | X 0–1403, Y 0–1871, **pressure 0–1 (normalized)**, orientation ±π, distance 0–255, tilt 0–π/2 |
| Range source | ⚠️ reported under `SOURCE_TOUCHSCREEN \| SOURCE_STYLUS` (`0x5002`), not `SOURCE_STYLUS`. An exact-source lookup returns nothing; this caused a bug (pressure advertised as absent), now fixed |
| Report rate | **360 Hz** (median 2.77 ms) in contact **and** hovering |
| Pressure | full range used: raw 0 … 4095, median 3376 while writing; meaningful and smooth |
| Tool type | the pen reports `BTN_TOOL_BRUSH`, which Android maps to `TOOL_TYPE_STYLUS` |
| Eraser | kernel declares `BTN_TOOL_RUBBER`, but **none was seen** in use (the test pen has no eraser end) |
| Stylus buttons | kernel declares `BTN_STYLUS`/`BTN_STYLUS2`; **none seen** while testing |
| Hover | yes (`ABS_DISTANCE`, hover reports at 360 Hz) |
| Tilt | yes (raw ±63 per axis) |
| Extra key `0x152` | toggles with each stroke; ONYX-specific, meaning unknown, ignored |
| Touchscreen | `cyttsp5_mt` also advertises stylus-capable sources; finger rejection uses tool type, which works |
| Standard MotionEvent sufficient? | **Yes**: all samples arrive (5 361 points in 42 strokes, 0 lost). The ONYX SDK is **not needed for capture** |

## 4. Connectivity

| Path | Status | Result |
|------|--------|--------|
| `adb reverse` USB tunnel | **Verified (hardware)** | tablet `127.0.0.1:8765` → Mac loopback listener; tablet shows "● Armin's MacBook Pro via USB" |
| Wi-Fi TCP to Mac + pairing | **Pending** on tablet; verified simulator → Mac LAN IP | |
| Bonjour discovery from tablet | **Pending**; advertisement verified with `dns-sd -B` | |
| Native USB (AOA) | handshake step 1 **verified**; transport not implemented | see usb-research.md |

## 5. Latency (hardware, USB via adb reverse)

Measured with `inkbridge-probe`. "On tablet" = sample event time → message send time,
both on the tablet clock. "Transport" = send → Mac receive, via the ping clock-offset
estimate.

| Configuration | Pen → Mac p50 / p95 / p99 | On tablet p50 / p95 | Transport p50 / p95 |
|---------------|---------------------------|---------------------|---------------------|
| Local ink **on** (tablet draws ink too) | 17.1 / 59.4 / 83.8 ms | 12.9 / 54.2 ms | 2.4 / 10.9 ms |
| Local ink **off** | **5.0 / 16.0 / 25.0 ms** | 2.7 / 10.8 ms | 2.1 / 6.8 ms |
| Local ink **on**, render thread (v2, injected strokes) | **6.4 / 14.9 / 23.3 ms** | 3.2 / 7.1 ms | 2.9 / 9.4 ms |
| Mac ingest (decode → store) | 0.05–0.08 ms p50 | | |
| RTT | 2.6–15 ms | | |

**Finding:** drawing ink on the e-ink panel *from the UI thread* delays pen events
3–5× at the tail. **Fixed** by rendering on a dedicated thread with dirty-rect updates
(ADR-006). Local ink is on by default again at no latency cost. Input-to-visible on the
Mac ≈ pen→Mac + ≤ 1 display frame (8–17 ms) ≈ **13–33 ms typical**, comfortably
under the 50 ms target. The first measurement session showed a p95 of ~600 ms, from
connection warm-up and a not-yet-converged clock estimate. Treat measurements from the
first seconds of a connection with caution.

## 6. Security considerations

- adb grants broad device control. It is developer-only.
- LAN mode is authenticated but not encrypted yet (see security.md).
- `repo.boox.com` serves the SDK over plain HTTP. Avoid, or vendor-verify, if the SDK
  is ever adopted.
- BOOX disabled the InkBridge package once (`enabled=3`, disabled-user) between
  installs. Re-enabled with `pm enable`. The trigger is unknown (possibly BOOX app
  management). Watch for it.

## 7. Recommendation

1. **Standard MotionEvent input is sufficient**: 360 Hz, full pressure, tilt and
   hover. The ONYX pen SDK is only worth adding for *fast local ink on the tablet*
   (its raw-drawing mode renders through the EPD without the UI thread), which is
   optional for this product.
2. **USB:** `adb reverse` works end to end. **AOA for production**, now known to be
   supported.
3. **Wi-Fi:** as implemented. Measure on hardware next, then add TLS + QR.

## 8. Open questions

1. Behaviour on an actual Note Air 3 (Android 12): same digitizer driver and rates?
2. The meaning of ONYX key `0x152`.
3. Does a pen with an eraser end or side buttons (e.g. a Pen2 Pro) produce `BTN_TOOL_RUBBER`/`BTN_STYLUS` through Android?
4. AOA: permission dialog behaviour and re-enumeration time.
5. Wi-Fi latency and power save on the tablet.
6. Can local ink be made cheap (ONYX raw drawing, or a SurfaceView off the UI thread) without hurting latency?
