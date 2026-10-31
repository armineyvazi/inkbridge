import Foundation
import InkBridgeCore

// inkbridge-probe: a headless InkBridge host for end-to-end tests and
// latency measurement. It runs the real InkServer and drawing model, but
// prints statistics instead of drawing.
//
//   inkbridge-probe [--seconds N] [--code XXXX-XXXX] [--no-wifi]
//                   [--usb-port 8765] [--wifi-port 8766] [--expect-strokes N]
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
            default:
                FileHandle.standardError.write(Data("unknown argument \(a)\n".utf8))
                exit(2)
            }
        }
    }
}

final class Probe: InkServerDelegate {
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
        let h = peer.hello
        print("connected: \(h.deviceName) [\(peer.kind.rawValue)] model=\(h.model) api=\(h.androidAPI) surface=\(h.surfaceWidthPx)x\(h.surfaceHeightPx) pressure=\(h.capabilities.pressure) eraser=\(h.capabilities.eraser)")
    }

    func inkServer(_ s: InkServer, peer: PeerInfo, didReceive m: Message, receivedAtNs: Int64) {
        messages += 1
        if case let .strokePoint(_, pts) = m.payload {
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
        let change = ingestor.handle(m, streamID: peer.hello.streamID)
        ingest.add(Double(monotonicNowNs() - receivedAtNs) / 1e6)
        if case .documentChanged = change, case .strokeEnd = m.payload {
            print("stroke \(store.strokes.count) committed (\(store.strokes.last?.points.count ?? 0) points)")
        }
    }

    func inkServer(_ s: InkServer, peer: PeerInfo, didUpdateClock c: ClockSync) {
        clock = c
    }

    func inkServer(_ s: InkServer, didDisconnect peer: PeerInfo, reason: String) {
        print("disconnected: \(peer.hello.deviceName): \(reason)")
    }

    func inkServer(_ s: InkServer, listener: TransportKind, didChangeState state: InkServer.ListenerState) {
        print("listener \(listener.rawValue): \(state)")
    }

    func report() {
        func f(_ v: Double?) -> String { v.map { String(format: "%.2f", $0) } ?? "n/a" }
        print("---- probe report ----")
        print("messages: \(messages), points: \(points), strokes: \(store.strokes.count), dropped duplicates: \(ingestor.droppedCount)")
        if let a = firstPointAt, let b = lastPointAt, b > a {
            print("point rate: \(String(format: "%.0f", Double(points) / (Double(b - a) / 1e9))) samples/s averaged from first to last point (includes pauses)")
        }
        print("rtt ms (last): \(f(clock.lastRTTNs.map { Double($0) / 1e6 }))")
        print("pen→host ms p50/p95/p99: \(f(penToHost.percentile(0.5))) / \(f(penToHost.percentile(0.95))) / \(f(penToHost.percentile(0.99))) (n=\(penToHost.count))")
        print("  on tablet (sample→send) ms p50/p95/p99: \(f(onDevice.percentile(0.5))) / \(f(onDevice.percentile(0.95))) / \(f(onDevice.percentile(0.99)))")
        print("  transport (send→host) ms p50/p95/p99: \(f(transport.percentile(0.5))) / \(f(transport.percentile(0.95))) / \(f(transport.percentile(0.99)))")
        print("ingest ms p50/p99: \(f(ingest.percentile(0.5))) / \(f(ingest.percentile(0.99)))")
    }
}

let options = Options(CommandLine.arguments)
var config = InkServer.Config(serviceName: "InkBridge Probe", pairingCode: options.code, sessionID: "probe-session")
config.usbPort = options.usbPort
config.wifiPort = options.wifiPort
config.wifiEnabled = options.wifi
// The probe drives clock sync harder than the app to converge quickly.
config.pingInterval = 0.5

let probe = Probe()
let server = InkServer(config: config)
server.delegate = probe
server.start()
print("probe running for \(Int(options.seconds))s; pairing code \(options.code)")
setvbuf(stdout, nil, _IOLBF, 0)

DispatchQueue.main.asyncAfter(deadline: .now() + options.seconds) {
    probe.report()
    server.stop()
    if let want = options.expectStrokes, probe.store.strokes.count < want {
        print("FAIL: expected at least \(want) strokes, got \(probe.store.strokes.count)")
        exit(1)
    }
    exit(0)
}
dispatchMain()
