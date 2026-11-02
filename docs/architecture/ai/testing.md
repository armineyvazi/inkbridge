# AI testing & acceptance criteria (proposed)

Distinguish **automated**, **mocked integration**, and **hardware/manual**.
Do not claim interpretation accuracy without an eval dataset.

## Document intelligence

| Criterion | Type |
|-----------|------|
| Printed PDF text extraction fixtures | Automated |
| HTR on labeled handwriting samples | Eval set + metrics (future) |
| Mixed print + ink pages | Eval / manual |
| Annotation↔paragraph association cases | Table-driven unit |
| Arrow/circle geometry detectors | Unit |
| Coordinates across zoom levels | Unit + golden |
| Multi-page package bounds | Unit |

## Provider Hub / OpenRouter

| Criterion | Type |
|-----------|------|
| Connection setup happy path | UI + mocked HTTP |
| Invalid API key | Mocked 401 |
| Keychain/Keystore round-trip | Platform integration |
| Model discovery parse | Unit against fixture JSON |
| Unsupported modality downgrade | Unit |
| Streaming / cancel / retry | Mocked SSE |
| Rate limit messaging | Mocked 429 |
| Usage display from `usage` | Unit |
| Cost estimate from listed rates | Unit |
| Key redaction in logs | Unit / lint |

## Persistence

| Criterion | Type |
|-----------|------|
| Save / reopen / search / export / delete | Unit + UI |
| Provenance navigation | Integration |
| No silent save | UI test |
| No duplicate lost answers on retry | Unit |

## Local agents

| Criterion | Type |
|-----------|------|
| CLI missing / unauthenticated / ok | Integration with fakes |
| Cancel kills process | Integration |
| Large context temp dir cleanup | Integration |
| `--force` gated by preference | Unit |

## Manual / device

- Mac AI panel streaming under load  
- BOOX panel refresh behavior  
- Real OpenRouter key smoke (maintainer only; never in CI secrets for PRs unless dedicated)  
- Claude / Cursor installed-machine smoke  
