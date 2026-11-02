# AI-native InkBridge (proposed)

> **Status:** design documentation only. No AI Provider Hub, OpenRouter client,
> OCR/HTR pipeline, Knowledge Library, Claude Code adapter, or Cursor adapter
> ships in the current product (verified against `main` as of 2026-11-03).

InkBridge today is a local-first BOOX ↔ Mac ink system: vector strokes, shared
canvas, Daily Journal, Engineering diagrams, TLS pairing, layered export.
The AI-native vision extends that into a **Knowledge and Engineering Workspace**
where the same page the user is reading and annotating can be asked about
through cloud providers or local coding agents — without leaving the app.

Three complementary interaction models:

1. **Cloud AI providers** (OpenRouter first) — in-app Provider Hub, Keychain/Keystore keys.
2. **Local coding agents** — Claude Code CLI (`claude -p`) and Cursor (`agent -p` / SDK).
3. **Future providers** — same adapter contracts; no vendor lock-in in core types.

## Read next

| Doc | Topic |
|-----|--------|
| [overview.md](overview.md) | Vision, implemented vs proposed, high-level architecture |
| [document-intelligence.md](document-intelligence.md) | Source / Ink / Semantic layers, HTR, relationships |
| [context-builder.md](context-builder.md) | Structured context packages |
| [provider-hub.md](provider-hub.md) | Hub UI, conversations, usage, macOS/Android panels |
| [openrouter.md](openrouter.md) | Verified OpenRouter API contracts |
| [credentials.md](credentials.md) | Keychain / Keystore design |
| [knowledge-library.md](knowledge-library.md) | Save Answer, provenance, search |
| [local-agents.md](local-agents.md) | Claude Code + Cursor feasibility |
| [security-privacy.md](security-privacy.md) | Consent, egress, retention |
| [ux.md](ux.md) | AI panel UX (Mac + BOOX e-ink) |
| [testing.md](testing.md) | Acceptance criteria and test strategy |
| [roadmap.md](roadmap.md) | Dependency-aware phases |
| [ADR-011](../../decisions/ADR-011-ai-provider-agnostic.md) | Provider-agnostic module |
| [ADR-012](../../decisions/ADR-012-secure-ai-credentials.md) | Credentials |
| [ADR-013](../../decisions/ADR-013-three-layer-document.md) | Document layers |

Diagrams: [`docs/diagrams/ai/`](../../diagrams/ai/).

Maintainer Obsidian vault: `07-AI/` (wikilinked narrative + Persian notes where needed).

Security baseline for the ink transport remains
[../security.md](../security.md). AI adds explicit cloud egress and credential rules.
