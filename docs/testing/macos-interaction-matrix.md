# macOS interaction matrix

Legend: ✅ verified (how) · ⏳ manual check pending · ⚠ known limitation.

| Scenario | Result |
|---|---|
| Overlay pointer mode: clicks reach apps underneath | ✅ policy unit test + self-test window flags (click-through) on 3 real displays; ⏳ a real click on YouTube |
| Overlay draw mode: the mouse draws, other displays stay usable, keyboard stays with the app | ✅ unit + self-test (flags, event routing); ⏳ by hand |
| Studio: click pans/draws, scroll pans, pinch zooms, Esc / ⌘Z / +/−/0 / D | ✅ event routing via self-test; ⏳ keyboard by hand |
| Studio never follows clicks to another monitor (the reported bug) | ✅ policy invariant test |
| Toolbar above overlay and studio | ✅ window levels (screenSaver+1 above screenSaver) |
| Toolbar stays centred | ✅ measured: centre 756 = screen centre |
| Built-in + 2 external displays (mixed scale, negative origin) | ✅ self-test 18/18 |
| Display disconnect / reconnect / primary change | ⏳ `didChangeScreenParameters` → relayout; fallback to the primary if the chosen display is gone |
| Full-screen apps / Spaces | ⏳ `.canJoinAllSpaces` + `.fullScreenAuxiliary` |
| Menu bar / Dock under the Studio Canvas | ⚠ the studio covers its display's menu bar and Dock area by design; use another display, Esc, or ⌃⌥B |
| Screen Recording denied → Save… | ✅ (earlier) explained in the save alert |
| Keyboard focus never taken in the overlay | ✅ `canBecomeKey == false` in both overlay modes (self-test) |
