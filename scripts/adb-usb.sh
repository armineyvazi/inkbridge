#!/usr/bin/env bash
# Sets up the development USB transport: forwards the tablet's 127.0.0.1:8765
# to this Mac's localhost:8765, where InkBridge's loopback listener runs.
# adbd drops reverse rules when the cable is unplugged or adbd restarts, so
# rerun this after replugging (or use --watch to reapply automatically).
set -euo pipefail
PORT="${PORT:-8765}"

apply() {
  adb reverse "tcp:$PORT" "tcp:$PORT" >/dev/null
  echo "$(date +%T) adb reverse tcp:$PORT → Mac localhost:$PORT ($(adb get-serialno))"
}

if ! adb get-state >/dev/null 2>&1; then
  echo "No device. On the BOOX: Settings → About → tap Build number 7×, then Developer options → USB debugging; replug and allow this computer." >&2
  [ "${1:-}" = "--watch" ] || exit 1
fi

if [ "${1:-}" = "--watch" ]; then
  while true; do
    adb wait-for-usb-device
    apply
    # Block until this device goes away, then loop to reapply on the next connect.
    while adb get-state >/dev/null 2>&1; do sleep 1; done
    echo "$(date +%T) device disconnected"
  done
else
  apply
  adb reverse --list
fi
