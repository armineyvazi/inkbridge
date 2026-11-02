# Security Policy

## Supported versions

| Version | Supported |
|---------|-----------|
| 0.1.x   | Yes       |

InkBridge is a developer-preview release. Security fixes are applied on `main` and included in the next patch or minor release.

## What InkBridge protects

- Wi-Fi transport uses TLS with a self-signed P-256 certificate **pinned** by the tablet.
- Pairing uses a short-lived one-time code (or QR deep link) and HMAC proofs bound to the certificate fingerprint.
- After pairing, the tablet reconnects with a 256-bit device token.
- Pairing failures are throttled per remote IP.
- Project names that would escape the Projects directory are rejected.

See [docs/architecture/security.md](docs/architecture/security.md) and [ADR-007](docs/decisions/ADR-007-tls-pairing.md) for the threat model.

## Known limitations (honest)

- There is no PAKE yet. A sniffed one-time code + nonce allows offline brute force of the short code space. Prefer pairing on a trusted network.
- USB currently requires developer mode (`adb reverse`). AOA without debugging is planned.
- The Mac overlay is local-only; there is no cloud sync and no account system.

## Reporting a vulnerability

Please **do not** open a public GitHub issue for security vulnerabilities.

Email the maintainer at the address on the GitHub profile for [armineyvazi](https://github.com/armineyvazi), with:

- A description of the issue
- Steps to reproduce
- Impact assessment (what an attacker gains)
- Whether you have a proof of concept (attach privately)

You should receive an acknowledgement within a few days. Please give a reasonable window before public disclosure.

## Secrets in this repository

Never commit API keys, signing certificates, device tokens, or personal pairing material. Build outputs and `local.properties` are gitignored.
