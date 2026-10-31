# Wi-Fi research

## Transport: TCP

Strokes need ordered, reliable delivery. TCP with `TCP_NODELAY` gives that with
1–5 ms RTT on a healthy LAN. UDP plus app-level retransmission would avoid
head-of-line blocking after a lost packet, but at the cost of reimplementing ordering
and acknowledgement. Under real packet loss that might matter. Measure first: Wi-Fi
latency on hardware is **pending**.

Wi-Fi power saving is the bigger latency risk. Android radios doze between
beacons, which can add tens of ms to the first packet after idle. Mitigations to
evaluate on hardware:

- the 2 s ping keeps the link warm
- `WifiManager.WifiLock(WIFI_MODE_FULL_LOW_LATENCY)` (API 29+) while drawing, if
  the BOOX firmware honours it

## Discovery: Bonjour / mDNS

- Mac: `NWListener.service = .init(name: <computer name>, type: "_inkbridge._tcp")`.
  macOS 11+ needs `NSBonjourServices` and `NSLocalNetworkUsageDescription` in
  `Info.plist`, both present in `Resources/Info.plist`.
- Android: `NsdManager.discoverServices("_inkbridge._tcp", PROTOCOL_DNS_SD)`, then
  `resolveService`.
- Enterprise, guest and hotel networks often block multicast or isolate clients.
  Manual IP entry is the fallback, and the Mac's IP will also go in the QR code.
- Verified on this Mac: `dns-sd -B _inkbridge._tcp` lists the probe while it runs.
  Discovery from the tablet is **pending**.

## Pairing and authentication

See [ADR-003](../decisions/ADR-003-wifi-transport.md) and
[security.md](../architecture/security.md). In summary: a nonce challenge with
HMAC-SHA256 keyed by an ~40-bit code, plus lockout. TLS with fingerprint pinning
through QR is planned for Phase 5.

## Cloud: none

There is no relay, rendezvous server or account. If the two devices cannot reach each
other on the LAN, the answer is USB.

## Verified so far

| Check | Result |
|-------|--------|
| LAN listener reachable on the Mac's LAN IP (13.0.0.156:8766) | yes (`nc` receives `auth.challenge`) |
| Simulator → Mac LAN IP with correct code | 6/6 strokes, 720 points, 0 dropped, RTT ~1.2 ms (same machine, so this is **not** a real Wi-Fi hop) |
| Wrong or missing code rejected | yes (integration tests) |
| Tablet over real Wi-Fi | **pending** |
