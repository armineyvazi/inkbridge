import AppKit
import Combine
import InkBridgeCore

/// Daily Journal: a per-day notebook you can step into and out of without
/// disturbing the open work.
///
/// Entering: the current document is saved, then snapshotted *in memory*
/// (strokes, background, diagram, undo/redo — `StrokeStore.snapshot`) along
/// with the view, tool, mouse mode and Engineering state. The day's page is
/// loaded into the same canvas. Leaving: the day is saved and the snapshot is
/// restored exactly; nothing is reloaded from disk.
///
/// Days follow local calendar boundaries: a timer for the next local midnight
/// plus `NSCalendarDayChanged` (time-zone change, wake from sleep) move an
/// open "today" journal to the new day; older days stay as they were.
final class JournalController: ObservableObject {
    @Published private(set) var active = false
    @Published private(set) var day = JournalCalendar.dayID(for: Date())
    @Published var page = JournalPage(day: JournalCalendar.dayID(for: Date()))
    @Published var showTimes: Bool { didSet { UserDefaults.standard.set(showTimes, forKey: "journalShowTimes"); coordinator.overlayView?.needsDisplay = true } }
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
        NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
            self?.dayMayHaveChanged()
        }
        NotificationCenter.default.addObserver(forName: NSNotification.Name.NSSystemTimeZoneDidChange, object: nil, queue: .main) { [weak self] _ in
            NSTimeZone.resetSystemTimeZone()
            self?.dayMayHaveChanged()
        }
    }

    var store: JournalStore { JournalStore(root: URL(fileURLWithPath: rootPath)) }
    var dayDir: URL { store.dayDir(day) }
    var isToday: Bool { day == JournalCalendar.dayID(for: Date()) }

    // MARK: Open / close

    func toggle() { active ? close() : open() }

    /// Opens a day (today by default). Asks once where journal files should live.
    func open(day requested: String? = nil) {
        if !UserDefaults.standard.bool(forKey: "journalRootChosen") && !chooseLocationFirstTime() { return }
        let target = requested ?? JournalCalendar.dayID(for: Date())
        guard JournalCalendar.isValid(target) else { return }
        if active { return switchDay(to: target) }
        let c = coordinator
        do { try c.storage.saveNow() } catch {
            // The open work could not be saved: do not replace it.
            c.model.statusMessage = "Daily Journal not opened: \(error.localizedDescription)"
            return
        }
        saved = Saved(snapshot: c.store.snapshot(), sessionID: c.sessionID, project: c.storage.activeProject,
                      title: c.storage.sessionTitle, viewport: c.ingestor.viewport, tool: c.model.tool,
                      pointer: c.model.pointerMode, engineering: c.engineering.active)
        if c.engineering.active { c.setEngineering(false) }
        active = true
        c.model.journalActive = true
        load(target)
        c.journalPanel.show(on: c.targetScreen)
        scheduleMidnight()
    }

    func close() {
        guard active, let s = saved else { return }
        let c = coordinator
        savePage()
        try? c.storage.saveNow()
        active = false
        c.model.journalActive = false
        midnightTimer?.invalidate()
        c.journalPanel.hide()
        // Back to exactly what was open: same document object state, undo history, view and tools.
        c.storage.journalDir = nil
        c.restoreSession(id: s.sessionID, snapshot: s.snapshot, viewport: s.viewport)
        c.storage.restore(project: s.project, title: s.title)
        // Crash recovery must reopen the work, not the journal that was just closed.
        UserDefaults.standard.set(s.project, forKey: "lastSessionProject")
        UserDefaults.standard.set(s.sessionID, forKey: "lastSessionID")
        c.model.tool = s.tool
        c.setPointerMode(s.pointer)
        if s.engineering { c.setEngineering(true) }
        saved = nil
        sendState()
    }

    func switchDay(to target: String) {
        guard active, target != day, JournalCalendar.isValid(target) else { return }
        savePage()
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
        if let (meta, s) = try? SessionArchive.load(from: dir) {
            strokes = s
            bg = meta.background ?? Self.paper
            viewport = meta.viewport
        }
        c.storage.journalDir = dir
        c.storage.enterJournal(title: page.title.isEmpty ? "Journal \(target)" : page.title)
        c.startSession(id: "journal-\(target)", strokes: strokes, background: bg, viewport: viewport)
        knownInk = Set(strokes.map(\.id))
        sendState()
    }

    // MARK: Day boundaries

    private func scheduleMidnight() {
        midnightTimer?.invalidate()
        let at = JournalCalendar.nextMidnight(after: Date()).addingTimeInterval(1)
        let t = Timer(fire: at, interval: 0, repeats: false) { [weak self] _ in self?.dayMayHaveChanged() }
        RunLoop.main.add(t, forMode: .common)
        midnightTimer = t
    }

    /// If "today" was open and the calendar day changed, move to the new day.
    /// A deliberately opened older day stays open.
    func dayMayHaveChanged(now: Date = Date()) {
        guard active else { return }
        let today = JournalCalendar.dayID(for: now)
        if today != day, let yesterday = JournalCalendar.offset(today, by: -1), day == yesterday || day > today {
            switchDay(to: today)
        }
        scheduleMidnight()
    }

    // MARK: Entries and timestamps

    private var knownInk: Set<String> = []

    /// Called after every document change while the journal is open.
    func documentChanged() {
        guard active else { return }
        let ids = coordinator.store.strokes.filter { $0.tool == .pen || $0.tool == .highlighter }.map(\.id)
        guard Set(ids) != knownInk else { return }
        knownInk = Set(ids)
        page.trackInk(present: ids, at: Date())
        savePage()
    }

    func addEntry(_ text: String, kind: JournalEntry.Kind) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        _ = page.addNote(t, kind: kind, at: Date())
        savePage()
    }

    func update(_ id: String, text: String? = nil, done: Bool? = nil) {
        page.update(id, text: text, done: done, at: Date())
        savePage()
    }

    func remove(_ id: String) {
        page.remove(id)
        savePage()
    }

    func setTitle(_ t: String) {
        page.title = String(t.prefix(120))
        coordinator.storage.sessionTitle = page.title.isEmpty ? "Journal \(day)" : page.title
        savePage()
    }

    /// Small and atomic, so it is written synchronously on every change:
    /// "Saved" never appears before the entry is on disk.
    func savePage() {
        do {
            try store.savePage(page)
            pageError = nil
        } catch {
            pageError = error.localizedDescription
        }
        UserDefaults.standard.set(day, forKey: "lastJournalDay")
        sendState()
    }

    // MARK: Location

    /// First use: confirm or choose the journal folder (separate from projects).
    private func chooseLocationFirstTime() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Where should your Daily Journal be saved?"
        alert.informativeText = "Journal days are kept separately from your projects. Suggested: \(StorageController.displayPath(rootPath)). You can change this later in Projects & Storage."
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
                try FileManager.default.createDirectory(at: new.dayDir(d).deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: old.dayDir(d), to: new.dayDir(d))
            }
        }
        rootPath = url.path
        UserDefaults.standard.set(rootPath, forKey: "journalRoot")
        UserDefaults.standard.set(true, forKey: "journalRootChosen")
        if active { coordinator.storage.journalDir = dayDir; try? coordinator.storage.saveNow(); savePage() }
    }

    // MARK: Tablet

    func sendState() {
        revision += 1
        guard let peer = coordinator.activePeer else { return }
        coordinator.server.send(.journalState(active: active, day: day, today: isToday, title: page.title,
                                              entries: page.entries, revision: revision), to: peer.id)
    }

    func handle(action: String, name: String?) {
        switch action {
        case "open": open()
        case "close": close()
        case "today": active ? switchDay(to: JournalCalendar.dayID(for: Date())) : open()
        case "prev": step(-1)
        case "next": step(1)
        case "day": if let name, JournalCalendar.isValid(name) { active ? switchDay(to: name) : open(day: name) }
        case "add_note": if active, let name { addEntry(name, kind: .note) }
        case "add_task": if active, let name { addEntry(name, kind: .task) }
        default: break
        }
        sendState()
    }

    // MARK: Canvas timestamps

    /// "09:15" next to each handwriting session (when times are shown).
    func drawTimes(_ ctx: CGContext, _ mapper: CoordinateMapper) {
        guard active, showTimes else { return }
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        let byID = Dictionary(coordinator.store.strokes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for e in page.entries where e.kind == .ink {
            let pts = e.strokeIDs.compactMap { byID[$0] }.flatMap(\.points)
            guard let minX = pts.map(\.x).min(), let minY = pts.map(\.y).min() else { continue }
            let p = mapper.map(x: minX, y: minY)
            DiagramRenderer.text(f.string(from: e.createdAt), at: CGPoint(x: p.x - 26, y: p.y - 18), size: 11, bold: false,
                                 color: CGColor(gray: 0.45, alpha: 1), maxWidth: 60, ctx)
        }
    }
}
