# ADR-007: TLS with a pinned certificate, one-time codes and device tokens (protocol v3)

**Status:** accepted, implemented (2026-10-31)
**Supersedes:** the permanent pairing code of ADR-003 / protocol v2

## Context

Wi-Fi had to become a first-class, cable-free connection. v2 had three gaps:

- The stream was plaintext after an HMAC challenge.
- The pairing code was permanent, so one sniffed handshake allowed offline brute force of ~40 bits.
- Discovery only pre-filled an IP address.

The brief asked for TLS, QR pairing and short-lived tokens.

## Options considered

| Option | Verdict |
|---|---|
| TLS-PSK keyed from the code | Network.framework supports it, but Android's `SSLSocket`/Conscrypt does not expose PSK. It would need BoringSSL via JNI or a bundled TLS stack. Rejected. |
| PAKE (SPAKE2) over plain TCP | Strongest pairing, but it is custom crypto on two platforms with no TLS for the stream. Rejected. |
| **Self-signed certificate on the Mac, pinned by the tablet, with proofs bound to the fingerprint** | Uses only platform TLS (Network.framework and `SSLSocket`). **Chosen.** |

## Decision

1. **Mac identity.**
   - A P-256 key and a self-signed X.509 certificate, built by a ~60-line DER encoder (Security.framework can parse certificates but not create them).
   - `SecIdentityCreate` turns them into an identity in memory.
   - Stored as 0600 files, so the ad-hoc-signed app never triggers Keychain prompts.
   - The certificate is verified by `openssl verify` in tests.
2. **Wi-Fi is TLS 1.2+.** USB (loopback via `adb reverse`) stays plain TCP and unauthenticated.
3. **Pairing.**
   - Connect Device on the Mac opens a ticket: an 8-character code, valid for 5 minutes, usable once, and void after 5 wrong guesses.
   - The device proves `HMAC(code, "inkbridge-v3-pair" ‖ 0 ‖ nonce ‖ fp_seen)`.
   - The Mac answers in `pair.granted` with its own proof and a 256-bit token.
   - The device stores the token, `host_id` and the fingerprint as its pin.
4. **Later connections.**
   - The device first pins the certificate.
   - It then proves `HMAC(token, "inkbridge-v3-token" ‖ 0 ‖ nonce ‖ fp)`.
   - It never sends that proof to a different `host_id`.
5. **QR code.**
   - Connect Device also shows an `inkbridge://pair?...` link with addresses, port, code, fingerprint and expiry.
   - Opening it on Android pre-pins the certificate.
6. **Bonjour TXT** carries `id=<host_id>`, so a paired tablet finds its Mac after the Mac's IP changes.
7. **`device.ready.resume_sequence`** lets a reconnecting device re-send exactly what the dead link lost.

## Consequences

- Wi-Fi is encrypted and authenticated in both directions.
- Offline brute force needs an active attacker within the 5-minute window, and is detectable.
- The protocol version bumps to 3, so old peers are refused with a clear error.
- **Neither the Note Air 2 Plus nor the Note Air 3 has a camera**, so a BOOX cannot scan the QR code itself.
  - On the BOOX, pairing is: choose the discovered Mac, then type the code.
  - The QR link works on devices that have a scanner, and it is tested through the deep link.
- Secrets sit in files, not the Keychain, until the app is Developer-ID signed.
