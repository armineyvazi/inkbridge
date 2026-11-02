# AI implementation roadmap (proposed)

Adjust against the live product roadmap in
[../../implementation/roadmap.md](../../implementation/roadmap.md).
**Phase 0 (docs + ADRs) is the only AI phase started.**

| Phase | Focus | Depends on |
|-------|--------|------------|
| **0** | Documentation, ADRs, diagrams | — |
| **1** | Document identity, PDF page model, region mapping; keep vector ink | Storage / canvas |
| **2** | OCR/HTR, layout, associations, confidence UI | Phase 1 |
| **3** | Context Builder + preview + budgets | Phase 1–2 (1 alone for surrogate) |
| **4** | Provider Hub, OpenRouter, Keychain/Keystore, streaming panels, usage | Phase 3 |
| **5** | Knowledge Library (Save Answer, search, export) | Phase 4 |
| **6** | Claude Code CLI adapter | Phase 3 |
| **7** | Cursor CLI adapter (+ optional SDK bridge later) | Phase 3 |
| **8** | Advanced workflows, eval sets, cross-doc relations | Phase 2–5 |

## Optional early vertical slice

OpenRouter + canvas PNG / stroke JSON context + Mac streaming panel + explicit
save — **before** full PDF import — labeled as surrogate Source. Unlocks Hub
UX learning without blocking on HTR.

## Parallelism

- Phases 6–7 can track beside 4–5 once Context Builder exists.  
- Phase 2 can start with geometry-only relations before full HTR.  
- Credential store can land with Phase 4 skeleton.
