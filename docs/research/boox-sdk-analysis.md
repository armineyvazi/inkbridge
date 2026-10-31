# BOOX (ONYX) SDK analysis

Sources, read 2026-10-31:

- [onyx-intl/OnyxAndroidDemo](https://github.com/onyx-intl/OnyxAndroidDemo):
  Apache-2.0 repository; `doc/Onyx-Pen-SDK.md`; the `app/OnyxPenDemo` module
- [alexdremov/notate](https://github.com/alexdremov/notate): MIT, a BOOX note-taking
  app built on the ONYX SDK

## What the pen SDK offers

`com.onyx.android.sdk:onyxsdk-pen`. The SDK doc names **1.4.11**; the repository
README still shows 1.2.1. Artifacts are served from `http://repo.boox.com/repository/maven-public/`
(**plain HTTP**, which needs an explicit Gradle opt-in and is a supply-chain concern).

```java
TouchHelper.create(view, rawInputCallback)
    .setStrokeWidth(3.0f)
    .setLimitRect(limit, excludeRects)
    .openRawDrawing();
touchHelper.setRawDrawingEnabled(true);        // "screen will not refresh"
touchHelper.setRawDrawingRenderEnabled(false); // disable SDK-side ink rendering
touchHelper.closeRawDrawing();
```

`RawInputCallback`:

- `onBeginRawDrawing(boolean, TouchPoint)`
- `onRawDrawingTouchPointMoveReceived(TouchPoint)`
- `onRawDrawingTouchPointListReceived(TouchPointList)`
- `onEndRawDrawing(boolean, TouchPoint)`
- the same four for erasing (`onBeginRawErasing` …), "triggered by stylus eraser button"

Pressure rendering helper: `BrushRender.drawStroke(canvas, paint, points, width, maxTouchPressure)`
with `EpdController.getMaxTouchPressure()`. This suggests `TouchPoint.pressure` is in
**raw digitizer units**, not 0…1. Unverified.

## Why it exists

E-ink cannot refresh at pen rate through the normal Android view pipeline. "Raw
drawing" lets the EPD controller paint ink straight to the panel (Notate: "writes
directly to the hardware frame buffer"). That makes **on-tablet** ink feel
instantaneous, while freezing normal screen refresh in the drawing region.

## Does InkBridge need it?

InkBridge's latency-critical output is on the **Mac**, not the e-ink panel. The
questions are:

| Question | Standard MotionEvent | ONYX pen SDK |
|----------|----------------------|--------------|
| Pen position, pressure, timestamps | yes (pending hardware check of rate and pressure) | yes |
| Historical (batched) samples | yes | `TouchPointList` per stroke |
| Eraser end or button | `TOOL_TYPE_ERASER` / `BUTTON_STYLUS_PRIMARY` (pending) | explicit erase callbacks |
| Fast on-tablet ink | no (normal e-ink refresh) | yes |
| Works on non-BOOX Android | yes | no |
| Dependency risk | none | closed-source AAR over HTTP; API stability across firmware unknown |

**Decision rule** (Phase 0): use `AndroidMotionEventSource` unless the hardware tests
show missing pressure, a much lower report rate than the digitizer supports, or no
eraser signal. If one of those fails, add `OnyxStylusInputSource` behind the
existing `StylusInputSource` interface, in a separate Gradle module so the core never
depends on it. Local ink on the tablet is optional feedback; the user looks at the Mac.

## Compatibility notes

- Do not assume every BOOX model exposes the same SDK behaviour. The demo repo has
  per-device workarounds.
- `setRawDrawingEnabled(true)` stops screen refresh in the limit rect. Status text
  inside that rect would freeze, so the diagnostics line must stay outside it.
- Licence: the demo repository is Apache-2.0. The SDK AARs carry no separate licence
  in the repo; check before shipping.
