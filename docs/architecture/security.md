# Security and privacy

InkBridge is local-only. It has no cloud service, account, analytics or telemetry.
Nothing leaves the Mac or the tablet except the stroke stream between the two.

## Threat model

| Threat | Mitigation | Status |
|--------|-----------|--------|
| Someone on the LAN draws on your screen | The LAN listener requires `HMAC-SHA256(pairing code, fresh nonce)` before accepting any stroke | implemented, tested |
| Replay of a captured handshake | A new 256-bit nonce per connection | implemented |
| Online guessing of the pairing code | ~40-bit code (8 chars from a 31-symbol alphabet). Failures are tracked **per remote IP**: 5 in 60 s locks that IP out for 30 s, doubling per repeat up to 15 min. A global brake (50 failures/min from all hosts) limits distributed guessing. Stalled Wi-Fi handshakes count as failures | implemented, tested (`AuthThrottleTests`) |
| Someone on the LAN locks the real user out | Lockout is per IP, so another machine's failures do not block your tablet. The global brake can still be triggered by a determined multi-host attacker; that is a deliberate trade-off against unlimited guessing | implemented |
| Idle LAN sockets exhaust connection slots | Pending handshakes have their own per-transport cap (4); only authenticated peers count toward the peer cap (4). LAN squatters cannot block USB | implemented, tested |
| **Offline brute force of the pairing code** | **Not mitigated yet.** An eavesdropper who captures one `auth.challenge` nonce and the device's HMAC response can test codes offline. ~40 bits falls in minutes to hours on a GPU, after which they can pair. Fix: TLS with a pinned certificate (QR) or a PAKE (SPAKE2), Phase 5. Until then, regenerating the code (Settings → New code) after using Wi-Fi on an untrusted network limits the window | **open, Phase 5** |
| A malformed or hostile message crashes the host | Length check before buffering (64 KiB max); every field type- and range-checked; NaN/∞ rejected; string and array caps; no force-unwraps on peer data | implemented; fixtures test each class |
| Resource exhaustion | Max 4 authenticated peers, 4 pending handshakes per transport; 5 s handshake timeout; 7 s idle timeout; > 50 bad messages ⇒ disconnect | implemented |
| A local process injects strokes over loopback | The loopback listener is unauthenticated **by design**: anything able to connect to 127.0.0.1 already runs as you | accepted risk, documented |
| **Eavesdropping or tampering on Wi-Fi** | **Not mitigated yet.** After authentication the stream is plaintext. Strokes are not secret, but an on-path attacker could inject strokes into an authenticated session | **open: TLS is Phase 5** |
| Screen contents leak | No screen capture unless the user enables it; capture is saved only locally; nothing transmitted | implemented |

## Why not TLS today

The brief asks for TLS on Wi-Fi. It is not in this milestone, for two reasons:

1. TLS with pre-shared keys (the natural fit for a pairing code) is supported by
   Network.framework but **not exposed by Android's standard `SSLSocket`/Conscrypt
   APIs**. It would need BoringSSL through JNI or a bundled TLS library.
2. The alternative is certificate pinning: the Mac creates a self-signed identity
   in the Keychain and the QR pairing code carries its SHA-256 fingerprint. This is
   the planned approach. It needs a QR scan on the tablet, Keychain identity
   management on the Mac, and a custom `TrustManager` on Android. That is real work,
   and it should be done properly rather than half done.

Until then, the honest guidance is: **use Wi-Fi mode on networks you trust**, or use
USB. The pairing challenge keeps casual LAN users out, but it does not resist a
capable eavesdropper: one sniffed handshake is enough to brute-force the short code
offline. TLS with a pinned certificate removes both problems, because the handshake
is then encrypted and the code is no longer the only secret.

## Privacy

- The tablet's `device_id` is a random install UUID, not a serial number or Android ID.
- Logs contain device names and connection events, never stroke data or screen content.
- The diagnostic report contains versions, timings and display names only, and is
  written locally for the user to share or not.
- macOS permissions used:
  - Local Network (Wi-Fi mode)
  - Screen Recording (only if screenshots are enabled)
  - Nothing else: hot keys use Carbon, so no Accessibility permission is needed.

## USB debugging

`adb reverse` needs USB debugging, which gives a connected computer broad control of
the tablet. That is acceptable for development, and it is **not** a requirement for
end users. The AOA transport ([ADR-002](../decisions/ADR-002-usb-transport.md)) removes it.
