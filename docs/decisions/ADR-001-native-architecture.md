# ADR-001: Two native apps, a shared wire protocol, and stroke events instead of pixels

- Status: accepted
- Date: 2026-10-31

## Context

The tablet has to act as an input device for arbitrary Mac content. The options:

1. **Screen mirroring**: stream the Mac screen to the tablet and send touches back
   (the Sidecar/Duet model).
2. **Stroke events**: the tablet sends pen samples, and the Mac renders ink natively
   over its own screen.
3. A cross-platform shell (Electron, Flutter, React Native) on one or both sides.

## Decision

Option 2, with a **native Kotlin app** on Android and a **native Swift/AppKit app**
on macOS. They share only a versioned JSON protocol, and both sides are tested
against the same fixtures.

## Consequences

- Bandwidth is about 20–40 KB/s while drawing instead of megabits of video. E-ink
  never has to show video, and the Mac shows full-resolution vector ink.
- Ink is editable: undo, erase, restyle, export as vectors.
- The tablet does **not** show the Mac's content. The user looks at the Mac and draws
  on the tablet, like a Wacom Intuos without a screen. That is the product brief, and
  it is the main UX trade-off.
- A transparent click-through overlay needs AppKit window-level control that a web
  shell does not provide cleanly. Low-level `MotionEvent` access, plus a possible
  vendor SDK, favours native Android.
- Two codebases, kept honest by shared protocol fixtures and the cross-language
  `scripts/e2e.sh`.
