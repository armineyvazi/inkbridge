# Wireless connection

Wi-Fi is the default connection method, and the whole workflow runs over it:

1. The two devices find each other.
2. They pair.
3. They draw.
4. They reconnect when the link drops.

No cable, ADB or USB debugging is needed, and nothing goes through the internet. USB (`adb reverse`) remains an optional alternative, and it uses the same protocol and drawing code.

## Audit of what existed before (v2)

| Area | v2 state | Gap |
|---|---|---|
| Discovery | Mac advertised `_inkbridge._tcp`. Android resolved it, but only to pre-fill an IP field in a settings dialog | No host identity, so a paired Mac could not be recognised after an IP change |
| Pairing | One permanent code, typed into the dialog together with the IP | Long-lived secret. One sniffed handshake allowed offline brute force |
| Encryption | None | Plaintext strokes; injection possible on-path |
| Reconnection | Backoff of 250 ms to 2 s; keep-alive timeout 7 s | Not tied to network changes; strokes in flight on a dead socket were lost |
| Mode | Global USB/Wi-Fi switch, USB by default | Wi-Fi was secondary |

## Architecture

```
BOOX (Android)                                        Mac
──────────────                                        ───
ConnectionManager (app-scoped)                        InkCoordinator
 ├─ BonjourDiscovery ── mDNS _inkbridge._tcp ──────▶  NWListener.service (TXT id=host_id, v=3)
 ├─ NetworkMonitor (ConnectivityManager callbacks)    NetworkWatcher (NWPathMonitor + wake) → restart listener
 ├─ PairingStore (host_id, name, pin, token, addr)    PairedDevices (device_id → token), PairingTicket
 └─ InkBridgeClient ── TlsTransport ── TLS 1.2+ ────▶ InkServer :8766 (HostIdentity: P-256 self-signed)
        └─ same protocol / StrokeProcessor / CanvasDocument as USB ─ AdbReverseTransport ─▶ :8765 (loopback)
```

The drawing engine never knows which transport is in use. `Transport` is only a byte pipe; TLS is one more layer inside `TlsTransport.open()`.

## Connection states

Shown to the user through `ConnectionStatus` (core, unit-tested):

```
NOT_PAIRED → DISCOVERING/FOUND → PAIRING → AUTHENTICATING → CONNECTED (ready to draw)
                                  ▲                               │ link lost
                                  └────────── RECONNECTING ◀──────┘
DISCONNECTED (user pressed Disconnect)
FAILED: wrong code · code expired · Mac forgot this tablet · Mac identity changed
```

## Pairing

The handshake is described in [ADR-007](../decisions/ADR-007-tls-pairing.md) and the [protocol spec](../protocol/protocol-specification.md).

1. **Mac:** Connect Device opens by itself while no tablet is paired, and whenever InkBridge is opened again (Finder, Spotlight, Launchpad). It is also on ⌃⌥K and in the menu-bar pen. It shows a one-time code (5 minutes), a QR link and the paired devices.
2. **BOOX:** Connect to Mac. Discovered Macs are listed. Choose one, type the code, then Pair.
3. **The Mac and tablet exchange proofs** bound to the TLS fingerprint. The Mac issues a token, and the tablet pins the certificate.
4. **From then on,** the tablet reconnects by itself with the token. No window needs to be open on the Mac.

There are two fallbacks:

- **Enter the Mac's address**, for networks where mDNS is blocked.
- **The `inkbridge://pair` link**, from the QR code on any device with a scanner. BOOX Note Air models have no camera.

## Reliability

| Mechanism | Where | Number |
|---|---|---|
| Heartbeat | Both sides ping every 2 s | Idle timeout 7 s |
| Retry backoff | `ReconnectionPolicy` | 250 ms → 2 s cap, ±20 % jitter |
| Network change | `NetworkMonitor.onAvailable` → `reconnectNow()`; `onLost` → drop the socket now | Measured on the Note Air 2 Plus: Wi-Fi available → authenticated **163 ms** |
| Mac IP change | Discovery matches TXT `id` to the paired `host_id` and updates the address | — |
| Mac sleep / network change | `NetworkWatcher` re-registers the listener and its Bonjour record 1.5 s after wake or a path change | — |
| Lost in-flight messages | Client keeps a sent log (8192 entries); `device.ready.resume_sequence` says what arrived; the rest is re-sent with new sequence numbers (same host + session only) | Tested: 5 lost points re-sent once, in order |
| Duplicates | Host drops `sequence ≤ last` per `stream_id` (one stream per app process) | Zero duplicates in all runs |
| Active stroke during a drop | The Mac keeps strokes in progress open for 10 s for the same stream. Replayed points continue them, and other peers end them | — |
| Two transports at once | `PeerArbiter` draws from one peer. A new peer that arrives mid-stroke is elected only after the stroke ends | — |
| Screen off | The connection stops 4 s after the last InkBridge screen is hidden, and reconnects on wake | — |

## Network situations

| Situation | Behaviour |
|---|---|
| Same Wi-Fi | Supported, and the primary case. Verified on hardware |
| Wi-Fi drops briefly | The tablet shows "Reconnecting…", queues strokes, and sends them on return. Verified on hardware (Wi-Fi off/on) |
| Router restarts / IPs change | Rediscovery by `host_id`; the backoff keeps trying. Not yet tested on hardware |
| Mac sleeps and wakes | The listener is re-registered on wake; the tablet retries. Not yet tested on hardware |
| Different networks / guest Wi-Fi with client isolation | **Not supported.** mDNS and direct TCP do not cross networks. Fallback: enter the address manually if the networks are routed. Wi-Fi Direct or a Mac-hosted network is future work |
| macOS firewall on | The first incoming connection may trigger "Allow incoming connections?"; choose Allow |

## Files

- **Mac:**
  - `InkBridgeCore/Security/{HostIdentity,PairedDevices,PairingLink}.swift`
  - `Transport/{InkServer,PeerConnection}.swift`
  - `Infrastructure/NetworkWatcher.swift`
  - `Features/Connect/ConnectDeviceView.swift`
- **Android core:**
  - `transport/TlsTransport.kt`
  - `client/InkBridgeClient.kt`
  - `protocol/PairingAuth.kt`
  - `connection/{ConnectionStatus,PairingLink}.kt`
- **Android app:**
  - `features/connection/{ConnectionManager,BonjourDiscovery,PairingStore}.kt`
  - `core/NetworkMonitor.kt`
  - `features/connect/ConnectActivity.kt`
