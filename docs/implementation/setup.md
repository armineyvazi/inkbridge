# Setup: build and run

## Prerequisites

| Tool | Version used | Notes |
|------|--------------|-------|
| macOS | 13+ (developed on 27.2) | ScreenCaptureKit screenshots need 14+ |
| Xcode / Swift | Xcode 27.1, Swift 6.4 | command-line tools are enough for `swift build` |
| JDK | **17** | `apps/android/Makefile` pins it, so a different `JAVA_HOME` is fine |
| Android SDK | platform 34, build-tools 34 | `brew install --cask android-commandlinetools`, then set `sdk.dir` in `apps/android/local.properties` |
| adb | any recent | `brew install --cask android-platform-tools` |

The Gradle wrapper (8.11.1) downloads itself. No global Gradle is needed.

Build output goes to `~/Library/Caches/InkBridge/` on purpose: inside a Dropbox or
iCloud folder, `codesign` fails on synced extended attributes.

## macOS host

```bash
cd apps/macos
make test        # unit + integration tests (62)
make app         # → ~/Library/Caches/InkBridge/macos-build/InkBridge.app
make install     # copy to /Applications (Spotlight, Launchpad, privacy settings)
make run         # install and open
```

InkBridge runs in the menu bar (pen icon). The toolbar appears at the bottom of the
selected display. The first Wi-Fi use triggers the macOS **Local Network** prompt:
allow it.

### macOS permissions

| Permission | Needed for | Where |
|------------|-----------|-------|
| Local Network | Wi-Fi mode (Bonjour + LAN listener) | prompted automatically; System Settings → Privacy & Security → Local Network |
| Screen & System Audio Recording | **only** "Include a screenshot when saving" | System Settings → Privacy & Security → Screen & System Audio Recording → **+** → `/Applications/InkBridge.app` |
| Accessibility | not needed (hot keys use Carbon) | — |

The app is ad-hoc signed, so macOS may treat each rebuild as a new app and forget a
granted permission. Re-toggle it after `make install` if screenshots stop working.

## Android app

```bash
cd apps/android
make test        # :core JVM tests
make apk         # debug APK
make install     # adb install -r
```

## Connect over USB (development)

1. On the BOOX: **Settings → About tablet → tap *Build number* 7×**, then
   **Developer options → USB debugging: on**. Replug and tap **Allow** on the
   "Allow USB debugging?" prompt.
2. On the Mac: `scripts/adb-usb.sh`. Use `scripts/adb-usb.sh --watch` to reapply
   automatically after every replug.
3. Start InkBridge on the Mac, then InkBridge on the tablet. Mode USB is the default.
4. Write on the tablet. Ink appears over the Mac's screen.

## Connect over Wi-Fi

1. Mac and tablet on the same network. On the Mac, the menu bar shows
   *Wi-Fi pairing code: XXXX-XXXX*.
2. On the tablet: **Settings → Wi-Fi**. The Mac's address fills in automatically
   through Bonjour, or type it (`ipconfig getifaddr en0`). Enter the pairing code,
   then Save.

## Without hardware

```bash
scripts/e2e.sh        # Kotlin simulator → Swift probe over loopback (USB path)
scripts/e2e.sh wifi   # same over the Mac's LAN IP with pairing
make -C apps/android simulate ARGS="--strokes 20"   # draw into a running InkBridge.app
```
