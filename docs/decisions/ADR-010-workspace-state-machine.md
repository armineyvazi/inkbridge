# ADR-010: Derive a single Workspace from the existing flags; refuse illegal transitions

- **Status:** accepted (2026-11-02)
- **Related:** ADR-006, `docs/architecture/macos-interaction-model.md`, Obsidian `02-Architecture/Screen Lifecycle.md`

## Context

Overlay / Studio / Engineering / Journal / Hide-ink were independent flags. Window policy was derived in more than one place and could disagree, producing contradictory states (Engineering left on after Journal Done; Esc flipping a Journal page to Overlay; Hide ink leaving a click-catching window; New session while Journal open writing into the day folder).

## Decision

- Pure `Workspace` / `WorkspaceSurface` in `InkBridgeCore` (`Workspace.swift`), resolved with priority **Journal > Engineering > Studio/Overlay**.
- `InkCoordinator.workspace` drives interaction policy; illegal writes are refused at the setters (`setBackground`, storage session changes, Engineering pointer force).
- Mode changes call `cancelGestures()`; Hide ink `orderOut`s the window; panel close buttons call the same leave paths as hotkeys.
- Tablet undo/redo/clear runs the same side effects as a local edit.

## Consequences

New surfaces extend `WorkspaceSurface` + `resolve`. Existing flag writers remain; they must use the guarded setters.
