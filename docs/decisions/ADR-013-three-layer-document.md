# ADR-013: Three-layer document model (Source / Ink / Semantic)

- **Status:** proposed (2026-11-03)
- **Related:** ADR-006 (canvas), ADR-011, `docs/architecture/ai/document-intelligence.md`

## Context

AI features need PDFs, handwriting, and interpretations. Collapsing everything
into screenshots or into stroke JSON alone loses either editability or meaning.

## Decision

1. Keep **Source** (original pages/media/text), **Ink** (vector strokes/diagrams),
   and **Semantic** (OCR/HTR/relations/AI/user corrections with provenance) separate.
2. Ink remains the primary editable annotation representation (already true today).
3. Context Builder reads all three; providers may **propose** Semantic objects;
   users confirm uncertain links.
4. Early demos may use canvas rasters as a **surrogate Source**, labeled honestly in UI.

## Consequences

- PDF import becomes Source Layer work, not a one-off chat feature.
- Semantic store needs confidence + provenance fields from day one.
- Export/sync must define which layers travel together.

## Rejected

- Replacing strokes with flattened images for AI.
- Treating model output as authoritative Source.
