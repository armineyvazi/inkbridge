# OpenRouter integration feasibility (proposed)

> Research verified against official docs on **2026-11-03**. No client code in repo.

## Sources

- Chat Completions: https://openrouter.ai/docs/api/api-reference/chat/create-a-chat-completion  
- Models list: https://openrouter.ai/docs/api/api-reference/models/list-all-models-and-their-properties  
- Auth: https://openrouter.ai/docs/api_reference/authentication  
- Overview (also documents Responses API): https://openrouter.ai/docs/api_reference/overview  

## Verified HTTP contracts

| Operation | Method / URL |
|-----------|----------------|
| Chat completion (stream optional) | `POST https://openrouter.ai/api/v1/chat/completions` |
| List models | `GET https://openrouter.ai/api/v1/models` |
| Responses API (alternative) | `POST https://openrouter.ai/api/v1/responses` |

**Auth:** `Authorization: Bearer <OPENROUTER_API_KEY>`

**Optional attribution headers** (documented): `HTTP-Referer`, `X-OpenRouter-Title`
(some docs also mention `X-Title` historically — prefer current official names
at implementation time).

## Recommended first adapter shape

Prefer **Chat Completions** for the initial Hub:

- Broad tooling familiarity and SSE streaming (`stream: true`)
- Multimodal `messages[].content` parts for text + images when the model
  advertises image input modalities
- OpenRouter extras: `models` fallback list, `provider` preferences, `user`
  abuse-prevention id (opaque app-generated, not PII)

Re-evaluate Responses API once Hub streaming UX is stable.

## Model metadata to consume

From `GET /api/v1/models` (fields observed in docs examples):

- `id`, `name`, `context_length`
- `architecture.input_modalities` / `output_modalities`
- `pricing.prompt` / `pricing.completion` (and image when present)
- `supported_parameters`

**Capability gating:** only attach image/PDF-like parts when input modalities
include vision/file support for that model. Text-only models get extracted
text + HTR + relation summaries.

## Validation and errors

- Validate key with a lightweight authenticated call (models list or a tiny
  completion) before enabling Send.
- Map HTTP 401/402/429/5xx to user-visible states; exponential backoff with
  jitter for 429 only when the user retries or policy allows.
- Redact `Authorization` and any key material from logs.

## Cost display

Estimate = Σ (tokens × listed rate). Show provider `usage` when present.
Do not claim “billed amount” unless OpenRouter exposes an authoritative
generation cost field consumed by the client.

## Feasibility verdict

**Feasible** for Phase 4 as the first cloud adapter: HTTPS + JSON from native
Swift/Kotlin (or shared Go/Rust later) with Keychain-held keys. No OpenRouter
requirement to embed a webview.
