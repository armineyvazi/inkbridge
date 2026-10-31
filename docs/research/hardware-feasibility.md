# Hardware feasibility report: BOOX Note Air 3

Last updated: 2026-10-31. Every statement is labelled **Verified (hardware)**,
**Verified (sourced)** (from vendor or retailer documentation, not observed), or
**Pending** (blocked on USB debugging being enabled on the test unit).

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

## 2. Device facts

| Fact | Status | Detail |
|------|--------|--------|
| Enumerates over USB-C | **Verified (hardware)** | `18d1:4ee1` "ONYX" / "BENGALP-IOT-IDP _SN:00E2B01C", bcdDevice 0x0419, high speed |
| USB function by default | **Verified (hardware)** | MTP only; no serial or CDC interface |
| Android 12 | **Verified (sourced)** | retailer listings, Android Central review. Exact API level pending (`ro.build.version.sdk`) |
| Wacom EMR digitizer, 4 096 pressure levels | **Verified (sourced)** | Android Central; "BOOX Pen Plus (4096 levels)" |
| Android Open Accessory | **Verified (hardware)** | `ACCESSORY_GET_PROTOCOL` → **v2**, with USB debugging off |
| USB debugging / adb | **Pending** | developer options off on the test unit |

## 3. Stylus input

Measured with the InkBridge app's diagnostics line and the *Device* report
(`StylusCapabilityProbe`), which lists every `InputDevice` motion range.

| Capability | Status | Result |
|------------|--------|--------|
| ACTION_DOWN/MOVE/UP from stylus | **Pending** | |
| ACTION_CANCEL occurrence | **Pending** | |
| `getToolType()` = STYLUS | **Pending** | |
| Pressure meaningful and stable (range, resting noise) | **Pending** | |
| Report rate (incl. historical samples) | **Pending** | |
| Historical samples per event | **Pending** | |
| Eraser (`TOOL_TYPE_ERASER`) | **Pending** | Pen Plus has no eraser end per product photos (unverified) |
| Stylus button (`BUTTON_STYLUS_PRIMARY`) | **Pending** | |
| Hover events | **Pending** | |
| Tilt (`AXIS_TILT`) | **Pending** | |
| Dispatch lag (event time → app) | **Pending** | |

## 4. Connectivity

| Path | Status | Result |
|------|--------|--------|
| `adb reverse` USB tunnel | **Pending** | |
| Wi-Fi TCP to Mac + pairing | **Pending** on tablet; **verified** simulator → Mac LAN IP | |
| Bonjour discovery from tablet | **Pending**; advertisement **verified** with `dns-sd -B` on the Mac | |
| Native USB (AOA) | handshake step 1 **verified**; transport not implemented | see usb-research.md |

## 5. Latency

| Segment | Simulator → Mac (loopback) | Tablet USB | Tablet Wi-Fi |
|---------|----------------------------|------------|--------------|
| RTT | 0.4–1.5 ms | **Pending** | **Pending** |
| Pen sample → Mac receive (p50 / p95 / p99) | 0.44 / 0.83 / 1.48 ms (USB path), 0.32 / 0.63 / 0.97 ms (LAN path) | **Pending** | **Pending** |
| Mac ingest (decode → store) p50 / p99 | 0.06–0.10 / 0.15–0.37 ms | | |
| Tablet process + encode per MotionEvent | 1.9–2.5 µs (JVM benchmark) | **Pending** (on-device) | |

The 50 ms input-to-visible target leaves room for: digitizer + Android input
(unknown, pending), transport (~1 ms USB expected), Mac ingest (< 0.5 ms), and up to
one display frame (8.3 ms at 120 Hz ProMotion, 16.7 ms at 60 Hz).

## 6. Security considerations

- adb grants broad device control. It is developer-only.
- LAN mode is authenticated but not encrypted yet (see security.md).
- `repo.boox.com` serves the SDK over plain HTTP. Avoid, or vendor-verify, if the SDK
  is ever adopted.

## 7. Recommendation

1. Proceed with **standard MotionEvent** input. Adopt the ONYX SDK only if the
   pending stylus checks fail (see boox-sdk-analysis.md for the decision rule).
2. **USB:** `adb reverse` for development. **AOA for production**, now known to be
   supported by this device's USB stack.
3. **Wi-Fi:** TCP + Bonjour + pairing challenge, as implemented. Add TLS with
   fingerprint pinning (QR) before calling Wi-Fi production-ready.

## 8. Open questions

1. Does the BOOX firmware batch or throttle MotionEvents for apps not using raw drawing?
2. Does `requestUnbufferedDispatch` change the report rate on this device?
3. Is `MotionEvent.getPressure()` normalized to 0…1, or raw (0…4095)?
4. Does the Pen Plus expose any button or eraser signal?
5. AOA: does the BOOX show the standard accessory permission dialog? How long does
   re-enumeration take?
6. Wi-Fi power save: first-packet latency after idle, and whether a low-latency
   WifiLock helps.
