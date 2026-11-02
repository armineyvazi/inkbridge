import Foundation
import InkBridgeCore

// inkbridge-probe: a headless InkBridge host for end-to-end tests and
// latency measurement. It runs the real InkServer and drawing model, but
// prints statistics instead of drawing.
//
//   inkbridge-probe [--seconds N] [--code XXXX-XXXX] [--no-wifi]
//                   [--usb-port 8765] [--wifi-port 8766] [--expect-strokes N]
//                   [--expect-pairings N] [--identity DIR]
//                   [--push-background SPEC@SECONDS ...]   SPEC = overlay | white | black | #rrggbb[:pattern]
//
// Background requests from the device are applied and echoed exactly like the
// app does (single writer, revisioned), and printed.
//
// Wi-Fi is TLS with a throwaway identity, and a Connect Device window with
// --code stays open for the whole run, so a simulator can pair and then
// reconnect with its token.
//
// Exit status is non-zero if --expect-strokes is given and not met, so the
// probe can gate scripts/e2e.sh.

struct Options {
  var seconds = 30.0
  var code = "TEST-CODE"
  var wifi = true
  var usbPort: UInt16 = 8765
  var wifiPort: UInt16 = 8766
  var expectStrokes: Int?
  var expectPairings: Int?
  /// Keep the TLS identity here instead of a throwaway directory, so a
  /// tablet's certificate pin survives probe restarts.
  var identityDir: String?
  var pushes: [(CanvasBackground, Double)] = []

  init(_ args: [String]) {
    var it = args.dropFirst().makeIterator()
    while let a = it.next() {
      switch a {
      case "--seconds": seconds = Double(it.next() ?? "") ?? seconds
      case "--code": code = it.next() ?? code
      case "--no-wifi": wifi = false
      case "--usb-port": usbPort = UInt16(it.next() ?? "") ?? usbPort
      case "--wifi-port": wifiPort = UInt16(it.next() ?? "") ?? wifiPort
      case "--expect-strokes": expectStrokes = Int(it.next() ?? "")
      case "--expect-pairings": expectPairings = Int(it.next() ?? "")
      case "--identity": identityDir = it.next()
      case "--push-background":
        let parts = (it.next() ?? "").split(separator: "@")
        if parts.count == 2, let at = Double(parts[1]),
          let bg = Options.parseBackground(String(parts[0]))
        {
          pushes.append((bg, at))
        }
      default:
        FileHandle.standardError.write(Data("unknown argument \(a)\n".utf8))
        exit(2)
      }
    }
  }
}

extension Options {
  static func parseBackground(_ spec: String) -> CanvasBackground? {
    let parts = spec.split(separator: ":").map(String.init)
    let pattern = parts.count > 1 ? CanvasBackground.Pattern(rawValue: parts[1]) ?? .none : .none
    switch parts[0] {
    case "overlay": return CanvasBackground(mode: .overlay, pattern: pattern)
    case "white": return .studio(CanvasBackground.white, pattern: pattern)
    case "black": return .studio(CanvasBackground.black, pattern: pattern)
    default: return RGBA(hex: parts[0] + "ff").map { .studio($0, pattern: pattern) }
    }
  }
}

final class Probe: InkServerDelegate {
  var peerID: UUID?
  var backgroundsReceived = 0
  let store = StrokeStore()
  lazy var ingestor = StrokeIngestor(store: store)
  var clock = ClockSync()
  var penToHost = LatencyStats(capacity: 100_000)
  var ingest = LatencyStats(capacity: 100_000)
  /// Sample time → send time, both on the device clock: delay spent on the tablet.
  var onDevice = LatencyStats(capacity: 100_000)
  /// Send time → host receive (needs clock offset): delay in transport.
  var transport = LatencyStats(capacity: 100_000)
  var messages = 0
  var points = 0
  var firstPointAt: Int64?
  var lastPointAt: Int64?

  func inkServer(_ s: InkServer, didConnect peer: PeerInfo) {
    peerID = peer.id
    s.send(.canvasBackground(store.background, revision: store.backgroundRevision), to: peer.id)
    let h = peer.hello
    print(
      "connected: \(h.deviceName) [\(peer.kind.rawValue)] model=\(h.model) api=\(h.androidAPI) surface=\(h.surfaceWidthPx)x\(h.surfaceHeightPx) pressure=\(h.capabilities.pressure) eraser=\(h.capabilities.eraser)"
    )
  }

  func inkServer(_ s: InkServer, peer: PeerInfo, didReceive m: Message, receivedAtNs: Int64) {
    messages += 1
    if case .strokePoint(_, let pts) = m.payload {
      points += pts.count
      firstPointAt = firstPointAt ?? receivedAtNs
      lastPointAt = receivedAtNs
      if let last = pts.last {
        onDevice.add(Double(m.timestampNs - last.t) / 1e6)
        if let hostNs = clock.hostTime(forDeviceNs: last.t) {
          penToHost.add(Double(receivedAtNs - hostNs) / 1e6)
        }
        if let sentHostNs = clock.hostTime(forDeviceNs: m.timestampNs) {
          transport.add(Double(receivedAtNs - sentHostNs) / 1e6)
        }
      }
    }
    if case .canvasBackground(let bg, _) = m.payload {
      backgroundsReceived += 1
      store.setBackground(bg)
      print(
        "background from device: \(bg.mode.rawValue) \(bg.color.hex) \(bg.pattern.rawValue) → revision \(store.backgroundRevision)"
      )
      s.send(.canvasBackground(store.background, revision: store.backgroundRevision), to: peer.id)
    }
    let change = ingestor.handle(m, streamID: peer.hello.streamID)
    ingest.add(Double(monotonicNowNs() - receivedAtNs) / 1e6)
    if case .documentChanged = change, case .strokeEnd = m.payload {
      print(
        "stroke \(store.strokes.count) committed (\(store.strokes.last?.points.count ?? 0) points)")
    }
  }

  func inkServer(_ s: InkServer, peer: PeerInfo, didUpdateClock c: ClockSync) {
    clock = c
  }

  func inkServer(_ s: InkServer, didDisconnect peer: PeerInfo, reason: String) {
    print("disconnected: \(peer.hello.deviceName): \(reason)")
  }

  func inkServer(
    _ s: InkServer, listener: TransportKind, didChangeState state: InkServer.ListenerState
  ) {
    print("listener \(listener.rawValue): \(state)")
  }

  var pairings = 0
  func inkServer(_ s: InkServer, didPair device: PairedDevice) {
    pairings += 1
    print("paired: \(device.name)")
    // Keep the window open so later runs in the same probe can pair too.
    s.openPairing(code: options.code)
  }

  func report() {
    func f(_ v: Double?) -> String { v.map { String(format: "%.2f", $0) } ?? "n/a" }
    print("---- probe report ----")
    print(
      "background: \(store.background.mode.rawValue) \(store.background.color.hex) \(store.background.pattern.rawValue) (revision \(store.backgroundRevision), \(backgroundsReceived) requests from device)"
    )
    print(
      "messages: \(messages), points: \(points), strokes: \(store.strokes.count), dropped duplicates: \(ingestor.droppedCount)"
    )
    if let a = firstPointAt, let b = lastPointAt, b > a {
      print(
        "point rate: \(String(format: "%.0f", Double(points) / (Double(b - a) / 1e9))) samples/s averaged from first to last point (includes pauses)"
      )
    }
    print("rtt ms (last): \(f(clock.lastRTTNs.map { Double($0) / 1e6 }))")
    print(
      "pen→host ms p50/p95/p99: \(f(penToHost.percentile(0.5))) / \(f(penToHost.percentile(0.95))) / \(f(penToHost.percentile(0.99))) (n=\(penToHost.count))"
    )
    print(
      "  on tablet (sample→send) ms p50/p95/p99: \(f(onDevice.percentile(0.5))) / \(f(onDevice.percentile(0.95))) / \(f(onDevice.percentile(0.99)))"
    )
    print(
      "  transport (send→host) ms p50/p95/p99: \(f(transport.percentile(0.5))) / \(f(transport.percentile(0.95))) / \(f(transport.percentile(0.99)))"
    )
    print("ingest ms p50/p99: \(f(ingest.percentile(0.5))) / \(f(ingest.percentile(0.99)))")
  }
}

let options = Options(CommandLine.arguments)
let identityDir =
  options.identityDir.map { URL(fileURLWithPath: $0) }
  ?? FileManager.default.temporaryDirectory.appendingPathComponent("inkbridge-probe-\(getpid())")
let identity: HostIdentity
do {
  identity = try HostIdentity.loadOrCreate(in: identityDir, commonName: "InkBridge Probe")
} catch {
  print("FAIL: TLS identity: \(error)")
  exit(1)
}
var config = InkServer.Config(
  serviceName: "InkBridge Probe", sessionID: "probe-session", identity: identity,
  pairedDevices: PairedDevices(url: nil))
config.pairingDuration = options.seconds + 5
config.usbPort = options.usbPort
config.wifiPort = options.wifiPort
config.wifiEnabled = options.wifi
// The probe drives clock sync harder than the app to converge quickly.
config.pingInterval = 0.5

let probe = Probe()
let server = InkServer(config: config)
server.delegate = probe
server.start()
server.openPairing(code: options.code)
for (bg, at) in options.pushes {
  DispatchQueue.main.asyncAfter(deadline: .now() + at) {
    probe.store.setBackground(bg)
    print(
      "background pushed: \(bg.mode.rawValue) \(bg.color.hex) \(bg.pattern.rawValue) revision \(probe.store.backgroundRevision)"
    )
    if let id = probe.peerID {
      server.send(.canvasBackground(bg, revision: probe.store.backgroundRevision), to: id)
    }
  }
}
print(
  "probe running for \(Int(options.seconds))s; pairing code \(options.code); tls \(identity.shortFingerprint)"
)
setvbuf(stdout, nil, _IOLBF, 0)

DispatchQueue.main.asyncAfter(deadline: .now() + options.seconds) {
  probe.report()
  server.stop()
  if options.identityDir == nil { try? FileManager.default.removeItem(at: identityDir) }
  if let want = options.expectPairings, probe.pairings < want {
    print("FAIL: expected at least \(want) pairings, got \(probe.pairings)")
    exit(1)
  }
  if let want = options.expectStrokes, probe.store.strokes.count < want {
    print("FAIL: expected at least \(want) strokes, got \(probe.store.strokes.count)")
    exit(1)
  }
  exit(0)
}
dispatchMain()
