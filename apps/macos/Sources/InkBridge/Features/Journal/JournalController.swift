import AppKit
import Combine
import InkBridgeCore
import OSLog

/// Daily Journal: a per-day notebook you can step into and out of without
/// disturbing the open work.
///
/// Entering: the current document is saved, then snapshotted *in memory*
/// (strokes, background, diagram, undo/redo — `StrokeStore.snapshot`) along
/// with the view, tool, mouse mode and Engineering state. The day's page is
/// loaded into the same canvas. Leaving (Done / Esc / Hide / ⌃⌥N toggle): the
/// day is saved and the snapshot is restored exactly; nothing is reloaded from
/// disk.
///
/// The canvas is always forced on-screen while the journal is active so tablet
/// ink is visible on the Mac. A previous "put away" mode ordered the canvas out
/// while still routing strokes into the day folder — writing looked broken.
///
/// Days follow local calendar boundaries: a timer for the next local midnight
/// plus `NSCalendarDayChanged` (time-zone change, wake from sleep) move an
/// open "today" journal to the new day; older days stay as they were.
final class JournalController: ObservableObject {
  private static let log = Logger(subsystem: "app.inkbridge.mac", category: "journal")

  @Published private(set) var active = false
  /// Legacy flag kept for the wire protocol (`journal.state.hidden`). Always false:
  /// leaving the journal restores the previous workspace instead of ordering the
  /// canvas out while still owning the day folder.
  @Published private(set) var hidden = false
  @Published private(set) var day = JournalCalendar.dayID(for: Date())
  @Published var page = JournalPage(day: JournalCalendar.dayID(for: Date()))
  @Published var showTimes: Bool {
    didSet {
      UserDefaults.standard.set(showTimes, forKey: "journalShowTimes")
      coordinator.overlayView?.needsDisplay = true
    }
  }
  @Published private(set) var rootPath: String
  @Published private(set) var pageError: String?

  private unowned let coordinator: InkCoordinator
  /// Set by the history window so the panel can open it.
  var historyOpener: (() -> Void)?
  private var saved: Saved?
  private var midnightTimer: Timer?
  private var revision: UInt64 = 0

  private struct Saved {
    var snapshot: StrokeStore.Snapshot
    var sessionID: String
    var project: String
    var title: String
    var startedAt: Date
    var viewport: Viewport
    var tool: Tool
    var pointer: PointerMode
    var engineering: Bool
  }

  static let paper = CanvasBackground.studio(RGBA(0.99, 0.985, 0.965), pattern: .dots)

  init(coordinator: InkCoordinator) {
    self.coordinator = coordinator
    rootPath = UserDefaults.standard.string(forKey: "journalRoot") ?? JournalStore.defaultRoot.path
    showTimes = UserDefaults.standard.object(forKey: "journalShowTimes") as? Bool ?? true
    NotificationCenter.default.addObserver(
      forName: .NSCalendarDayChanged, object: nil, queue: .main
    ) { [weak self] _ in
      self?.dayMayHaveChanged()
    }
    NotificationCenter.default.addObserver(
      forName: NSNotification.Name.NSSystemTimeZoneDidChange, object: nil, queue: .main
    ) { [weak self] _ in
      NSTimeZone.resetSystemTimeZone()
      self?.dayMayHaveChanged()
    }
  }

  var store: JournalStore { JournalStore(root: URL(fileURLWithPath: rootPath)) }
  var dayDir: URL { store.dayDir(day) }
  var isToday: Bool { day == JournalCalendar.dayID(for: Date()) }

  // MARK: Open / close

  /// The 📖 button and ⌃⌥N: open today's journal, or leave it and restore the previous workspace.
  func toggle() {
    if active { close() } else { open() }
  }

  /// Leaves the journal and restores the previous workspace (same as Done).
  ///
  /// Historically this ordered the canvas out while keeping the day folder as the
  /// save target ("put away"). That made BOOX writing look broken on the Mac and
  /// prevented returning to the prior workspace. Hide / Esc / tablet "Hide on Mac"
  /// all leave now.
  func hide() { close() }

  /// Re-opens the journal if it was left (tablet "Show on Mac" after a leave).
  func show() {
    if active {
      ensureCanvasOnScreen()
      coordinator.journalPanel.show(on: coordinator.targetScreen)
      sendState()
    } else {
      open()
    }
  }

  /// Opens a day (today by default). Asks once where journal files should live.
  func open(day requested: String? = nil) {
    if !UserDefaults.standard.bool(forKey: "journalRootChosen") && !chooseLocationFirstTime() {
      return
    }
    let target = requested ?? JournalCalendar.dayID(for: Date())
    guard JournalCalendar.isValid(target) else { return }
    if active {
      ensureCanvasOnScreen()
      return switchDay(to: target)
    }
    let c = coordinator
    do { try c.storage.saveNow() } catch {
      // The open work could not be saved: do not replace it.
      c.model.statusMessage = "Daily Journal not opened: \(error.localizedDescription)"
      Self.log.error("open refused: save failed \(error.localizedDescription, privacy: .public)")
      return
    }
    saved = Saved(
      snapshot: c.store.snapshot(), sessionID: c.sessionID, project: c.storage.activeProject,
      title: c.storage.sessionTitle, startedAt: c.sessionStarted, viewport: c.ingestor.viewport,
      tool: c.model.tool,
      pointer: c.model.pointerMode, engineering: c.engineering.active)
    if c.engineering.active { c.setEngineering(false) }
    active = true
    hidden = false
    c.model.journalActive = true
    c.model.journalHidden = false
    load(target)
    ensureCanvasOnScreen()
    c.journalPanel.show(on: c.targetScreen)
    scheduleMidnight()
    Self.log.info(
      "opened day=\(target, privacy: .public) session=\(c.sessionID, privacy: .public) strokes=\(c.store.strokes.count)"
    )
  }

  func close() {
    guard active, let s = saved else { return }
    let c = coordinator
    let leaving = day
    savePage()
    flushPage()
    try? c.storage.saveNow()
    hidden = false
    c.model.journalHidden = false
    active = false
    c.model.journalActive = false
    midnightTimer?.invalidate()
    c.journalPanel.hide()
    // Back to exactly what was open: same document object state, undo history, view and tools.
    c.storage.journalDir = nil
    // Title first: restoring announces the storage state, which must not pair the work with the journal's title.
    c.storage.sessionTitle = s.title
    c.restoreSession(
      id: s.sessionID, snapshot: s.snapshot, viewport: s.viewport, startedAt: s.startedAt)
    c.storage.restore(project: s.project, title: s.title)
    // Crash recovery must reopen the work, not the journal that was just closed.
    UserDefaults.standard.set(s.project, forKey: "lastSessionProject")
    UserDefaults.standard.set(s.sessionID, forKey: "lastSessionID")
    c.model.tool = s.tool
    c.setPointerMode(s.pointer)
    // Always restore: Engineering left on inside the journal must turn off with Done.
    c.setEngineering(s.engineering)
    ensureCanvasOnScreen()
    saved = nil
    sendState()
    Self.log.info(
      "closed day=\(leaving, privacy: .public) restoredSession=\(s.sessionID, privacy: .public)"
    )
  }

  /// Forces the drawing window on-screen and redraws. Journal open/show must call this:
  /// "Hide ink" (⌃⌥O) or a previous put-away can leave the window ordered out while the
  /// panel is visible, so tablet strokes update the store but never appear.
  private func ensureCanvasOnScreen() {
    let c = coordinator
    c.cancelGestures()
    if !c.model.overlayVisible {
      c.model.overlayVisible = true
    }
    c.setCanvasHidden(false)
    c.applyInteraction()
    c.overlayView?.isHidden = false
    c.overlayView?.invalidateCache()
    c.overlayView?.needsDisplay = true
  }

  func switchDay(to target: String) {
    guard active, target != day, JournalCalendar.isValid(target) else { return }
    savePage()
    flushPage()
    try? coordinator.storage.saveNow()
    load(target)
  }

  func step(_ days: Int) {
    if let d = JournalCalendar.offset(day, by: days) { switchDay(to: d) }
  }

  /// Loads `target` into the canvas: its ink (if any) and its page.
  private func load(_ target: String) {
    let c = coordinator
    day = target
    let dir = store.dayDir(target)
    page = store.loadPage(target)
    var strokes: [Stroke] = []
    var bg = Self.paper
    var viewport = Viewport.home
    var started = Date()
    let sessionURL = dir.appendingPathComponent("session.json")
    if FileManager.default.fileExists(atPath: sessionURL.path) {
      do {
        let (meta, s) = try SessionArchive.load(from: dir)
        strokes = s
        bg = meta.background ?? Self.paper
        viewport = meta.viewport
        started = meta.startedAt
        pageError = nil
      } catch {
        // Keep the typed page; surface the ink load failure instead of silently drawing blank.
        pageError = "Could not load ink for \(target): \(error.localizedDescription)"
        Self.log.error(
          "load ink failed day=\(target, privacy: .public) err=\(error.localizedDescription, privacy: .public)"
        )
      }
    }
    c.storage.journalDir = dir
    c.startSession(
      id: "journal-\(target)", strokes: strokes, background: bg, viewport: viewport,
      startedAt: started)
    // Seed incremental-save state from the day folder *after* the document is replaced.
    c.storage.enterJournal(
      title: page.title.isEmpty ? "Journal \(target)" : page.title, dir: dir)
    knownInk = Set(strokes.map(\.id))
    refreshAnchors()
    ensureCanvasOnScreen()
    sendState()
    Self.log.info(
      "loaded day=\(target, privacy: .public) strokes=\(strokes.count) entries=\(self.page.entries.count)"
    )
  }

  // MARK: Day boundaries

  private func scheduleMidnight() {
    midnightTimer?.invalidate()
    let at = JournalCalendar.nextMidnight(after: Date()).addingTimeInterval(1)
    let t = Timer(fire: at, interval: 0, repeats: false) { [weak self] _ in
      self?.dayMayHaveChanged()
    }
    RunLoop.main.add(t, forMode: .common)
    midnightTimer = t
  }

  /// If "today" was open and the calendar day changed, move to the new day.
  /// A deliberately opened older day stays open.
  func dayMayHaveChanged(now: Date = Date()) {
    guard active else { return }
    let today = JournalCalendar.dayID(for: now)
    if today != day, let yesterday = JournalCalendar.offset(today, by: -1),
      day == yesterday || day > today
    {
      switchDay(to: today)
    }
    scheduleMidnight()
  }

  // MARK: Entries and timestamps

  private var knownInk: Set<String> = []

  /// Called after every document change while the journal is open.
  func documentChanged() {
    guard active else { return }
    let ids = coordinator.store.strokes.filter { $0.tool == .pen || $0.tool == .highlighter }.map(
      \.id)
    guard Set(ids) != knownInk else { return }
    let added = ids.filter { !knownInk.contains($0) }
    knownInk = Set(ids)
    page.trackInk(present: ids, at: Date())
    savePage()
    if !added.isEmpty {
      Self.log.info(
        "ink accepted day=\(self.day, privacy: .public) new=\(added.count) total=\(ids.count) rendered=\(self.coordinator.workspace.canvasOnScreen)"
      )
    }
  }

  func addEntry(_ text: String, kind: JournalEntry.Kind) {
    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard active, !t.isEmpty else { return }
    _ = page.addNote(t, kind: kind, at: Date())
    savePage()
  }

  func update(_ id: String, text: String? = nil, done: Bool? = nil) {
    guard active else { return }
    page.update(id, text: text, done: done, at: Date())
    savePage()
  }

  func remove(_ id: String) {
    guard active else { return }
    page.remove(id)
    savePage()
  }

  /// Edits arrive from text fields, which also commit when the panel hides, i.e.
  /// after close: without the `active` guard that renamed the restored work
  /// session to "Journal <day>" (found in real use, 2026-11-01).
  func setTitle(_ t: String) {
    let t = String(t.prefix(120))
    guard active, t != page.title else { return }
    page.title = t
    coordinator.storage.sessionTitle = page.title.isEmpty ? "Journal \(day)" : page.title
    savePage()
  }

  /// Page writes run on a serial background queue (they took ~80 ms on the main
  /// thread per stroke end in the baseline). Writes are coalesced: the latest
  /// page wins, older pending ones are skipped. `flushPage()` waits for them
  /// (switching days, closing, quitting).
  private let pageQueue = DispatchQueue(label: "inkbridge.journal.save", qos: .utility)
  private var pendingPage: JournalPage?
  private let pendingLock = NSLock()
  @Published private(set) var pageSaving = false

  func savePage() {
    refreshAnchors()
    pendingLock.withLock { pendingPage = page }
    pageSaving = true
    let store = self.store
    pageQueue.async { [weak self] in
      guard let self else { return }
      guard
        let p = self.pendingLock.withLock({ () -> JournalPage? in
          defer { self.pendingPage = nil }
          return self.pendingPage
        })
      else { return }
      var failure: String?
      do { try store.savePage(p) } catch { failure = error.localizedDescription }
      DispatchQueue.main.async {
        self.pageError = failure
        self.pageSaving = self.pendingLock.withLock { self.pendingPage != nil }
      }
    }
    UserDefaults.standard.set(day, forKey: "lastJournalDay")
    sendState()
  }

  /// Blocks until queued page writes are on disk.
  func flushPage() {
    pageQueue.sync {}
    if let p = pendingLock.withLock({ () -> JournalPage? in
      defer { pendingPage = nil }
      return pendingPage
    }) {
      try? store.savePage(p)
    }
  }

  // MARK: Location

  /// First use: confirm or choose the journal folder (separate from projects).
  private func chooseLocationFirstTime() -> Bool {
    let alert = NSAlert()
    alert.messageText = "Where should your Daily Journal be saved?"
    alert.informativeText =
      "Journal days are kept separately from your projects. Suggested: \(StorageController.displayPath(rootPath)). You can change this later in Projects & Storage."
    alert.addButton(withTitle: "Use This Folder")
    alert.addButton(withTitle: "Choose…")
    alert.addButton(withTitle: "Cancel")
    switch alert.runModal() {
    case .alertFirstButtonReturn: break
    case .alertSecondButtonReturn:
      guard let url = pickFolder() else { return false }
      rootPath = url.path
    default: return false
    }
    do { try ProjectStore.validateDestination(URL(fileURLWithPath: rootPath)) } catch {
      coordinator.model.statusMessage = error.localizedDescription
      return false
    }
    UserDefaults.standard.set(rootPath, forKey: "journalRoot")
    UserDefaults.standard.set(true, forKey: "journalRootChosen")
    return true
  }

  func pickFolder() -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.prompt = "Use for Journal"
    panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 3)
    return panel.runModal() == .OK ? panel.url : nil
  }

  /// Changes the journal folder. Existing days are never moved or deleted;
  /// `copyExisting` copies them into the new folder (skipping days already there).
  func changeLocation(to url: URL, copyExisting: Bool) throws {
    try ProjectStore.validateDestination(url)
    savePage()
    let old = store
    if copyExisting {
      let new = JournalStore(root: url)
      for d in old.days() where !FileManager.default.fileExists(atPath: new.dayDir(d).path) {
        try FileManager.default.createDirectory(
          at: new.dayDir(d).deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: old.dayDir(d), to: new.dayDir(d))
      }
    }
    rootPath = url.path
    UserDefaults.standard.set(rootPath, forKey: "journalRoot")
    UserDefaults.standard.set(true, forKey: "journalRootChosen")
    if active {
      coordinator.storage.journalDir = dayDir
      try? coordinator.storage.saveNow()
      savePage()
    }
  }

  // MARK: Tablet

  func sendState() {
    revision += 1
    guard let peer = coordinator.activePeer else { return }
    coordinator.server.send(
      .journalState(
        active: active, day: day, today: isToday, title: page.title,
        entries: page.entries, revision: revision, hidden: hidden), to: peer.id)
  }

  func handle(action: String, name: String?) {
    switch action {
    case "open": open()
    case "close": close()
    case "today": active ? switchDay(to: JournalCalendar.dayID(for: Date())) : open()
    case "prev": step(-1)
    case "next": step(1)
    case "day":
      if let name, JournalCalendar.isValid(name) { active ? switchDay(to: name) : open(day: name) }
    case "add_note": if active, let name { addEntry(name, kind: .note) }
    case "add_task": if active, let name { addEntry(name, kind: .task) }
    case "hide": hide()
    case "show": show()
    default: break
    }
    sendState()
  }

  // MARK: Handwriting previews

  /// Thumbnails by entry, keyed so an entry that gained or lost strokes is re-rendered.
  private var thumbCache: [String: (key: String, image: NSImage)] = [:]

  func thumbnail(for e: JournalEntry, dark: Bool) -> NSImage? {
    let key = "\(e.strokeIDs.count)-\(e.strokeIDs.last ?? "")-\(dark)"
    if let hit = thumbCache[e.id], hit.key == key { return hit.image }
    let ids = Set(e.strokeIDs)
    let strokes = coordinator.store.strokes.filter { ids.contains($0.id) }
    guard let img = Self.renderThumbnail(strokes, dark: dark) else { return nil }
    thumbCache[e.id] = (key, img)
    return img
  }

  static func renderThumbnail(_ strokes: [Stroke], dark: Bool) -> NSImage? {
    // As wide as the panel allows, as tall as the ink's shape needs (24–96 pt).
    var b = CGRect.null
    for s in strokes {
      let r = s.bounds
      b = b.union(CGRect(x: r.minX, y: r.minY, width: r.maxX - r.minX, height: r.maxY - r.minY))
    }
    guard !b.isNull else { return nil }
    let size = CGSize(
      width: 220, height: min(96, max(24, 220 * (b.height + 16) / max(b.width + 16, 1))))
    // Dark ink disappears on a dark panel: draw it light there.
    guard
      let cg = InkThumbnail.render(strokes, size: size, color: dark ? RGBA(0.92, 0.92, 0.92) : nil)
    else { return nil }
    return NSImage(cgImage: cg, size: size)
  }

  /// Pans and zooms the page to an entry's handwriting.
  func reveal(_ e: JournalEntry) {
    guard active else { return }
    let ids = Set(e.strokeIDs)
    var r = CGRect.null
    for s in coordinator.store.strokes where ids.contains(s.id) {
      let b = s.bounds
      r = r.union(CGRect(x: b.minX, y: b.minY, width: b.maxX - b.minX, height: b.maxY - b.minY))
    }
    guard !r.isNull else { return }
    if hidden { show() }
    // Fit the ink, but never closer than 150% (a single word would fill the screen), centred.
    let surface = coordinator.ingestor.surface
    let z = min(Viewport.fitting(r.insetBy(dx: -120, dy: -120), in: surface).zoom, 1.5)
    coordinator.setViewport(
      Viewport(x: r.midX - surface.width / z / 2, y: r.midY - surface.height / z / 2, zoom: z))
  }

  // MARK: Canvas timestamps

  /// "09:15" next to each handwriting session (when times are shown).
  private static let timeFormat: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm"
    return f
  }()

  /// Label positions, recomputed only when the page or the ink changes (not per frame).
  private var anchors: [(date: Date, point: CGPoint)] = []

  private func refreshAnchors() {
    anchors = page.inkAnchors(coordinator.store.strokes)
  }

  func drawTimes(_ ctx: CGContext, _ mapper: CoordinateMapper, dirty: CGRect) {
    guard active, showTimes else { return }
    for a in anchors {
      let p = mapper.map(x: Double(a.point.x), y: Double(a.point.y))
      let r = CGRect(x: p.x - 56, y: p.y - 20, width: 60, height: 18)
      guard r.intersects(dirty) else { continue }
      DiagramRenderer.text(
        Self.timeFormat.string(from: a.date), at: CGPoint(x: p.x - 26, y: p.y - 18), size: 11,
        bold: false,
        color: CGColor(gray: 0.45, alpha: 1), maxWidth: 60, ctx)
    }
  }
}
