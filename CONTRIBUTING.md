# Contributing to InkBridge

Thanks for helping. InkBridge is a native macOS + Android (BOOX) project with a shared wire protocol. Small, focused changes with tests are preferred.

## Development setup

Follow [docs/implementation/setup.md](docs/implementation/setup.md). Short version:

```bash
# macOS host
make test-macos
make install-macos

# Android (JDK 17, Android SDK platform 34)
# Create apps/android/local.properties with sdk.dir=...
make test-android
make install-android   # requires adb + a device or emulator
```

Build artifacts go to `~/Library/Caches/InkBridge/` so Dropbox/iCloud xattrs do not break `codesign`.

## Workflow

1. Open an issue for non-trivial work (or reference an existing one).
2. Branch from `main`: `git checkout -b fix/short-description`.
3. Keep commits focused. Prefer imperative subjects (`Fix eraser stroke.style width`).
4. Open a pull request against `main`. CI must pass.

## Quality gates

```bash
make format   # Swift (swift-format)
make lint     # Swift format check + Android lintDebug
make test     # macOS + Android unit/integration tests
make check    # lint + test (what CI runs)
```

- **Swift:** `InkBridgeCore` must stay UI-free and unit-testable.
- **Kotlin:** `:core` is pure JVM — prefer putting protocol/input/transport logic there.
- **Protocol changes:** bump or extend fixtures in `protocol/fixtures/` and update both codecs. Document in `docs/protocol/` and an ADR when behaviour changes.
- **New workspace surfaces:** extend `Workspace` / `WorkspaceSurface` (ADR-010); do not add orphan boolean flags.

## Testing expectations

- Behaviour changes need tests (unit or fixture).
- Bug fixes need a regression test when practical.
- Hardware-only behaviour (BOOX panel, real Wi-Fi) should be marked **Verified (hardware)** or **Pending** in docs — do not claim it from CI alone.
- Run `scripts/e2e.sh` (and `scripts/e2e.sh wifi` when possible) for transport changes.

## Documentation

- User- and developer-facing docs live in this repository under `docs/`.
- Extended engineering notes may also live in the maintainer's Obsidian vault; keep ADRs and architecture docs in sync when behaviour changes (see [docs/README.md](docs/README.md)).

## Security

Do not commit secrets. Report vulnerabilities privately — see [SECURITY.md](SECURITY.md).

## License

By contributing, you agree that your contributions are licensed under the MIT License (see [LICENSE](LICENSE)).
