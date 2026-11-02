import AppKit
import Combine
import InkBridgeCore

/// The Mac's storage manager: where projects live, which project and session
/// are active, autosave, and the save status both devices show.
///
/// Saving never blocks drawing: the document is snapshotted on the main
/// thread (value types) and written on `ioQueue`. The status turns `saved`
/// only after the files were written and renamed into place.
final class StorageController: ObservableObject {
  @Published private(set) var config: StorageConfig
  @Published private(set) var status: SaveStatus = .empty
  @Published private(set) var projects: [ProjectInfo] = []
  @Published var sessionTitle: String
  @Published private(set) var freeBytes: Int64?

  private unowned let coordinator: InkCoordinator
  private let ioQueue = DispatchQueue(label: "inkbridge.save", qos: .utility)
  private var saving = false
  private var saveAgain = false
  private var savedVersion = -1
  /// What the last successful save put on disk; lets the next save append (see `IncrementalSave`).
  private var persisted: IncrementalSave.Persisted?
  /// Saves by kind, for diagnostics ("Projects & Storage" and the self-check).
  private(set) var fullSaves = 0, appendSaves = 0

  /// The open document was replaced: the next save is a full write.
  func documentReplaced() { persisted = nil }
  private var revision: UInt64 = 0
  private static let configKey = "storageConfig"
  static let journalMarker = "__journal__"

  var projectStore: ProjectStore { ProjectStore(root: URL(fileURLWithPath: config.rootPath)) }
  var activeProject: String { config.activeProject }
  /// Set while the Daily Journal is open: saves go to that day's folder instead of the project.
  var journalDir: URL?

  var sessionDir: URL {
    journalDir ?? projectStore.sessionDir(config.activeProject, coordinator.sessionID)
  }

  /// The journal day was just loaded into the canvas: it is what is on disk.
  func enterJournal(title: String) {
    sessionTitle = title
    savedVersion = coordinator.store.documentVersion
    setStatus(
      FileManager.default.fileExists(atPath: sessionDir.appendingPathComponent("strokes.json").path)
        ? .saved(Date()) : .empty)
  }

  /// Back from the journal: the restored document was saved before entering.
  func restore(project: String, title: String) {
    config.activeProject = project
    sessionTitle = title
    savedVersion = coordinator.store.documentVersion
    setStatus(.saved(Date()))
    coordinator.sendStorageState()
  }

  init(coordinator: InkCoordinator) {
    self.coordinator = coordinator
    if let data = UserDefaults.standard.data(forKey: Self.configKey),
      let saved = try? JSONDecoder().decode(StorageConfig.self, from: data)
    {
      config = saved
    } else {
      config = StorageConfig(
        rootPath: StorageConfig.defaultRoot.path, recentRoots: [StorageConfig.defaultRoot.path])
    }
    sessionTitle = Self.defaultTitle()
    prepare()
  }

  static func defaultTitle(_ date: Date = Date()) -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH.mm"
    return "Session \(f.string(from: date))"
  }

  /// Creates the active project and imports pre-1.0 autosaves once (copied, not moved).
  private func prepare() {
    do {
      freeBytes = try ProjectStore.validateDestination(URL(fileURLWithPath: config.rootPath))
      try projectStore.ensureProject(config.activeProject)
      importLegacySessionsOnce()
    } catch {
      status = .failed(error.localizedDescription)
    }
    refreshProjects()
  }

  private func importLegacySessionsOnce() {
    let key = "legacySessionsImported"
    guard !UserDefaults.standard.bool(forKey: key) else { return }
    UserDefaults.standard.set(true, forKey: key)
    let legacy = InkCoordinator.supportDirectory.appendingPathComponent("Sessions")
    let ids = ((try? FileManager.default.contentsOfDirectory(atPath: legacy.path)) ?? []).filter {
      !$0.hasPrefix(".")
    }
    guard !ids.isEmpty else { return }
    let project = "Imported Sessions"
    try? projectStore.ensureProject(project)
    for id in ids {
      let to = projectStore.sessionDir(project, id)
      if !FileManager.default.fileExists(atPath: to.path) {
        try? FileManager.default.copyItem(at: legacy.appendingPathComponent(id), to: to)
      }
    }
  }

  func refreshProjects() {
    projects = projectStore.listProjects()
  }

  private func persist() {
    if let data = try? JSONEncoder().encode(config) {
      UserDefaults.standard.set(data, forKey: Self.configKey)
    }
    revision += 1
    coordinator.sendStorageState()
  }

  // MARK: Saving

  /// Called after every document change: shows "Unsaved" until the next save lands.
  func documentChanged() {
    guard coordinator.store.documentVersion != savedVersion, status != .saving, !isPristine else {
      return
    }
    if case .failed = status { return }  // keep the error visible until a save succeeds
    setStatus(.unsaved)
  }

  /// Writes the session if it changed (or `force`). Non-blocking.
  func save(force: Bool = false) {
    let version = coordinator.store.documentVersion
    guard force || version != savedVersion else { return }
    if isPristine {
      savedVersion = version
      return
    }
    if saving {
      saveAgain = true
      return
    }
    saving = true
    setStatus(.saving)
    let strokes = coordinator.store.strokes
    let diagram = coordinator.store.diagram
    let background = coordinator.store.background
    var meta = coordinator.makeMetadata()
    meta.title = sessionTitle
    let dir = sessionDir
    let project = config.activeProject
    let sessionID = coordinator.sessionID
    let isJournal = journalDir != nil
    let journalDay = journalDir?.lastPathComponent ?? ""
    let plan = IncrementalSave.plan(
      strokes: strokes, background: background, diagram: diagram, dir: dir, persisted: persisted)
    let logCount = persisted?.logCount ?? 0
    ioQueue.async { [weak self] in
      let result: Result<Void, StorageError>
      do {
        switch plan {
        case .append(let new): try SessionArchive.appendStrokes(new, metadata: meta, to: dir)
        case .full, .none:
          try SessionArchive.writeStrokes(strokes, metadata: meta, diagram: diagram, to: dir)
        }
        result = .success(())
      } catch {
        result = .failure(StorageError.from(error, path: dir.path))
      }
      DispatchQueue.main.async {
        guard let self else { return }
        self.saving = false
        switch result {
        case .success:
          self.savedVersion = version
          if case .append(let new) = plan {
            self.appendSaves += 1
            self.persisted?.ids += new.map(\.id)
            self.persisted?.logCount = logCount + new.count
          } else {
            self.fullSaves += 1
            self.persisted = .init(
              dir: dir, ids: strokes.map(\.id), background: background, diagram: diagram,
              logCount: 0)
          }
          // Crash recovery reopens what was being written: a journal day or a project session.
          UserDefaults.standard.set(
            isJournal ? Self.journalMarker : project, forKey: "lastSessionProject")
          UserDefaults.standard.set(isJournal ? journalDay : sessionID, forKey: "lastSessionID")
          self.setStatus(
            self.coordinator.store.documentVersion == version ? .saved(Date()) : .unsaved)
        case .failure(let e):
          self.persisted = nil  // unknown state on disk: next save is a full write
          self.setStatus(.failed(e.localizedDescription))
        }
        if self.saveAgain {
          self.saveAgain = false
          self.save()
        }
      }
    }
  }

  /// A session nobody drew in (and that was never saved) is not worth a folder.
  private var isPristine: Bool {
    coordinator.store.strokes.isEmpty && coordinator.store.diagram.isEmpty
      && coordinator.store.background == .overlay
      && !FileManager.default.fileExists(atPath: sessionDir.path)
  }

  /// Synchronous save for quitting and switching sessions (the data must be on disk first).
  func saveNow() throws {
    if isPristine { return }
    var meta = coordinator.makeMetadata()
    meta.title = sessionTitle
    // An async save may still be writing this folder: let it land first.
    ioQueue.sync {}
    let store = coordinator.store
    do {
      try SessionArchive.writeStrokes(
        store.strokes, metadata: meta, diagram: store.diagram, to: sessionDir)
      persisted = .init(
        dir: sessionDir, ids: store.strokes.map(\.id), background: store.background,
        diagram: store.diagram, logCount: 0)
      fullSaves += 1
      savedVersion = coordinator.store.documentVersion
      setStatus(.saved(Date()))
    } catch {
      let e = StorageError.from(error, path: sessionDir.path)
      setStatus(.failed(e.localizedDescription))
      throw e
    }
  }

  private func setStatus(_ s: SaveStatus) {
    guard s != status else { return }
    status = s
    revision += 1
    coordinator.sendStorageState()
  }

  // MARK: Projects and sessions

  func createProject(_ name: String) throws -> String {
    let n = try projectStore.createProject(name)
    refreshProjects()
    return n
  }

  /// Saves go to the journal day folder while it is open; swapping the session there
  /// would overwrite the day's ink. Refuse until Done.
  private func requireNotInJournal() throws {
    if journalDir != nil { throw StorageError.journalOpen }
  }

  /// Saves the current session, then starts a new one in `name`, which must be an existing project.
  func switchProject(_ raw: String) throws {
    try requireNotInJournal()
    guard let name = ProjectStore.validName(raw), projectStore.isSafeProjectName(name) else {
      throw StorageError.invalidName(raw)
    }
    guard projectStore.listProjects().contains(where: { $0.name == name }) else {
      throw StorageError.notFound(name)
    }
    try saveNow()
    try projectStore.ensureProject(name)
    config.activeProject = name
    coordinator.startSession(
      id: InkCoordinator.newSessionID(), strokes: [], background: coordinator.store.background,
      viewport: .home)
    sessionTitle = Self.defaultTitle()
    setStatus(.empty)
    persist()
    refreshProjects()
  }

  func newSession() throws {
    try requireNotInJournal()
    try saveNow()
    coordinator.startSession(
      id: InkCoordinator.newSessionID(), strokes: [], background: coordinator.store.background,
      viewport: .home)
    sessionTitle = Self.defaultTitle()
    setStatus(.empty)
    persist()
  }

  func openSession(project: String, id: String) throws {
    try requireNotInJournal()
    try saveNow()
    let dir = projectStore.sessionDir(project, id)
    let (meta, strokes): (SessionMetadata, [Stroke])
    do { (meta, strokes) = try SessionArchive.load(from: dir) } catch {
      throw StorageError.from(error, path: dir.path)
    }
    config.activeProject = project
    coordinator.startSession(
      id: id, strokes: strokes, background: meta.background ?? .overlay, viewport: meta.viewport,
      diagram: SessionArchive.loadDiagram(from: dir), startedAt: meta.startedAt)
    sessionTitle = meta.title
    savedVersion = coordinator.store.documentVersion
    setStatus(.saved(meta.savedAt))
    persist()
  }

  func renameProject(_ old: String, to new: String) throws {
    let n = try projectStore.renameProject(old, to: new)
    if config.activeProject == old { config.activeProject = n }
    persist()
    refreshProjects()
  }

  func duplicateProject(_ name: String) throws {
    _ = try projectStore.duplicateProject(name)
    refreshProjects()
  }

  func deleteProject(_ name: String) throws {
    guard name != config.activeProject else {
      throw StorageError.failed("“\(name)” is open. Switch to another project before deleting it.")
    }
    try projectStore.deleteProject(name)
    refreshProjects()
  }

  func renameSession(_ title: String) {
    guard let t = ProjectStore.validName(title) else { return }
    sessionTitle = t
    save(force: true)
  }

  // MARK: Locations

  /// Changes where projects are stored. `migrate` moves the existing
  /// projects; otherwise they stay where they are (still reachable by
  /// switching back). Never silent: the UI asks first.
  func changeRoot(to url: URL, migrate: Bool) throws {
    try saveNow()
    freeBytes = try ProjectStore.validateDestination(url)
    if migrate { _ = try projectStore.migrate(to: url) }
    config.rootPath = url.path
    if !config.recentRoots.contains(url.path) { config.recentRoots.insert(url.path, at: 0) }
    config.recentRoots = Array(config.recentRoots.prefix(6))
    try projectStore.ensureProject(config.activeProject)
    // The session continues in the new location from the next save.
    savedVersion = -1
    save(force: true)
    persist()
    refreshProjects()
  }

  func setExportsFolder(_ url: URL?) throws {
    if let url { try ProjectStore.validateDestination(url) }
    config.exportsPath = url?.path
    persist()
  }

  /// Where Save… opens: the chosen export folder, else this project's `exports/`.
  var exportsDirectory: URL {
    config.exportsPath.map { URL(fileURLWithPath: $0) }
      ?? projectStore.exportsDir(config.activeProject)
  }

  // MARK: Tablet

  static func displayPath(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    var p = path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    if p.count > 120 { p = "…" + p.suffix(119) }
    return p
  }

  func state() -> StorageState {
    let savedAt: Int64
    if case .saved(let d) = status {
      savedAt = Int64(d.timeIntervalSince1970 * 1000)
    } else {
      savedAt = 0
    }
    var error: String?
    if case .failed(let m) = status { error = String(m.prefix(120)) }
    return StorageState(
      project: journalDir == nil ? String(config.activeProject.prefix(120)) : "Daily Journal",
      session: String(sessionTitle.prefix(120)),
      location: Self.displayPath(
        (journalDir ?? projectStore.projectDir(config.activeProject)).path),
      status: status.wire, savedAtMs: savedAt, error: error,
      projects: projects.prefix(100).map { String($0.name.prefix(120)) },
      locations: config.recentRoots.prefix(6).map(Self.displayPath), revision: revision)
  }

  /// A request from the tablet. Everything is validated here; the answer is a fresh `storage.state`.
  func handle(action: String, name: String?) {
    do {
      switch action {
      case "save_now": try saveNow()
      case "new_session": try newSession()
      case "switch_project": try switchProject(name ?? config.activeProject)
      case "create_project": try switchProject(try createProject(name ?? ""))
      case "use_location":
        // The tablet chooses among locations the Mac offered (display strings); never a raw path.
        guard let name, let path = config.recentRoots.first(where: { Self.displayPath($0) == name })
        else {
          throw StorageError.failed("That location is not one this Mac offered.")
        }
        try changeRoot(to: URL(fileURLWithPath: path), migrate: false)
      default: break
      }
    } catch {
      setStatus(.failed(error.localizedDescription))
    }
    coordinator.sendStorageState()
  }
}
