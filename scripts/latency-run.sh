#!/bin/bash
# Writing-latency run on a connected BOOX (adb). Draws 60 injected stylus strokes on the
# canvas and prints the app's per-stage `perf` line (sample→posted, input, process,
# handoff, draw, lock, copy+post, CPU, heap, dropped samples).
#
#   scripts/latency-run.sh [0|1]   1 = old frame order (A/B, debug.inkbridge.legacyframe)
#
# Coordinates are for a 1404×1872 portrait screen (Note Air 2 Plus / Note Air 3).
# The strokes go into the Mac's CURRENT document: make sure that is a scratch session,
# not someone's Daily Journal, and remove it afterwards.
set -euo pipefail
adb shell setprop debug.inkbridge.legacyframe "${1:-0}"
adb shell pm enable app.inkbridge.android >/dev/null   # BOOX sometimes disables sideloaded apps
adb shell am force-stop app.inkbridge.android
adb shell input keyevent KEYCODE_WAKEUP
adb shell am start -n app.inkbridge.android/.features.dashboard.DashboardActivity >/dev/null; sleep 9
adb shell input tap 702 605; sleep 4                    # "Open canvas"
focus=$(adb shell dumpsys window | grep -m1 mCurrentFocus)
case "$focus" in *CanvasActivity*) ;; *) echo "canvas not in front: $focus" >&2; exit 1;; esac
adb logcat -c
for i in $(seq 1 60); do
  x=$((200 + (i % 8) * 130)); y=$((300 + (i / 8) * 200))
  adb shell input stylus swipe $x $y $((x + 110)) $((y + 150)) 250
done
sleep 2
adb logcat -d -s InkBridge | grep perf | tail -1 | sed 's/^.*perf //'
