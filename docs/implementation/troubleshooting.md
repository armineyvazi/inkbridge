# Troubleshooting

## The tablet says "USB: … retry"

- `adb devices` lists nothing → USB debugging is off, or the prompt was not accepted.
  See setup.md. On the Mac, `ioreg -p IOUSB | grep -i onyx` shows whether the cable
  carries data at all.
- `adb devices` shows `unauthorized` → unlock the tablet and accept the prompt.
- Listed, but the app keeps retrying → the reverse rule is missing (it is cleared on
  every replug). Run `scripts/adb-usb.sh`, or keep `scripts/adb-usb.sh --watch` running.
- Still retrying → is InkBridge running on the Mac? Check with
  `lsof -nP -iTCP:8765 -sTCP:LISTEN`.

## Tablet says "Wrong code", "Code expired", "Pair again" or "Mac identity changed"

- **Wrong code**: retype it; case and the dash do not matter. Five wrong codes void
  that code. Open Connect Device again for a new one.
- **Code expired**: codes live 5 minutes and work once, and only while Connect Device
  is open on the Mac. Reopen it (⌃⌥K).
- **Pair again**: the Mac forgot this tablet (Forget was pressed, or InkBridge's data
  on the Mac was reset). Pair again from Connect to Mac.
- **Mac identity changed**: the Mac's TLS certificate differs from the one the tablet
  pinned. Expected after deleting `~/Library/Application Support/InkBridge/Identity`.
  Otherwise, treat it as suspicious. Forget the Mac in the tablet's Settings and pair again.
- Repeated failures from one IP are locked out for 30 s (doubling on repeats);
up to 60 s.

## Wi-Fi: the tablet cannot find the Mac

- Same network? Guest and enterprise networks often block multicast (Bonjour) or
  isolate clients. Type the IP manually (`ipconfig getifaddr en0` on the Mac).
- macOS **Local Network** permission: System Settings → Privacy & Security → Local
  Network → InkBridge on.
- macOS firewall: allow incoming connections for InkBridge.

## Ink appears in the wrong place or is squashed

- Settings → *Tablet mapping*. "Keep tablet proportions" letterboxes; "Stretch" fills
  the screen.
- Rotate the tablet to landscape to match a landscape display.
- Wrong monitor → Settings → *Draw on*.

## Ink not shown over a full-screen app

Report it with the diagnostic report. The overlay uses `.screenSaver` level and
`.fullScreenAuxiliary`; some apps (games, video players in exclusive mode) may still
sit above it.

## Build problems

- `codesign … resource fork, Finder information, or similar detritus not allowed` →
  you are building inside Dropbox or iCloud with a `.build` dir there. Use the
  Makefile, which builds into `~/Library/Caches/InkBridge`.
- `Gradle requires JVM 17 or later` → use `make` in `apps/android`, which sets
  `JAVA_HOME` to JDK 17.

## Getting logs

```bash
# Mac
log stream --predicate 'subsystem == "app.inkbridge"' --level info
# Tablet
adb logcat -s InkBridge
# Diagnostic report: menu bar → Export Diagnostic Report
```
