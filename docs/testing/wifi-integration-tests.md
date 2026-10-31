# Wi-Fi integration tests

Legend:

- **U**: unit test, in process.
- **S**: socket test on loopback (real TLS where noted).
- **E**: cross-language end-to-end: Kotlin simulator ↔ Swift probe over the Mac's LAN IP (`scripts/e2e.sh wifi`).
- **H**: real BOOX Note Air 2 Plus on Wi-Fi with no `adb reverse`; the host is `inkbridge-probe`, which uses the same `InkServer` as the app.

| # | Scenario | Coverage | Result |
|---|---|---|---|
| 1 | Mac and BOOX on the same Wi-Fi | H | ✅ 13.0.0.156 ↔ 13.0.0.184 |
| 2 | Automatic Mac discovery | H | ✅ Bonjour list showed the Mac; TXT `id` used to follow IP changes (U) |
| 3 | QR-code pairing | U (Swift and Kotlin parse the shared `pairing-link.txt`), Robolectric deep link | ✅. The BOOX has no camera, so scanning on the BOOX is not possible |
| 4 | Secure authentication | S: Swift TLS client against the real listener; proofs bound to the certificate fingerprint; impostor host proof (Kotlin) | ✅ |
| 5 | Successful connection | S, E, H | ✅ |
| 6 | Stylus stroke delivery | E (6/6 strokes), H (30/30) | ✅ |
| 7 | Real-time drawing sync | H: pen→Mac **p50 7.1 / p95 13.6 / p99 22.3 ms** (n = 3816 samples) | ✅ |
| 8 | Temporary Wi-Fi disconnection | H: Wi-Fi off, 2 strokes drawn offline, Wi-Fi on → both delivered, 0 duplicates. S: 5 messages lost on a dead link re-sent exactly once, in order | ✅ |
| 9 | Automatic reconnection | H: network available → authenticated **163 ms**; E: forced drop → back with the token in 16 ms. Tablet sleep/wake → re-authenticated 120 ms after Wi-Fi returned | ✅ |
| 10 | Mac sleep and wake recovery | Listener re-registration built (`NetworkWatcher`) | ⏳ not run (sleeping the test Mac ends the session) |
| 11 | Network switching | U: `reconnectNow`, address follows discovery `host_id` | ⏳ not run on hardware |
| 12 | Invalid pairing credentials | S: wrong code, window closed, MITM fingerprint, missing proof, unknown token, 5 wrong codes void the ticket. H: wrong code, certificate changed, forgotten tablet | ✅ |
| 13 | Duplicate connection prevention | U/S: one active peer (`PeerArbiter`), per-stream sequence dedupe, deferred switch while a stroke is active | ✅ (no duplicates in any run) |

## Commands

```bash
make -C apps/macos test           # 87 Swift tests, including the TLS pairing tests
make -C apps/android test         # 56 core + 9 UI tests
scripts/e2e.sh wifi               # TLS pair → draw → drop → token reconnect
```

The hardware runs use `inkbridge-probe --identity DIR` to keep a stable certificate across restarts, and `adb shell input` to drive the tablet.

## Not yet verified on hardware

- **Wi-Fi to the real InkBridge.app.** Pairing needs one click in Connect Device, and macOS may ask once to allow incoming connections. The probe host has the same server code; the app adds only the window.
- Router restart, the Mac changing networks, the Mac sleeping and waking.
- **The cable physically unplugged.** In every hardware run, Wi-Fi carried all InkBridge traffic: the tablet dialled 13.0.0.156:8766 and `adb reverse` was removed. The cable stayed in only so adb could drive the tablet.
- Note Air 3. All hardware results are from a Note Air 2 Plus.
