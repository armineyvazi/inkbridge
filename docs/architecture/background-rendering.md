# Background rendering

| Where | How |
|---|---|
| Mac overlay (`OverlayView`) | Each `draw(dirtyRect)` first draws the background layer for that rect only: `BackgroundRenderer.draw` fills it (studio) and strokes the pattern lines. Then come the cached stroke bitmap and the live strokes. The stroke cache never contains the background, so switching backgrounds does not re-render ink: a background change costs one full-view repaint of a solid fill and lines |
| Mac window (`OverlayWindow.setStudio`) | Studio: opaque, and **catches clicks**, so clicks never land on apps hidden underneath. Overlay: transparent and click-through, as before. The toolbar panel sits above in both modes |
| Export (`SessionArchive`) | `background/background.json` (the definition) is always written. `background/canvas-background.png` is written when there is anything to draw. `annotations/annotations.png` is **always transparent**. `full-page.(png\|jpg)` and the new vector `full-page.pdf` composite the layers in order: screenshot (overlay mode only) → background → strokes. In studio mode no screenshot is taken |
| Tablet (`CanvasRenderer`) | A full redraw fills with `CanvasBackground.einkPaper`, the colour's luminance quantised to the 16 e-ink greys, snapped to pure white (L ≥ 0.9) or pure black (L ≤ 0.2). Pattern lines are drawn from the shared spacing, but skipped when closer than 8 screen px. On dark paper the ink is drawn white. The stored colour is never changed; only the preview is monochrome |
| Tablet refresh | Changing the background triggers one full redraw (it changes every pixel). A black ⇄ white flip adds one clean-refresh flash to remove ghosting. Writing afterwards stays incremental, using dirty rects |

Line density guard: lines closer than 6 pt on the Mac or 8 px on the tablet are not drawn, because at low zoom a grid becomes a grey wash and makes e-ink refreshes slower.
