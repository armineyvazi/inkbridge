#!/usr/bin/env bash
# Cross-language end-to-end test without hardware: the Kotlin simulator (same
# StrokeProcessor + InkBridgeClient as the Android app) streams strokes to the
# Swift inkbridge-probe (same InkServer + StrokeStore as the Mac app).
#
#   scripts/e2e.sh          USB path (loopback :8765, as adb reverse delivers it)
#   scripts/e2e.sh wifi     Wi-Fi path: TLS on the LAN address :8766, pairing with a
#                           one-time code, then a dropped link that must recover
#                           with the device token
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:-usb}"
STROKES=6
CODE="E2E4-TEST"
LOG="$(mktemp -t inkbridge-probe)"

for port in 8765 8766; do
  if lsof -nP -iTCP:$port -sTCP:LISTEN >/dev/null 2>&1; then
    echo "port $port is in use (InkBridge app or another probe running?); stop it first" >&2
    exit 2
  fi
done

make -s -C "$ROOT/apps/macos" release >/dev/null
PROBE="$HOME/Library/Caches/InkBridge/macos-build/release/inkbridge-probe"
EXPECT=(--expect-strokes "$STROKES")
[ "$MODE" = wifi ] && EXPECT+=(--expect-pairings 1)
"$PROBE" --seconds 25 --code "$CODE" "${EXPECT[@]}" >"$LOG" 2>&1 &
PROBE_PID=$!
trap 'kill $PROBE_PID 2>/dev/null || true' EXIT
sleep 1

if [ "$MODE" = wifi ]; then
  HOST="$(ipconfig getifaddr en0 || ipconfig getifaddr en1 || echo 127.0.0.1)"
  ARGS="--wifi $HOST --code $CODE --strokes $STROKES --reconnect"
else
  ARGS="--strokes $STROKES"
fi
make -s -C "$ROOT/apps/android" simulate ARGS="$ARGS"

wait $PROBE_PID && STATUS=0 || STATUS=$?
trap - EXIT
cat "$LOG"
exit $STATUS
