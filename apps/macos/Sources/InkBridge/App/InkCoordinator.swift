import AppKit
import Combine
import InkBridgeCore
import os
import SwiftUI

/// Wires the server, the drawing engine and the windows together.
///
/// Data flow: InkServer (socket queue) → delegate on main → PeerArbiter
/// decides whether the peer is active → StrokeIngestor mutates StrokeStore →
/// OverlayView invalidates the touched rect. Nothing here touches sockets
/// directly or knows which transport delivered a message.
final class InkCoordinator: NSObject {
    let model: AppModel
    let store = StrokeStore()
    private(set) lazy var ingestor = StrokeIngestor(store: store)
    private var arbiter: PeerArbiter
    private var peers: [UUID: PeerInfo] = [:]
    let server: InkServer
    let sessionID: String
    let sessionStarted = Date()
    private let log = Logger(subsystem: "app.inkbridge", category: "coordinator")

    private var overlayWindow: OverlayWindow?
    private(set) var overlayView: OverlayView!
    private var toolbar: ToolbarPanel?
    var settingsWindow: NSWindow?
    let hotKeys = HotKeyCenter()
    private var bag = Set<AnyCancellable>()
    private var autosaveTimer: Timer?
    var autosavedRevision = -1

    // Latency bookkeeping
    private var clock = ClockSync()
    private var inputLatency = LatencyStats()
    private var renderLatency = LatencyStats()
    private var pendingReceiveNs: Int64?

    init(model: AppModel, sessionID: String? = nil) {
        self.model = model
        self.sessionID = sessionID ?? Self.newSessionID()
        arbiter = PeerArbiter(preference: model.transportPreference)
        var config = InkServer.Config(
            serviceName: Host.current().localizedName ?? "Mac",
            pairingCode: model.pairingCode,
            sessionID: self.sessionID
        )
        config.wifiEnabled = model.wifiEnabled
        server = InkServer(config: config)
        super.init()
        server.delegate = self
    }

    static func newSessionID() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "session-" + f.string(from: Date())
    }

    func start() {
        ingestor.resolveTool = { [weak self] tool in
            guard let self else { return (tool, StrokeStyle(color: .black, width: 3, pressureSensitive: true)) }
            let pressure = self.activePeer?.hello.capabilities.pressure ?? true
            return self.model.resolve(tool, devicePressure: pressure)
        }
        buildOverlay()
        buildToolbar()
        registerHotKeys()
        observeModel()
        server.start()
        autosaveTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.autosave() }
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    func stop() {
        autosave()
        server.stop()
    }

    private var activePeer: PeerInfo? { arbiter.activeID.flatMap { peers[$0] } }

    // MARK: Windows

    private func buildOverlay() {
        guard let screen = DisplayManager.screen(for: model.displayID) else { return }
        overlayView = OverlayView(store: store, mapper: mapper(for: screen))
        overlayView.onDraw = { [weak self] ns in self?.didDraw(at: ns) }
        overlayWindow = OverlayWindow(screen: screen, content: overlayView)
        overlayWindow?.orderFrontRegardless()
        store.aspectRatio = overlayView.mapper.aspectRatio
    }

    private func mapper(for screen: NSScreen) -> CoordinateMapper {
        CoordinateMapper(canvas: screen.frame.size, surface: ingestor.surface, fit: model.fit)
    }

    @objc private func screensChanged() {
        relayoutOverlay()
    }

    func relayoutOverlay() {
        guard let screen = DisplayManager.screen(for: model.displayID), let overlayWindow else { return }
        overlayWindow.move(to: screen)
        overlayView.mapper = mapper(for: screen)
        store.aspectRatio = overlayView.mapper.aspectRatio
        placeToolbarIfOffscreen(on: screen)
    }

    private func buildToolbar() {
        let host = NSHostingView(rootView: ToolbarView(model: model, actions: self))
        let panel = ToolbarPanel(content: host)
        panel.setContentSize(host.fittingSize)
        if let screen = DisplayManager.screen(for: model.displayID) { placeToolbarIfOffscreen(on: screen, panel: panel) }
        panel.orderFrontRegardless()
        toolbar = panel
    }

    private func placeToolbarIfOffscreen(on screen: NSScreen, panel: ToolbarPanel? = nil) {
        guard let panel = panel ?? toolbar else { return }
        if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(panel.frame) }) && panel.frame.origin != .zero { return }
        let f = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: f.midX - panel.frame.width / 2, y: f.minY + 24))
    }

    func toggleToolbar() {
        guard let toolbar else { return }
        toolbar.isVisible ? toolbar.orderOut(nil) : toolbar.orderFrontRegardless()
    }

    var isToolbarVisible: Bool { toolbar?.isVisible ?? false }

    // MARK: Model observation

    private func observeModel() {
        model.$wifiEnabled.dropFirst().sink { [weak self] in self?.server.setWifiEnabled($0) }.store(in: &bag)
        model.$transportPreference.dropFirst().sink { [weak self] p in
            guard let self else { return }
            let before = self.arbiter.activeID
            if self.arbiter.setPreference(p) != before { self.activePeerChanged() }
        }.store(in: &bag)
        model.$fit.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in self?.relayoutOverlay() }.store(in: &bag)
        model.$displayID.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in self?.relayoutOverlay() }.store(in: &bag)
        model.$eraserRadius.sink { [weak self] r in self?.store.eraserRadius = r }.store(in: &bag)
        // The toolbar changes width with the selected tool's controls.
        model.$tool.receive(on: RunLoop.main).sink { [weak self] _ in
            guard let toolbar = self?.toolbar, let content = toolbar.contentView else { return }
            toolbar.setContentSize(content.fittingSize)
        }.store(in: &bag)
    }

    func refreshEditState() {
        model.canUndo = store.canUndo
        model.canRedo = store.canRedo
    }

    private func flash(_ message: String) {
        model.statusMessage = message
        log.info("\(message, privacy: .public)")
    }
}

// MARK: - Server events

extension InkCoordinator: InkServerDelegate {
    func inkServer(_ server: InkServer, didConnect peer: PeerInfo) {
        peers[peer.id] = peer
        let before = arbiter.activeID
        arbiter.add(.init(id: peer.id, kind: peer.kind, connectedAt: Date()))
        if arbiter.activeID != before { activePeerChanged() }
        log.info("connected \(peer.hello.deviceName, privacy: .public) via \(peer.kind.rawValue, privacy: .public)")
    }

    func inkServer(_ server: InkServer, peer: PeerInfo, didReceive message: Message, receivedAtNs: Int64) {
        guard arbiter.isActive(peer.id) else { return }
        recordInputLatency(message, receivedAt: receivedAtNs)
        switch ingestor.handle(message, streamID: peer.hello.streamID) {
        case .none:
            break
        case let .strokeUpdated(id, added):
            pendingReceiveNs = pendingReceiveNs ?? receivedAtNs
            overlayView.strokeDidUpdate(id, added: added)
        case .documentChanged:
            pendingReceiveNs = pendingReceiveNs ?? receivedAtNs
            overlayView.needsDisplay = true
            refreshEditState()
        case .surfaceChanged:
            relayoutOverlay()
        }
    }

    func inkServer(_ server: InkServer, peer: PeerInfo, didUpdateClock clock: ClockSync) {
        guard arbiter.isActive(peer.id) else { return }
        self.clock = clock
        model.rttMs = clock.lastRTTNs.map { Double($0) / 1e6 }
    }

    func inkServer(_ server: InkServer, didDisconnect peer: PeerInfo, reason: String) {
        peers.removeValue(forKey: peer.id)
        let wasActive = arbiter.isActive(peer.id)
        arbiter.remove(peer.id)
        log.info("disconnected \(peer.hello.deviceName, privacy: .public): \(reason, privacy: .public)")
        model.connection.lastError = reason
        if wasActive { activePeerChanged() }
    }

    func inkServer(_ server: InkServer, listener: TransportKind, didChangeState state: InkServer.ListenerState) {
        let listening: Bool
        if case .listening = state { listening = true } else { listening = false }
        if listener == .usb { model.connection.usbListening = listening } else { model.connection.wifiListening = listening }
        if case .failed(let e) = state { model.connection.lastError = "\(listener.rawValue) listener failed: \(e)" }
    }

    /// Strokes in progress belong to the old link; finish them so nothing dangles.
    private func activePeerChanged() {
        store.endAll()
        overlayView.needsDisplay = true
        refreshEditState()
        clock.reset()
        inputLatency.reset()
        let peer = activePeer
        model.connection.deviceName = peer?.hello.deviceName
        model.connection.transport = peer?.kind
        model.rttMs = nil
        model.inputLatencyMs = nil
        if let peer {
            _ = ingestor.setSurface(CGSize(width: peer.hello.surfaceWidthPx, height: peer.hello.surfaceHeightPx))
        }
        relayoutOverlay()
    }

    // MARK: Latency

    private func recordInputLatency(_ message: Message, receivedAt: Int64) {
        guard case let .strokePoint(_, points) = message.payload, let last = points.last,
              let sampleHostNs = clock.hostTime(forDeviceNs: last.t) else { return }
        let ms = Double(receivedAt - sampleHostNs) / 1e6
        // Ignore nonsense from a not-yet-converged clock estimate.
        guard ms > -5, ms < 2_000 else { return }
        inputLatency.add(max(ms, 0))
        if inputLatency.count % 30 == 0 { model.inputLatencyMs = inputLatency.percentile(0.5) }
    }

    private func didDraw(at ns: Int64) {
        guard let received = pendingReceiveNs else { return }
        pendingReceiveNs = nil
        renderLatency.add(Double(ns - received) / 1e6)
        if renderLatency.count % 30 == 0 { model.renderLatencyMs = renderLatency.percentile(0.5) }
    }

    func diagnosticReport() -> String {
        func f(_ v: Double?) -> String { v.map { String(format: "%.2f", $0) } ?? "n/a" }
        let info = Bundle.main.infoDictionary
        return """
        InkBridge diagnostic report
        generated: \(ISO8601DateFormatter().string(from: Date()))
        app version: \(info?["CFBundleShortVersionString"] as? String ?? "dev")
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        protocol version: \(inkProtocolVersion)
        session: \(sessionID)
        usb listener: \(model.connection.usbListening ? "listening :8765" : "not listening")
        wifi listener: \(model.connection.wifiListening ? "listening :8766" : "not listening")
        transport preference: \(model.transportPreference.rawValue)
        connected peers: \(peers.values.map { "\($0.hello.deviceName) [\($0.kind.rawValue)] api=\($0.hello.androidAPI) surface=\($0.hello.surfaceWidthPx)x\($0.hello.surfaceHeightPx) pressure=\($0.hello.capabilities.pressure)" }.joined(separator: "; "))
        active peer: \(activePeer?.hello.deviceName ?? "none")
        last error: \(model.connection.lastError ?? "none")
        rtt ms (last): \(f(model.rttMs))
        clock offset ns: \(clock.offsetNs.map(String.init) ?? "n/a")
        pen→mac ms p50/p95: \(f(inputLatency.percentile(0.5))) / \(f(inputLatency.percentile(0.95))) (n=\(inputLatency.count))
        receive→draw ms p50/p95: \(f(renderLatency.percentile(0.5))) / \(f(renderLatency.percentile(0.95))) (n=\(renderLatency.count))
        duplicate/stale messages dropped: \(ingestor.droppedCount)
        strokes: \(store.strokes.count) committed, \(store.active.count) active
        displays: \(DisplayManager.displays.map { "\($0.name) \(Int($0.size.width))x\(Int($0.size.height))" }.joined(separator: "; "))

        """
    }
}
