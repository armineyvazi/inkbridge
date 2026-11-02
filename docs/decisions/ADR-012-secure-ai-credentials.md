# ADR-012: Secure AI credentials (Keychain / Keystore, no key sync)

- **Status:** proposed (2026-11-03)
- **Related:** ADR-007 (TLS pairing), ADR-011, `docs/architecture/ai/credentials.md`

## Context

Cloud providers require API keys. The ink stack already uses careful secret
handling for pairing. AI keys must not regress into plaintext project files
(especially under Dropbox-synced paths) or sync blindly across devices.

## Decision

1. Store cloud API keys only in **macOS Keychain** and **Android Keystore-backed** storage.
2. Persist non-secret provider metadata (display name, provider type, default model id).
3. **Do not synchronize raw API keys**; each device re-enters secrets.
4. Prefer CLI-native auth for Claude Code / Cursor on the Mac when sufficient.
5. Redact credentials from logs, exports, diagnostics, and crash reports.

## Consequences

- Hub “Validate” flows run on-device against Keychain material.
- Backup/migrate UX tells users to re-enter keys.
- Android and Mac Hub UIs share metadata schema, not secret bytes.

## Rejected

- Plaintext `.env` / UserDefaults / SharedPreferences for keys.
- Syncing keys via iCloud/Dropbox/journal folders.
