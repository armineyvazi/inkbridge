# Layers and objects (planned: Phases 3–4)

The design is fixed in [../architecture/shared-drawing-model.md](../architecture/shared-drawing-model.md); none of this is built yet.

- **Objects:** stroke, shape and text, each with an ID, a layer ID and a transform. Strokes stay point lists in canvas px; a transform is applied for move and resize, and baked in on commit so stored data remains plain coordinates.
- **Selection** (Phase 3): tap to select, lasso a polygon, move/resize/duplicate/delete/recolour. Each is one command in the history.
- **Layers** (Phase 4): create, rename, hide, lock, delete, reorder. The background stays a separate, non-layer object. Hidden layers are excluded from the composite export; "selected layer only" export is planned with them.
- **Shape recognition** (Phase 3): opt-in; converts a stroke to a line, rectangle or ellipse after pen-up when the fit error is below a threshold, and is undoable.
