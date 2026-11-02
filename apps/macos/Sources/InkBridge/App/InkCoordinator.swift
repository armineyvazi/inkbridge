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
  private(set) var sessionID: String
  private(set) lazy var storage = StorageController(coordinator: self)
  private(set) lazy var storageWindow = StorageWindowController(coordinator: self)
  let engineering = EngineeringModel()
  private(set) lazy var journal = JournalController(coordinator: self)
  private(set) lazy var journalPanel = JournalPanelController(journal: journal, storage: storage)
  private(set) lazy var journalHistory = JournalHistoryWindow(journal: journal)
  private(set) lazy var engineeringPanel = EngineeringPanelController(
    model: engineering, actions: self)
  var diagramDrag: DiagramDrag?
  var sentDiagramRevision: UInt64 = 0
  var lastDiagramSyncNs: Int64 = 0
  var lastTextEdit: (id: String, at: Date)?
  /// When the open session began (from its file when reopened). Was the app's launch time for every session.
  private(set) var sessionStarted = Date()
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

  // MARK: Displays

  /// The display the user last clicked on (follow-mouse mode).
  private var followedDisplayID: CGDirectDisplayID?
  private var mouseMonitors: [Any] = []

  /// Where ink, Studio Canvas and the toolbar are shown.
  var targetScreen: NSScreen? {
    if model.followMouse, let id = followedDisplayID,
      let s = NSScreen.screens.first(where: { DisplayManager.displayID(of: $0) == id })
    {
      return s
    }
    return DisplayManager.screen(for: model.displayID)
  }

  /// Follows clicks across monitors. Mouse-button monitors need no special
  /// permission (unlike key monitors). Global sees clicks in other apps; local
  /// sees clicks on InkBridge's own windows (Studio Canvas catches clicks).
  private func startFollowingMouse() {
    followedDisplayID = DisplayManager.screenUnderMouse().flatMap(DisplayManager.displayID(of:))
    let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
    if let g = NSEvent.addGlobalMonitorForEvents(
      matching: mask, handler: { [weak self] _ in self?.mouseClicked() })
    {
      mouseMonitors.append(g)
    }
    if let l = NSEvent.addLocalMonitorForEvents(
      matching: mask,
      handler: { [weak self] e in
        self?.mouseClicked()
        return e
      })
    {
      mouseMonitors.append(l)
    }
  }

  /// Single derived view of what the app is doing. Prefer this over reading the
  /// source flags independently (journal / engineering / background / pointer / ink).
  var workspace: Workspace {
    Workspace.resolve(
      background: store.background.mode,
      pointer: model.pointerMode,
      engineering: engineering.active,
      journalActive: journal.active,
      journalHidden: journal.hidden,
      inkVisible: model.overlayVisible
    )
  }

  var interaction: WindowInteraction { workspace.interaction }

  /// Ends any in-flight mouse / diagram gesture. Call before every mode transition
  /// so a mid-drag switch cannot leave a stuck stroke or an uncommitted diagram preview.
  func cancelGestures() {
    if mouseStrokes.activeID != nil { finishMouseStroke() }
    lastPanPoint = nil
    cancelDiagramGesture()
  }

  /// Pushes the interaction policy into the window and view.
  func applyInteraction() {
    let ws = workspace
    let w = ws.interaction
    overlayWindow?.apply(w, studio: ws.usesStudioChrome)
    overlayView?.crosshair = w.mouseDraws
    // Never steal focus while the canvas is ordered out (journal put away, ink hidden).
    guard ws.canvasOnScreen else { return }
    // A studio surface takes the keyboard so Esc / ⌘Z work; the overlay never does.
    if w.canBecomeKey, let win = overlayWindow {
      NSApp.activate(ignoringOtherApps: true)
      win.makeKey()
      win.makeFirstResponder(overlayView)
    }
  }

  func setPointerMode(_ mode: PointerMode) {
    cancelGestures()
    // Engineering owns the mouse as a pointer; ignore Draw while it is active.
    if engineering.active, mode == .draw { return }
    model.pointerMode = mode
    applyInteraction()
  }

  // MARK: Mouse drawing, pan, zoom (Studio Canvas and overlay draw mode)

  private var mouseStrokes = MouseStrokeBuilder()
  private var lastPanPoint: CGPoint?

  private func handleMouse(_ e: OverlayView.MouseEvent) {
    if engineering.active {
      handleDiagramMouse(e)
      return
    }
    let w = interaction
    let mapper = overlayView.mapper
    switch e {
    case .down(let p):
      if w.mouseDraws {
        if case .begin(let id, let point) = mouseStrokes.down(
          p, mapper: mapper, t: monotonicNowNs())
        {
          let (tool, style) = resolveInCanvasUnits(model.tool)
          store.begin(id: id, tool: tool, style: style, point: point)
          overlayView.strokeDidUpdate(id, added: 1)
        }
      } else if w.mousePans {
        lastPanPoint = p
      }
    case .drag(let p):
      if w.mouseDraws,
        case .append(let id, let pts)? = mouseStrokes.drag(p, mapper: mapper, t: monotonicNowNs())
      {
        if store.append(id: id, points: pts) != nil {
          if store.active[id]?.tool == .eraser {
            overlayView.needsDisplay = true
          } else {
            overlayView.strokeDidUpdate(id, added: pts.count)
          }
        }
      } else if w.mousePans, let last = lastPanPoint {
        pan(p.x - last.x, p.y - last.y)
        lastPanPoint = p
      }
    case .up:
      finishMouseStroke()
      lastPanPoint = nil
    }
  }

  private func finishMouseStroke() {
    guard case .end(let id)? = mouseStrokes.up() else { return }
    store.end(id: id)
    overlayView.needsDisplay = true
    refreshEditState()
    syncDocument()  // the tablet receives Mac strokes as document diffs
  }

  /// Moves the view by a drag/scroll delta in view points (content follows the pointer).
  func pan(_ dx: CGFloat, _ dy: CGFloat) {
    let scale = max(overlayView.mapper.scale, 1e-6)
    var v = ingestor.viewport
    v.x -= Double(dx) / scale
    v.y -= Double(dy) / scale
    setViewport(v)
  }

  func zoom(_ factor: Double, at p: CGPoint) {
    let v = ingestor.viewport
    let c = overlayView.mapper.unmap(p)
    // `zoomed(by:focus:)` takes the focus in tablet view px.
    let focus = CGPoint(x: (c.x - v.x) * v.zoom, y: (c.y - v.y) * v.zoom)
    setViewport(v.zoomed(by: factor, focus: focus))
  }

  /// Keys while the studio has focus. Global ⌃⌥ shortcuts keep working everywhere.
  private func handleKey(_ e: NSEvent) -> Bool {
    if engineering.active, handleDiagramKey(e) { return true }
    let cmd = e.modifierFlags.contains(.command)
    switch (e.keyCode, cmd) {
    case (53, _):  // Esc
      if workspace.escapeHidesJournal {
        journal.hide()
      } else if engineering.active {
        setEngineering(false)
      } else {
        setBackground(
          CanvasBackground(
            mode: .overlay, color: store.background.color, pattern: store.background.pattern))
      }
    case (6, true):  // ⌘Z / ⇧⌘Z
      e.modifierFlags.contains(.shift) ? redo() : undo()
    case (2, false): setPointerMode(model.pointerMode == .draw ? .pointer : .draw)  // D
    case (24, _), (69, _):
      zoom(1.25, at: CGPoint(x: overlayView.bounds.midX, y: overlayView.bounds.midY))  // + / =
    case (27, _), (78, _):
      zoom(0.8, at: CGPoint(x: overlayView.bounds.midX, y: overlayView.bounds.midY))  // -
    case (29, false): homeView()  // 0
    default: return false
    }
    return true
  }

  private func mouseClicked() {
    // Only a click-through overlay may follow the user's clicks to another display;
    // an opaque or click-catching surface would jump onto the monitor they want to use.
    guard interaction.followsClicks else { return }
    guard model.followMouse, let screen = DisplayManager.screenUnderMouse(),
      let id = DisplayManager.displayID(of: screen), id != followedDisplayID
    else { return }
    followedDisplayID = id
    relayoutOverlay()
  }

  /// Pins ink to one display (nil = follow the mouse).
  func setDisplay(_ id: CGDirectDisplayID?) {
    if let id {
      model.followMouse = false
      model.displayID = id
    } else {
      model.followMouse = true
      followedDisplayID = DisplayManager.screenUnderMouse().flatMap(DisplayManager.displayID(of:))
    }
    relayoutOverlay()
  }

  let pairedDevices: PairedDevices
  let identity: HostIdentity?
  private lazy var networkWatcher = NetworkWatcher { [weak self] in
    self?.server.restartWifiListener()
  }
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
    pairedDevices = PairedDevices(
      url: Self.supportDirectory.appendingPathComponent("paired-devices.json"))
    do {
      identity = try HostIdentity.loadOrCreate(
        in: Self.supportDirectory.appendingPathComponent("Identity"))
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
      guard let self else {
        return (tool, StrokeStyle(color: .black, width: 3, pressureSensitive: true))
      }
      return self.resolveInCanvasUnits(tool)
    }
    startFollowingMouse()
    buildOverlay()
    toolbar = ToolbarController(model: model, actions: self)
    toolbar.start(on: targetScreen)
    registerHotKeys()
    observeModel()
    server.start()
    networkWatcher.start()
    _ = storage  // load storage config, create the active project
    _ = journalHistory  // registers History opener for tablet / crash-recovery journal opens
    autosaveTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
      self?.autosave()
    }
    NotificationCenter.default.addObserver(
      self, selector: #selector(screensChanged),
      name: NSApplication.didChangeScreenParametersNotification, object: nil)
  }

  func stop() {
    // Quitting: write synchronously so the data is on disk before the process ends.
    journal.flushPage()
    try? storage.saveNow()
    server.stop()
  }

  var activePeer: PeerInfo? { arbiter.activeID.flatMap { peers[$0] } }

  /// Tool sizes are canvas px, the unit strokes are stored in, so they go on the
  /// stroke unchanged. (Until v0.4 they were Mac screen points divided by the overlay's
  /// scale, which made the same setting thicker or thinner on the page depending on the
  /// zoom and on which Mac display showed the overlay.)
  private func resolveInCanvasUnits(_ tool: Tool) -> (Tool, StrokeStyle) {
    let pressure = activePeer?.hello.capabilities.pressure ?? true
    return model.resolve(tool, devicePressure: pressure)
  }

  // MARK: Overlay

  private func buildOverlay() {
    guard let screen = targetScreen else { return }
    overlayView = OverlayView(store: store, mapper: mapper(for: screen))
    overlayView.onDraw = { [weak self] ns in self?.didDraw(at: ns) }
    overlayWindow = OverlayWindow(screen: screen, content: overlayView)
    overlayView.onMouse = { [weak self] e in self?.handleMouse(e) }
    overlayView.onPan = { [weak self] dx, dy in self?.pan(dx, dy) }
    overlayView.onZoom = { [weak self] f, p in self?.zoom(f, at: p) }
    overlayView.onKey = { [weak self] e in self?.handleKey(e) ?? false }
    overlayView.drawUnderInk = { [weak self] ctx, mapper, dirty in
      self?.drawDiagram(ctx, mapper, dirty: dirty)
      self?.journal.drawTimes(ctx, mapper, dirty: dirty)
    }
    applyInteraction()
    overlayWindow?.orderFrontRegardless()
    updateEraserRadius()
  }

  private func mapper(for screen: NSScreen) -> CoordinateMapper {
    CoordinateMapper(
      canvas: screen.frame.size, surface: ingestor.surface, viewport: ingestor.viewport,
      fit: model.fit)
  }

  @objc private func screensChanged() {
    relayoutOverlay()
  }

  /// Takes the canvas window off screen (or brings it back) without touching the
  /// document: used to put the Daily Journal away. Ink from the tablet keeps
  /// arriving in the store and keeps being saved while the window is out.
  func setCanvasHidden(_ hidden: Bool) {
    if hidden {
      overlayWindow?.orderOut(nil)
    } else {
      relayoutOverlay()
      overlayWindow?.orderFrontRegardless()
      applyInteraction()
      overlayView?.invalidateCache()
    }
  }

  func relayoutOverlay() {
    guard let screen = targetScreen, let overlayWindow else { return }
    overlayWindow.move(to: screen)
    overlayView.mapper = mapper(for: screen)
    model.viewport = ingestor.viewport
    updateEraserRadius()
    toolbar?.screenChanged(targetScreen)
    // Keep floating panels on the same display as the canvas.
    if engineering.active { engineeringPanel.place(on: screen) }
    if journal.active, !journal.hidden { journalPanel.place(on: screen) }
  }

  /// The eraser size is its radius in canvas px.
  private func updateEraserRadius() {
    store.eraserRadius = model.eraserSize
  }

  // MARK: Tool settings (shared with the tablet)

  /// Bumped on every change; the tablet ignores nothing based on it, it is for diagnostics/tests.
  private(set) var toolRevision: UInt64 = 0
  /// Last `tool.request` seq applied, per device stream (one per tablet app process).
  private var toolAcks: [String: UInt64] = [:]

  /// A tablet asked to change the tool or sizes. Applied in arrival order, so the
  /// latest change wins wherever it came from; the answer goes to every tablet.
  func applyToolRequest(seq: UInt64, tool: Tool?, sizes: [Tool: Double], from peer: PeerInfo) {
    toolAcks[peer.hello.streamID] = seq
    var t = model.toolSettings
    if let tool { t.tool = tool }
    for (k, v) in sizes { t.setSize(k, v) }
    if t != model.toolSettings {
      model.toolSettings = t  // the observer broadcasts
      // Hit-testing must see the new radius before the next stroke.begin arrives.
      updateEraserRadius()
    } else {
      sendToolState(to: peer)
    }
  }

  func sendToolState(to peer: PeerInfo) {
    server.send(
      .toolState(
        model.toolSettings, revision: toolRevision, ack: toolAcks[peer.hello.streamID] ?? 0),
      to: peer.id)
  }

  private var toolBroadcastPending = false

  /// One `tool.state` per run-loop turn, however many properties changed together.
  private func toolSettingsChanged() {
    updateEraserRadius()
    guard !toolBroadcastPending else { return }
    toolBroadcastPending = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.toolBroadcastPending = false
      self.toolRevision += 1
      for p in self.peers.values { self.sendToolState(to: p) }
    }
  }

  // MARK: Model observation

  private func observeModel() {
    model.$wifiEnabled.dropFirst().sink { [weak self] in self?.server.setWifiEnabled($0) }.store(
      in: &bag)
    model.$transportPreference.dropFirst().sink { [weak self] p in
      guard let self else { return }
      let before = self.arbiter.activeID
      if self.arbiter.setPreference(p) != before { self.activePeerChanged() }
    }.store(in: &bag)
    model.$fit.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in self?.relayoutOverlay()
    }.store(in: &bag)
    model.$displayID.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in
      self?.relayoutOverlay()
    }.store(in: &bag)
    model.$followMouse.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in
      self?.relayoutOverlay()
    }.store(in: &bag)
    // Any tool or size change, from the toolbar, a hotkey, the journal or a tablet.
    // Published fires before the property is set, so read the model on the next turn.
    Publishers.Merge4(
      model.$tool.map { _ in () }, model.$penWidth.map { _ in () },
      model.$highlighterWidth.map { _ in () }, model.$eraserSize.map { _ in () }
    )
    .dropFirst(4).receive(on: RunLoop.main)
    .sink { [weak self] in self?.toolSettingsChanged() }.store(in: &bag)
  }

  func refreshEditState() {
    model.canUndo = store.canUndo
    model.canRedo = store.canRedo
    storage.documentChanged()
    journal.documentChanged()
  }

  // MARK: Document sync (host → tablet)

  /// Sends the active tablet whatever changed in the document.
  func syncDocument() {
    guard let peer = activePeer else { return }
    send(sync.diff(store.strokes), to: peer)
    syncBackground()
  }

  /// Tells the active tablet the storage state (project, session, save status).
  func sendStorageState() {
    guard let peer = activePeer else { return }
    server.send(.storageState(storage.state()), to: peer.id)
  }

  /// Puts back a document snapshotted in memory (leaving the journal): same
  /// strokes, background, diagram, undo/redo, session and view.
  func restoreSession(
    id: String, snapshot: StrokeStore.Snapshot, viewport: Viewport, startedAt: Date
  ) {
    sessionStarted = startedAt
    storage.documentReplaced()
    store.restore(snapshot)
    sessionID = id
    server.setSessionID(id)
    ingestor.viewport = viewport
    engineering.selection = []
    engineering.diagramVersion += 1
    backgroundDidChange()
    relayoutOverlay()
    overlayView?.invalidateCache()
    refreshEditState()
    autosavedRevision = store.documentVersion
    if let peer = activePeer {
      sync.reset()
      send(sync.resync(store.strokes), to: peer)
      sentBackgroundRevision = nil
      syncBackground()
      server.send(.canvasViewport(viewport), to: peer.id)
      syncDiagram(force: true)
    }
  }

  /// Replaces the open document (new or opened session). The tablet gets a full resync.
  func startSession(
    id: String, strokes: [Stroke], background: CanvasBackground, viewport: Viewport,
    diagram: Diagram = Diagram(),
    startedAt: Date = Date()
  ) {
    sessionStarted = startedAt
    storage.documentReplaced()
    store.endAll()
    store.load(strokes, background: background, diagram: diagram)
    engineering.selection = []
    engineering.diagramVersion += 1
    sessionID = id
    server.setSessionID(id)
    ingestor.viewport = viewport
    backgroundDidChange()
    relayoutOverlay()
    overlayView?.invalidateCache()
    refreshEditState()
    autosavedRevision = store.documentVersion
    if let peer = activePeer {
      sync.reset()
      send(sync.resync(store.strokes), to: peer)
      sentBackgroundRevision = nil
      syncBackground()
      server.send(.canvasViewport(viewport), to: peer.id)
      syncDiagram(force: true)
    }
  }

  /// Revision of the background the active tablet last received.
  private var sentBackgroundRevision: UInt64?

  /// Sends the background layer if the tablet has an older revision.
  func syncBackground(force: Bool = false) {
    guard let peer = activePeer, force || sentBackgroundRevision != store.backgroundRevision else {
      return
    }
    sentBackgroundRevision = store.backgroundRevision
    server.send(
      .canvasBackground(store.background, revision: store.backgroundRevision), to: peer.id)
  }

  /// Mirrors the store's background into the views and window. Cheap: no stroke re-render.
  func backgroundDidChange() {
    let bg = store.background
    guard model.background != bg else { return }
    model.background = bg
    if bg.mode == .studio { model.lastStudioColor = bg.color }
    applyInteraction()
    overlayView?.needsDisplay = true
  }

  /// The single entry point for background changes (toolbar, hotkeys, tablet).
  /// Engineering and Journal own a studio surface: Overlay is refused while they are active
  /// so the window cannot become a transparent click-catcher over the desktop.
  func setBackground(_ bg: CanvasBackground) {
    var next = bg
    if next.mode == .overlay, !workspace.allowsOverlayBackground {
      next.mode = .studio
    }
    cancelGestures()
    guard store.setBackground(next) else { return }
    backgroundDidChange()
    refreshEditState()
    syncBackground()
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
    log.info(
      "connected \(peer.hello.deviceName, privacy: .public) via \(peer.kind.rawValue, privacy: .public)"
    )
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

  func inkServer(
    _ server: InkServer, peer: PeerInfo, didReceive message: Message, receivedAtNs: Int64
  ) {
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
    case .strokeUpdated(let id, let added):
      pendingReceiveNs = pendingReceiveNs ?? receivedAtNs
      overlayView.strokeDidUpdate(id, added: added)
    case .documentChanged:
      // Tablet undo/redo/clear already mutated the store; apply the same side
      // effects a local edit() would (window chrome, diagram panel, sync).
      pendingReceiveNs = pendingReceiveNs ?? receivedAtNs
      overlayView.needsDisplay = true
      backgroundDidChange()
      diagramChanged()
      refreshEditState()
      syncDocument()
    case .surfaceChanged, .viewportChanged:
      relayoutOverlay()
    }
  }

  /// Per-message replies to the tablet that keep its mirror correct.
  private func followUp(_ message: Message, change: StrokeIngestor.Change, peer: PeerInfo) {
    switch message.payload {
    case .strokeBegin(let id, _, _, _):
      // Tell the tablet how the Mac resolved its stroke (highlighter, laser, eraser…).
      if let s = store.active[id] {
        server.send(
          .strokeStyle(
            strokeID: id, tool: s.tool, style: WireStyle(color: s.style.color, width: s.style.width)
          ), to: peer.id)
      }
    case .strokeEnd(let id):
      // The tablet already has its own stroke; diff only reports it if the Mac dropped it.
      sync.markKnown(id)
    case .storageRequest(let action, let name):
      storage.handle(action: action, name: name)
    case .journalRequest(let action, let name):
      journal.handle(action: action, name: name)
    case .toolRequest(let seq, let tool, let sizes):
      applyToolRequest(seq: seq, tool: tool, sizes: sizes, from: peer)
    case .canvasBackground(let bg, _):
      // A request from the tablet. The Mac is the single writer: apply it (one undo
      // step), then echo the result with the new revision so both sides converge,
      // even when nothing changed or a newer Mac-side change won the race.
      if store.setBackground(bg) {
        backgroundDidChange()
        refreshEditState()
      }
      syncBackground(force: true)
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

  func inkServer(
    _ server: InkServer, listener: TransportKind, didChangeState state: InkServer.ListenerState
  ) {
    let listening: Bool
    if case .listening = state { listening = true } else { listening = false }
    if listener == .usb {
      model.connection.usbListening = listening
    } else {
      model.connection.wifiListening = listening
    }
    if case .failed(let e) = state {
      model.connection.lastError = "\(listener.rawValue) listener failed: \(e)"
    }
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
      parkTimer = Timer.scheduledTimer(withTimeInterval: Self.strokeGrace, repeats: false) {
        [weak self] _ in
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
      ingestor.setSurface(
        CGSize(width: peer.hello.surfaceWidthPx, height: peer.hello.surfaceHeightPx))
      send(sync.resync(store.strokes), to: peer)
      sentBackgroundRevision = nil
      syncBackground()
      server.send(.storageState(storage.state()), to: peer.id)
      syncDiagram(force: true)
      journal.sendState()
      sendToolState(to: peer)
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
    guard case .strokePoint(_, let points) = message.payload, let last = points.last,
      let sampleHostNs = clock.hostTime(forDeviceNs: last.t)
    else { return }
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
