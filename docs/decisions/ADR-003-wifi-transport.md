# ADR-003: Wi-Fi transport: LAN TCP, Bonjour discovery, pairing-code challenge; TLS deferred

- Status: accepted (TLS part deferred)
- Date: 2026-10-31

## Context

The brief asks for local-only Wi-Fi with discovery, pairing, authentication,
reconnection and TLS, and says never to expose an unauthenticated drawing server.
Research is in [`research/wifi-research.md`](../research/wifi-research.md).

## Decision

- Plain TCP on port 8766, `TCP_NODELAY` on both ends. UDP would avoid head-of-line
  blocking, but strokes need ordered, reliable delivery; on a healthy LAN, TCP's RTT
  is 1–5 ms.
- Discovery is Bonjour `_inkbridge._tcp` (`NWListener.service` on the Mac,
  `NsdManager` on Android). Manual IP entry is the fallback, because some networks
  block multicast.
- Authentication: the host sends a nonce, and the device answers
  `HMAC-SHA256(normalized pairing code, nonce)`. The pairing code is generated on
  the Mac, shown in its menu and settings, and can be regenerated. Five failures in
  60 s lock out the LAN listener.
- **TLS is deferred to Phase 5**, using a self-signed Mac identity pinned by
  fingerprint, delivered through a QR code. See
  [`architecture/security.md`](../architecture/security.md) for why PSK-TLS is not
  practical on Android.

## Consequences

- Nobody can draw without the code. A passive observer on the same network *can* read
  strokes, and an active one could inject into an authenticated session. This is
  stated in the security doc and the README.
- QR pairing arrives together with TLS, because the QR code exists to carry the
  certificate fingerprint as well as the code.
