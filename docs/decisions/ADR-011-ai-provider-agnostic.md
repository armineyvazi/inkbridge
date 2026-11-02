# ADR-011: Provider-agnostic AI integration module

- **Status:** proposed (2026-11-03)
- **Related:** ADR-012, ADR-013, `docs/architecture/ai/`

## Context

InkBridge will speak to cloud model routers (OpenRouter first) and local coding
agents (Claude Code, Cursor). Baking vendor SDKs into document or UI types would
freeze product evolution and risk leaking secrets into the wrong layers.

## Decision

1. Core document / ink / journal types remain free of AI vendor imports.
2. Introduce small consumer-defined interfaces, e.g. `AIProvider` (cloud chat) and
   `LocalAgent` (subprocess/SDK bridge), registered in a `ProviderRegistry`.
3. `ConversationManager` + `AIContextBuilder` sit above adapters.
4. OpenRouter is the first `AIProvider`; Claude Code and Cursor are `LocalAgent`s.
5. Capability metadata gates context package shape per model.

## Consequences

- New providers = new adapters + registration, not model changes.
- Testing can mock adapters without network.
- UI binds to registry ids, not OpenRouter types.

## Rejected

- Hard-coding OpenRouter calls inside SwiftUI/Compose screens.
- Supporting only local agents or only cloud.
