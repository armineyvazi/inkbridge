import AppKit
import Combine
import InkBridgeCore
import os

/// Wires the server, the drawing engine, document sync and the windows.
///
/// Inbound: InkServer (socket queue) → delegate on main → PeerArbiter decides
/// whether the peer is active → StrokeIngestor mutates StrokeStore →
/// OverlayView invalidates the touched rect.
///
/// Outbound (ADR-006): after every document change `DocumentSync` computes
/// what the active tablet is missing or must drop, and only that is sent.
final class InkCoordinator: NSObject {
    let model: AppModel
    let store = StrokeStore()
    private(set) lazy var ingestor = StrokeIngestor(store: store)
    private var arbiter: PeerArbiter
    private var peers: [UUID: PeerInfo] = [:]
    private var sync = DocumentSync()
    let server: InkServer
    let sessionID: String
    let sessionStarted = Date()
    let log = Logger(subsystem: "app.inkbridge", category: "coordinator")

    private var overlayWindow: OverlayWindow?
    private(set) var overlayView: OverlayView!
    private(set) var toolbar: ToolbarController!
    private(set) lazy var exporter = ExportController(coordinator: self)
    private(set) lazy var connectDevice = ConnectDeviceController(coordinator: self)
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
    private var lastActiveStream: String?

    let pairedDevices: PairedDevices
    let identity: HostIdentity?
    private lazy var networkWatcher = NetworkWatcher { [weak self] in self?.server.restartWifiListener() }
    /// The stream of the tablet that was active before a drop; its strokes in
    /// progress are kept open for `strokeGrace` so a reconnect can finish them.
    private var parkedStream: String?
    private var parkTimer: Timer?
    private static let strokeGrace: TimeInterval = 10
    /// Peers that connected while a stroke was in progress; elected once it ends,
    /// so a transport switch never cuts a stroke in half.
    private var deferredPeers: [PeerArbiter.Peer] = []

    init(model: AppModel, sessionID: String? = nil) {
        self.model = model
        self.sessionID = sessionID ?? Self.newSessionID()
        arbiter = PeerArbiter(preference: model.transportPreference)
        pairedDevices = PairedDevices(url: Self.supportDirectory.appendingPathComponent("paired-devices.json"))
        do {
            identity = try HostIdentity.loadOrCreate(in: Self.supportDirectory.appendingPathComponent("Identity"))
        } catch {
            identity = nil
            model.connection.lastError = "Wi-Fi unavailable: could not create the TLS identity (\(error))"
        }
        var config = InkServer.Config(
            serviceName: Host.current().localizedName ?? "Mac",
            sessionID: self.sessionID,
            identity: identity,
            pairedDevices: pairedDevices
        )
        config.wifiEnabled = model.wifiEnabled && identity != nil
        server = InkServer(config: config)
        model.hostFingerprint = identity?.shortFingerprint ?? ""
        model.hostFingerprintHex = identity?.fingerprint.hexString ?? ""
        model.hostID = config.hostID
        model.pairedDevices = pairedDevices.all
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
            return self.resolveInCanvasUnits(tool)
        }
        buildOverlay()
        toolbar = ToolbarController(model: model, actions: self)
        toolbar.start(on: DisplayManager.screen(for: model.displayID))
        registerHotKeys()
        observeModel()
        server.start()
        networkWatcher.start()
        autosaveTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.autosave() }
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    func stop() {
        autosave()
        server.stop()
    }

    var activePeer: PeerInfo? { arbiter.activeID.flatMap { peers[$0] } }

    /// Toolbar widths are on-screen points; stored strokes use canvas px, so a
    /// line looks as thick as selected at the current zoom and scales after.
    private func resolveInCanvasUnits(_ tool: Tool) -> (Tool, StrokeStyle) {
        let pressure = activePeer?.hello.capabilities.pressure ?? true
        var (resolved, style) = model.resolve(tool, devicePressure: pressure)
        style.width /= max(overlayView.mapper.scale, 1e-6)
        return (resolved, style)
    }

    // MARK: Overlay

    private func buildOverlay() {
        guard let screen = DisplayManager.screen(for: model.displayID) else { return }
        overlayView = OverlayView(store: store, mapper: mapper(for: screen))
        overlayView.onDraw = { [weak self] ns in self?.didDraw(at: ns) }
        overlayWindow = OverlayWindow(screen: screen, content: overlayView)
        overlayWindow?.orderFrontRegardless()
        updateEraserRadius()
    }

    private func mapper(for screen: NSScreen) -> CoordinateMapper {
        CoordinateMapper(canvas: screen.frame.size, surface: ingestor.surface, viewport: ingestor.viewport, fit: model.fit)
    }

    @objc private func screensChanged() {
        relayoutOverlay()
    }

    func relayoutOverlay() {
        guard let screen = DisplayManager.screen(for: model.displayID), let overlayWindow else { return }
        overlayWindow.move(to: screen)
        overlayView.mapper = mapper(for: screen)
        model.viewport = ingestor.viewport
        updateEraserRadius()
        toolbar?.screenChanged(DisplayManager.screen(for: model.displayID))
    }

    /// The eraser size is a fraction of the display height; convert to canvas px.
    private func updateEraserRadius() {
        guard let overlayView else { return }
        store.eraserRadius = model.eraserRadius * Double(overlayView.mapper.canvas.height) / max(overlayView.mapper.scale, 1e-6)
    }

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
        model.$eraserRadius.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in self?.updateEraserRadius() }.store(in: &bag)
    }

    func refreshEditState() {
        model.canUndo = store.canUndo
        model.canRedo = store.canRedo
    }

    // MARK: Document sync (host → tablet)

    /// Sends the active tablet whatever changed in the document.
    func syncDocument() {
        guard let peer = activePeer else { return }
        send(sync.diff(store.strokes), to: peer)
    }

    /// Moves the shared view (Mac-side Fit all / Home) and tells the tablet.
    func setViewport(_ viewport: Viewport) {
        ingestor.viewport = viewport
        relayoutOverlay()
        if let peer = activePeer { server.send(.canvasViewport(viewport), to: peer.id) }
    }

    func fitAll() {
        guard let bounds = store.contentBounds else { return setViewport(.home) }
        setViewport(.fitting(bounds, in: ingestor.surface))
    }

    private func send(_ payloads: [Payload], to peer: PeerInfo) {
        for p in payloads { server.send(p, to: peer.id) }
    }
}

// MARK: - Server events

extension InkCoordinator: InkServerDelegate {
    func inkServer(_ server: InkServer, didConnect peer: PeerInfo) {
        peers[peer.id] = peer
        log.info("connected \(peer.hello.deviceName, privacy: .public) via \(peer.kind.rawValue, privacy: .public)")
        let entry = PeerArbiter.Peer(id: peer.id, kind: peer.kind, connectedAt: Date())
        // A second link from the tablet that is drawing right now waits until the stroke ends.
        if activePeer != nil && !store.active.isEmpty {
            deferredPeers.append(entry)
            return
        }
        elect(entry)
        model.pairedDevices = pairedDevices.all
    }

    private func elect(_ entry: PeerArbiter.Peer) {
        let before = arbiter.activeID
        arbiter.add(entry)
        if arbiter.activeID != before { activePeerChanged() }
    }

    func inkServer(_ server: InkServer, didPair device: PairedDevice) {
        model.pairedDevices = pairedDevices.all
        model.justPaired = device
        model.statusMessage = "Paired with \(device.name)"
    }

    func inkServer(_ server: InkServer, pairingTicketChanged ticket: PairingTicket?) {
        model.pairingTicket = ticket
    }

    func inkServer(_ server: InkServer, peer: PeerInfo, didReceive message: Message, receivedAtNs: Int64) {
        guard arbiter.isActive(peer.id) else { return }
        recordInputLatency(message, receivedAt: receivedAtNs)
        let change = ingestor.handle(message, streamID: peer.hello.streamID)
        followUp(message, change: change, peer: peer)
        if !deferredPeers.isEmpty && store.active.isEmpty {
            let waiting = deferredPeers
            deferredPeers.removeAll()
            waiting.filter { peers[$0.id] != nil }.forEach(elect)
        }
        switch change {
        case .none:
            break
        case let .strokeUpdated(id, added):
            pendingReceiveNs = pendingReceiveNs ?? receivedAtNs
            overlayView.strokeDidUpdate(id, added: added)
        case .documentChanged:
            pendingReceiveNs = pendingReceiveNs ?? receivedAtNs
            overlayView.needsDisplay = true
            refreshEditState()
            syncDocument()
        case .surfaceChanged, .viewportChanged:
            relayoutOverlay()
        }
    }

    /// Per-message replies to the tablet that keep its mirror correct.
    private func followUp(_ message: Message, change: StrokeIngestor.Change, peer: PeerInfo) {
        switch message.payload {
        case let .strokeBegin(id, _, _, _):
            // Tell the tablet how the Mac resolved its stroke (highlighter, laser, eraser…).
            if let s = store.active[id] {
                server.send(.strokeStyle(strokeID: id, tool: s.tool, style: WireStyle(color: s.style.color, width: s.style.width)), to: peer.id)
            }
        case let .strokeEnd(id):
            // The tablet already has its own stroke; diff only reports it if the Mac dropped it.
            sync.markKnown(id)
        default:
            break
        }
    }

    func inkServer(_ server: InkServer, peer: PeerInfo, didUpdateClock clock: ClockSync) {
        guard arbiter.isActive(peer.id) else { return }
        self.clock = clock
        model.rttMs = clock.lastRTTNs.map { Double($0) / 1e6 }
    }

    func inkServer(_ server: InkServer, didDisconnect peer: PeerInfo, reason: String) {
        peers.removeValue(forKey: peer.id)
        deferredPeers.removeAll { $0.id == peer.id }
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

    /// Gives the new active tablet the whole document once; later changes go
    /// out as diffs.
    ///
    /// Strokes in progress: if the same tablet process comes back (same
    /// stream ID, e.g. after a Wi-Fi blip) they continue, because the tablet
    /// re-sends what the dead link lost (`resume_sequence`). A different
    /// tablet, or none for `strokeGrace`, ends them so nothing hangs open.
    private func activePeerChanged() {
        let peer = activePeer
        let stream = peer?.hello.streamID
        parkTimer?.invalidate()
        if peer == nil, !store.active.isEmpty, let previous = lastActiveStream {
            parkedStream = previous
            parkTimer = Timer.scheduledTimer(withTimeInterval: Self.strokeGrace, repeats: false) { [weak self] _ in
                guard let self else { return }
                self.parkedStream = nil
                self.store.endAll()
                self.overlayView.needsDisplay = true
                self.refreshEditState()
            }
        } else if stream == nil || stream != parkedStream && stream != lastActiveStream {
            store.endAll()
            parkedStream = nil
        } else {
            parkedStream = nil
        }
        lastActiveStream = stream ?? lastActiveStream
        overlayView.needsDisplay = true
        refreshEditState()
        clock.reset()
        inputLatency.reset()
        sync.reset()
        model.connection.deviceName = peer?.hello.deviceName
        model.connection.transport = peer?.kind
        model.connection.remote = peer.map { Self.displayAddress($0.remote) }
        if peer != nil { model.connection.lastConnectedAt = Date() }
        model.rttMs = nil
        model.inputLatencyMs = nil
        if let peer {
            ingestor.setSurface(CGSize(width: peer.hello.surfaceWidthPx, height: peer.hello.surfaceHeightPx))
            send(sync.resync(store.strokes), to: peer)
        }
        relayoutOverlay()
    }

    /// "192.168.1.20" from an endpoint description like "192.168.1.20:50211".
    static func displayAddress(_ remote: String) -> String {
        guard let colon = remote.lastIndex(of: ":"), !remote.hasPrefix("[") else { return remote }
        return String(remote[..<colon])
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
        let v = ingestor.viewport
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
        host id: \(model.hostID)
        tls fingerprint: \(model.hostFingerprint.isEmpty ? "none" : model.hostFingerprint)
        paired devices: \(model.pairedDevices.map { "\($0.name) (last seen \($0.lastSeen.map { ISO8601DateFormatter().string(from: $0) } ?? "never"))" }.joined(separator: "; "))
        connect window: \(model.pairingTicket == nil ? "closed" : "open")
        connected peers: \(peers.values.map { "\($0.hello.deviceName) [\($0.kind.rawValue)] api=\($0.hello.androidAPI) surface=\($0.hello.surfaceWidthPx)x\($0.hello.surfaceHeightPx) pressure=\($0.hello.capabilities.pressure)" }.joined(separator: "; "))
        active peer: \(activePeer?.hello.deviceName ?? "none")
        last error: \(model.connection.lastError ?? "none")
        rtt ms (last): \(f(model.rttMs))
        clock offset ns: \(clock.offsetNs.map(String.init) ?? "n/a")
        pen→mac ms p50/p95: \(f(inputLatency.percentile(0.5))) / \(f(inputLatency.percentile(0.95))) (n=\(inputLatency.count))
        receive→draw ms p50/p95: \(f(renderLatency.percentile(0.5))) / \(f(renderLatency.percentile(0.95))) (n=\(renderLatency.count))
        duplicate/stale messages dropped: \(ingestor.droppedCount)
        strokes: \(store.strokes.count) committed, \(store.active.count) active, tablet mirror \(sync.known.count)
        viewport: x=\(f(v.x)) y=\(f(v.y)) zoom=\(f(v.zoom))
        displays: \(DisplayManager.displays.map { "\($0.name) \(Int($0.size.width))x\(Int($0.size.height))" }.joined(separator: "; "))

        """
    }
}
