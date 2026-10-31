# ADR-004: Core Graphics rendering with a cached layer and dirty rects; Catmull-Rom smoothing

- Status: accepted
- Date: 2026-10-31

## Context

Ink must appear with minimal added latency and stay smooth and pressure-sensitive.
The brief says to start with Core Graphics and move to Metal only if profiling demands
it.

## Decision

- Core Graphics through `NSView.draw`. Committed strokes are rendered to a `CGImage`
  cache at backing scale, rebuilt only when `StrokeStore.revision` changes. Live
  strokes are drawn on top, and each new segment invalidates only its own bounds.
- Smoothing: decimate samples closer than 0.75 pt, then uniform Catmull-Rom converted
  to cubic Béziers. It interpolates through every sample, so it adds no lag.
- Pressure: width `w·(0.3 + 0.7p)` per segment with round caps. Highlighter: one
  constant-width path, so overlaps do not darken.
- Stroke-level eraser with segment–segment hit testing.

## Measurements

| | |
|---|---|
| Decode one `stroke.point` (debug build) | 8.5 µs |
| Map one point | 94 ns |
| Full render of a 2 000-point pressure stroke at 2× | 7.2 ms (only on cache rebuild) |
| Receive → `draw` completed (simulator → probe) | ingest p50 0.06–0.10 ms; overlay draw measured in-app |

## Consequences

- No GPU code to maintain. If a cache rebuild ever stalls very large sessions, the
  next step is tiled caches or incremental cache updates, before considering Metal.
- Variable-width segments can show faint joins on translucent pen colors. Pen colors
  are opaque, so this is acceptable.
