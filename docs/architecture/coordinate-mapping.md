# Coordinate mapping

Four coordinate spaces, and the code that converts between each pair:

```mermaid
flowchart LR
  A["Tablet view px<br/>(origin top-left, current orientation)"] -->|CoordinateNormalizer<br/>÷ width, ÷ height, clamp, round 1e-5| B["Normalized 0..1<br/>(on the wire)"]
  B -->|CoordinateMapper.calibration<br/>(x − ox)·sx, (y − oy)·sy| C["Calibrated 0..1"]
  C -->|CoordinateMapper.activeRect<br/>aspect fit or stretch| D["Overlay points<br/>(AppKit, top-left, flipped view)"]
  D -->|window server × backingScaleFactor| E["Display pixels"]
```

## 1. Tablet: px → normalized (Android)

`x_n = clamp(x / viewWidth, 0, 1)`, and likewise for y. The reference is the **drawing
view**, not the physical panel. The status bar and the app's top bar are excluded, so
the whole visible drawing area maps to the whole target. Rotation changes the view
size, and the tablet sends `device.surface`. The digitizer's own coordinate space is
already mapped to view pixels by Android.

## 2. Calibration (Mac)

`Calibration { offsetX, offsetY, scaleX, scaleY }`, identity by default, applied in
normalized space. It corrects a consistent offset or scale error, and is persisted
with each session. **A calibration wizard (tap four targets, solve for the transform)
is not implemented yet.** The data model and the mapping are in place and tested.
A four-point solve would also give rotation and shear; that would mean extending
`Calibration` to a full 2×3 affine transform.

## 3. Fitting to the display (Mac)

The target canvas is the selected display's frame, in points.

- **Aspect fit** (default): `scale = min(W/w, H/h)`, centered. Shapes keep their
  proportions: a circle drawn on the tablet stays a circle. A portrait Note Air 3
  (1404 × 1872, 3:4) on a 16:10 display maps to a centred band using the full height.
  Rotate the tablet to landscape to cover most of the screen.
- **Stretch**: the tablet fills the whole display, and shapes distort by the ratio of
  the two aspect ratios.

`activeRect` is the canvas region in use. Out-of-range points clamp to it.

## 4. Points → pixels

The overlay draws in AppKit **points**, and the window server applies the display's
`backingScaleFactor`, so Retina needs no special handling. The committed-ink cache is
rendered at `backingScaleFactor` so it stays sharp.

## Multiple displays

- Settings → *Draw on* lists every `NSScreen` with its stable `CGDirectDisplayID`.
- The overlay window is placed on that screen's `frame`. Each screen has its own
  points coordinate space, so no global desktop arithmetic is needed.
- On `didChangeScreenParametersNotification` (plug or unplug, resolution change,
  arrangement change) the overlay is moved and the mapper rebuilt. Because strokes are
  normalized, **existing ink remaps** to the new size instead of being lost or cropped.
- If the selected display disappears, InkBridge falls back to the main display.

Rotated external displays need nothing special: AppKit reports the rotated frame.
This has **not been hardware tested**.

## Tests

`CoordinateMapperTests`: stretch corners, portrait-on-landscape letterbox, landscape
fit, clamping, calibration. `CoordinateNormalizerTest`: normalize, clamp, rounding,
resize on rotation.
