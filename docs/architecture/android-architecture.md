# Android architecture

```
apps/android/
├── core/        pure Kotlin/JVM library: no android.* imports
│   └── app/inkbridge/core/
│       ├── protocol/   Message, MessageCodec, Framing, FrameDecoder, PairingAuth
│       ├── input/      StylusEvent, StylusInputSource, StrokeProcessor,
│       │               CoordinateNormalizer, EventRateMeter
│       ├── transport/  Transport, TcpTransport, AdbReverseTransport,
│       │               WifiTcpTransport, ReconnectionPolicy
│       └── client/     InkBridgeClient, ClientState, DeviceDescriptor
├── app/         the Android application
│   └── app/inkbridge/android/
│       ├── MainActivity.kt
│       ├── input/      AndroidMotionEventSource, StylusCapabilityProbe
│       └── features/
│           ├── drawing/     DrawingSurfaceView, StylusDiagnostics
│           ├── connection/  ConnectionSettings, BonjourDiscovery
│           └── settings/    SettingsDialog
└── simulator/   JVM "virtual tablet" using :core
```

**Departure from the suggested layout.** The brief proposed separate Gradle modules
for `core/input`, `core/transport`, `core/protocol` and so on. They are **packages
in one `:core` module** instead. The boundary that matters is Android vs. pure JVM:
it lets about 30 tests run on the JVM in seconds without an emulator, and lets the
simulator reuse the exact client code. Splitting further would add build
configuration without decoupling anything new, because the packages already depend
in one direction only (`client → transport, protocol, input`).

## Input pipeline

`DrawingSurfaceView.onTouchEvent` → `AndroidMotionEventSource.onMotionEvent` →
`StrokeProcessor.process` → `InkBridgeClient.submit`.

- **Historical samples.** `AndroidMotionEventSource.samples()` returns every
  `getHistorical*` sample plus the current one, oldest first. Dropping them would
  make fast strokes polygonal.
- **Timestamps.** `getEventTimeNanos()` on API 34+, otherwise `getEventTime() × 10⁶`.
  Both use `CLOCK_MONOTONIC`, the same clock as `System.nanoTime()`. That shared clock
  is what makes the Mac's pen-to-host latency figure meaningful.
- **Pointer 0 only.** The pen is one pointer. `ACTION_POINTER_*` events are consumed
  and ignored.
- **Palm and finger rejection.** `TOOL_TYPE_FINGER` is ignored unless
  `acceptFinger` is set. A finger `UP` cannot end a pen stroke.
- **Eraser.** `TOOL_TYPE_ERASER`, or `BUTTON_STYLUS_PRIMARY` held at pen-down,
  starts an eraser stroke. Whether the BOOX pen reports either is **not yet verified**.
- **Repair.** `DOWN` while a stroke is active first ends the old stroke. `MOVE`/`UP`
  without `DOWN` is ignored. `CANCEL` emits `stroke.cancel`.
- **Batch limit.** Batches over 256 points are split to respect the protocol limit.

`StylusInputSource` is the seam for vendor input. `AndroidMotionEventSource` is the
only implementation. An `OnyxStylusInputSource` would be added only if hardware tests
show that standard MotionEvents are not good enough
(see [`research/boox-sdk-analysis.md`](../research/boox-sdk-analysis.md)).

## Coordinates

`CoordinateNormalizer` divides by the **drawing view's** current size, clamps to
0…1 and rounds to 1e-5. Rotation is handled by resizing: the manifest declares
`configChanges="orientation|screenSize…"`, so rotating calls `onSizeChanged` instead
of recreating the activity. The client then sends `device.surface`. Calibration is
done on the Mac, so the tablet stays a dumb sensor.

## Connection

`InkBridgeClient` is a loop of *connect → handshake → run → back off*:

- `transportFactory` builds a fresh, single-use `Transport` per attempt.
- The **outbox** (`Channel`, 4 096 messages) lives on the client, not the connection.
  Strokes drawn during a short outage are delivered after reconnecting. If the queue
  is full, events are dropped and counted (`droppedEvents`), never blocking the UI
  thread.
- `send()` assigns the sequence number and writes under one `Mutex`. Otherwise a
  concurrent pong could get a later number but reach the wire first, and the host
  would discard the earlier message as stale.
- `ReconnectionPolicy`: 250 → 500 → 1 000 → 2 000 ms (capped) with ±20 % jitter. The
  cap is low because the target is "reconnect within 3 s".
- A rejected pairing code puts the client in `Failed` with **no retry loop**, so
  a wrong code cannot trigger the host's lockout by itself.
- The connection lives between `onStart` and `onStop`. A drawing app is used in the
  foreground, and a background socket the user cannot see would be surprising.

## UI

Plain Views, no Compose or AppCompat: fewer dependencies, faster cold start, and
nothing animated (animations look bad on e-ink). Diagnostics text refreshes at most
4 times a second, because e-ink cannot redraw text at input rate. Local ink draws
only the new segments into a bitmap and invalidates just their bounds.

## Logging

`android.util.Log`, tag `InkBridge`. The device and digitizer report is logged on
launch (`adb logcat -s InkBridge`). Stroke contents are never logged.
