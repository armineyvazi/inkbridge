# E-ink design considerations

Verified on a BOOX Note Air 2 Plus: Android 11, 1404×1872 at 227 ppi, Carta panel. The Note Air 3 has the same panel resolution and Android 12; its behaviour is expected to match, but that is unverified.

| Property of e-ink | Consequence in InkBridge |
|---|---|
| Every screen update is a panel refresh (~100–450 ms) with possible ghosting | No animations, no transitions (`overridePendingTransition(0,0)`, `windowAnimationStyle=@null`). Text views update only when their value changes (`Ink.setText`/`setValue`). The canvas chip changes only on *stage* changes, never per latency sample |
| Partial refresh is cheap; full refresh is expensive but cleans ghosts | Ink is drawn incrementally into a cached bitmap and posted with `lockCanvas(dirtyRect)`, so writing never triggers a full refresh. A full redraw happens only on zoom/pan end or document changes |
| Ghosting accumulates | **Clean refresh:** a one-frame black cover (~120 ms) forces a full waveform. It runs automatically after Clear and Fit (Settings → Display), and manually from ⋮ → Refresh screen or Settings → Refresh screen now |
| Greys are dithered and look dirty | Pure black on white. One dark grey (#404040) for secondary text; light grey only for hairlines. Status uses shape: filled dot, ring with centre, open ring, and an inverted "!" square |
| Colour panels (Kaleido) are dim; the Note Air is monochrome | Ink on the tablet is black, and highlighter is grey. Colour is shown on the Mac only |
| Gestures redraw continuously | Pinch and pan transform the cached bitmap at most ~20 fps, and the real render happens once at gesture end |
| Stylus latency matters more than UI latency | The renderer runs on its own thread. Pen input goes to the network before the local mirror. Measured over USB earlier: on-tablet p95 7.1 ms |

## BOOX-specific APIs

The Onyx SDK (`EpdController`, refresh modes, raw pen drawing) can force A2 or DU waveforms and draw ink in the panel controller. It is **not used**:

- Its compatibility with the Note Air 3 firmware has not been verified.
- It needs Onyx's Maven repository and hidden APIs.
- The standard-Android approach above already meets the latency target.

Users can still pick a faster refresh mode for InkBridge in BOOX's per-app optimisation menu, and the app works in all modes. If the Onyx SDK is adopted later, it belongs behind an interface in `features/canvas`, with a fallback to the current renderer.
