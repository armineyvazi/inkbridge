# Code style

## Swift (macOS)

- Follow [API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/).
- Format with `xcrun swift-format` (`make format` / `make lint`).
- `InkBridgeCore` must not import AppKit UI types beyond what drawing/math needs; keep it unit-testable.
- Prefer `throws` / typed errors with context (`"load session: \(path): \(error)"`) over empty catches.
- Document ownership and concurrency on public types.

## Kotlin (Android)

- Follow [Kotlin coding conventions](https://kotlinlang.org/docs/coding-conventions.html).
- Put protocol, transport, and input in `:core` (pure JVM) whenever possible.
- UI belongs in `:app`; keep e-ink constraints (no animation, large targets) — see `docs/design/`.
- Android Lint: `make -C apps/android lint`.

## Protocol

- Both codecs must agree with `protocol/fixtures/`.
- Additive fields preferred; meaning changes require a version bump and ADR.

## Commits and PRs

- Imperative subject line; explain *why* in the body when non-obvious.
- PRs use [.github/PULL_REQUEST_TEMPLATE.md](../../.github/PULL_REQUEST_TEMPLATE.md).
