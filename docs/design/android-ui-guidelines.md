# Android UI guidelines

InkBridge on the BOOX is a drawing surface for a Mac. The UI exists to get the user to a connected canvas, and then to stay out of the way.

## Principles

1. **One obvious next step.** Every screen has at most one solid-black button.
   - On the dashboard it changes with the state: Connect to Mac → Open canvas → Try again / Pair again.
2. **The canvas is the product.** It is full-screen. Controls are a slim floating bar that can be hidden.
3. **Words with every state.** Status is shown by shape *and* text, never by colour (the panel has none).
4. **Calm screens.** Nothing animates, values update only when they change, and latency is never streamed into the UI. Each redraw is an e-ink refresh.
5. **Technical detail lives in Diagnostics**, not on the main screens.

## Navigation

```
Dashboard (launcher)
 ├─ Open canvas ─────────▶ Canvas ── ⋮ ─▶ Settings / Diagnostics
 ├─ Connect to Mac ──────▶ Connect: list → code → done ──▶ Canvas
 │                          ├─ Enter the Mac's address
 │                          └─ Use a USB cable instead
 ├─ Settings ────────────▶ Connection · Drawing · Display · Application
 └─ Diagnostics
inkbridge://pair?… ──────▶ Connect (code pre-filled, certificate pre-pinned)
```

Screens are separate activities with no transition animations (`InkActivity`). The connection lives in the app-scoped `ConnectionManager`, so moving between screens never drops it.

## Screens

| Screen | Content | Primary action |
|---|---|---|
| Dashboard | Status card (mark, title, explanation, Mac, connection, last connected), drawing card (canvas, stylus, ink), links | Depends on state |
| Connect | Instructions; discovered Macs; Search again; manual address; USB. Then the code entry, then the done screen | Pair / Start drawing |
| Canvas | Full-screen ink; top-left chip (back + stage); top-right bar (undo, redo, −, %, +, fit, ⋮) | — |
| Settings | Four sections with toggles and segmented controls, applied immediately | — |
| Diagnostics | Monospaced report: state, address, pins, RTT, counters, Wi-Fi, discovery, digitizer | — |

Rendered screenshots: `make -C apps/android screenshots` writes them to `~/Library/Caches/InkBridge/screenshots`. Hardware captures are listed in [../testing/android-ui-tests.md](../testing/android-ui-tests.md).

## Typography and spacing

- **Type scale (sp):**
  - Display 34 bold
  - Title 24 bold
  - Heading 19 bold
  - Body 17
  - Caption 14 (dark grey)
  - Settings → Text size → Large multiplies every size by 1.15.
- **Spacing:** a 4 dp grid, with steps of 4, 8, 16, 24, 32 and 48.
- **Page margins:** 32 dp. Content is capped at 720 dp wide and centred.
- **Touch targets:** at least 56 dp; 48 dp inside the canvas bar.

## Colour and contrast

| Token | Value | Use |
|---|---|---|
| INK | #000000 | Text, borders, primary buttons, icons |
| PAPER | #FFFFFF | Backgrounds |
| GREY | #404040 | Secondary text (still solid on Carta panels) |
| RULE | #B0B0B0 | Hairlines only, never text |
| PRESSED | #D8D8D8 | Pressed state |

The UI has no shadows, gradients, or colour-only meaning.

## Icons

There are 16 icons, drawn for this app on a 24 dp grid with 2 dp round strokes and no fills (`res/drawable/ic_*.xml`). They are tinted, never recoloured by hand, and always come with a label or `contentDescription`.
