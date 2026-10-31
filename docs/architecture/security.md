# Security and privacy

InkBridge is local-only. It has no cloud service, account, analytics or telemetry.
Nothing leaves the Mac or the tablet except the stroke stream between the two.

## Threat model (protocol v3)

The Wi-Fi listener speaks **TLS 1.2+ with a self-signed certificate that devices pin**,
and every connection must prove a secret bound to that certificate. Design:
[wireless-connection.md](wireless-connection.md), decision: [ADR-007](../decisions/ADR-007-tls-pairing.md).

| Threat | Mitigation | Status |
|--------|-----------|--------|
| Someone on the LAN draws on your screen | Every LAN connection must present a device token (256-bit, issued at pairing) or, while Connect Device is open, prove the one-time code. Proofs are `HMAC-SHA256(secret, label ‖ 0 ‖ nonce ‖ cert fingerprint)` | implemented, tested |
| Eavesdropping or tampering on Wi-Fi | All Wi-Fi traffic is TLS; the device pins the Mac's certificate SHA-256 | implemented, tested (Swift TLS tests, JVM↔Swift e2e, real BOOX) |
| Man in the middle at first pairing | The device's proof covers the fingerprint *it saw*; a MITM must present its own certificate, so its relayed proof fails at the real Mac. The Mac answers with its own proof (`pair.granted.proof`), so a fake Mac that does not know the code is detected before anything is stored. A QR link carries the fingerprint, which pins from the first byte | implemented, tested (`testWifiRejections`, `impostorWithoutTheCodeIsDetected`) |
| Replay of a captured handshake | Fresh 256-bit nonce per connection; separate labels for device, host and token proofs | implemented, tested |
| Online guessing of the code | Codes exist only while Connect Device is open (5 min), work once, and are voided after 5 wrong guesses in total (from any address). Per-IP lockout (30 s doubling to 15 min) and a global brake (50/min) still apply | implemented, tested |
| Offline brute force of the code | The code (~40 bits) is never sent; a passive eavesdropper sees only TLS. An *active* attacker who stands up a fake Mac during the 5-minute window gets one device proof and could brute-force it offline, but the code is single-use and expires, and the device would show "the Mac could not prove it showed this code". Residual, documented | mitigated |
| A forgotten or stolen tablet keeps access | Mac: Connect Device / Settings → Forget removes the token and drops the link at once. Re-pairing replaces the token | implemented, tested |
| An address now points to a different Mac (DHCP reuse) | The device checks `host_id` in `auth.challenge` before sending any token proof, and the TLS pin fails anyway | implemented, tested |
| A malformed or hostile message crashes the host | Length check before buffering (64 KiB max); every field type- and range-checked; NaN/∞ rejected; string and array caps | implemented; fixtures test each class |
| Resource exhaustion | Max 4 authenticated peers, 4 pending handshakes per transport; 5 s handshake timeout; 7 s idle timeout; > 50 bad messages ⇒ disconnect | implemented |
| A local process injects strokes over loopback | The loopback (USB) listener is unauthenticated plain TCP **by design**: anything able to connect to 127.0.0.1 already runs as you | accepted risk |
| Secrets at rest | Mac: TLS key, host ID and device tokens in `~/Library/Application Support/InkBridge/` with mode 0600 (not the Keychain: the ad-hoc-signed app would re-prompt after every rebuild). Tablet: token and pin in app-private storage; `allowBackup=false`. Neither is ever logged or shown | implemented; Keychain once the app is Developer-ID signed |
| Screen contents leak | No screen capture unless the user enables it; saved only locally; never transmitted | implemented |

## Privacy

- The tablet's `device_id` is a random install UUID, not a serial number or Android ID.
- Logs contain device names and connection events, never stroke data or screen content.
- The diagnostic report contains versions, timings and display names only, and is
  written locally for the user to share or not.
- macOS permissions used:
  - Local Network (Wi-Fi mode); the macOS firewall may also ask to allow incoming connections
  - Screen Recording (only if screenshots are enabled)
  - Nothing else: hot keys use Carbon, so no Accessibility permission is needed.

## USB debugging

`adb reverse` needs USB debugging, which gives a connected computer broad control of
the tablet. That is acceptable for development, and it is **not** a requirement for
end users. The AOA transport ([ADR-002](../decisions/ADR-002-usb-transport.md)) removes it.
