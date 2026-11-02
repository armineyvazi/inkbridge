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
# Cold Gradle on CI can take minutes; keep the probe alive long enough.
PROBE_SECONDS="${E2E_SECONDS:-25}"
if [ "${CI:-}" = "true" ]; then
  PROBE_SECONDS="${E2E_SECONDS:-180}"
fi

for port in 8765 8766; do
  if lsof -nP -iTCP:$port -sTCP:LISTEN >/dev/null 2>&1; then
    echo "port $port is in use (InkBridge app or another probe running?); stop it first" >&2
    exit 2
  fi
done

# Build both sides before opening the listen window so cold tooling cannot
# outlive the probe (common on GitHub Actions macos runners).
make -s -C "$ROOT/apps/macos" release >/dev/null
(
  cd "$ROOT/apps/android"
  ./gradlew --no-daemon :simulator:classes >/dev/null
)

PROBE="$HOME/Library/Caches/InkBridge/macos-build/release/inkbridge-probe"
EXPECT=(--expect-strokes "$STROKES")
[ "$MODE" = wifi ] && EXPECT+=(--expect-pairings 1)
# Background sync both ways: the tablet asks for black, later the Mac switches to white with graph paper.
EXPECT+=(--push-background white:graph@4)
"$PROBE" --seconds "$PROBE_SECONDS" --code "$CODE" "${EXPECT[@]}" >"$LOG" 2>&1 &
PROBE_PID=$!
trap 'kill $PROBE_PID 2>/dev/null || true' EXIT

# Wait until the USB listen port is open (probe startup is not instantaneous).
for _ in $(seq 1 60); do
  if lsof -nP -iTCP:8765 -sTCP:LISTEN >/dev/null 2>&1; then
    break
  fi
  if ! kill -0 "$PROBE_PID" 2>/dev/null; then
    echo "inkbridge-probe exited before listening:" >&2
    cat "$LOG" >&2
    exit 1
  fi
  sleep 0.25
done
if ! lsof -nP -iTCP:8765 -sTCP:LISTEN >/dev/null 2>&1; then
  echo "inkbridge-probe did not open :8765 in time:" >&2
  cat "$LOG" >&2
  exit 1
fi

if [ "$MODE" = wifi ]; then
  HOST="$(ipconfig getifaddr en0 || ipconfig getifaddr en1 || echo 127.0.0.1)"
  ARGS="--wifi $HOST --code $CODE --strokes $STROKES --reconnect --set-background black"
else
  ARGS="--strokes $STROKES --set-background black"
fi
make -s -C "$ROOT/apps/android" simulate ARGS="$ARGS"

wait $PROBE_PID && STATUS=0 || STATUS=$?
trap - EXIT
cat "$LOG"
exit $STATUS
