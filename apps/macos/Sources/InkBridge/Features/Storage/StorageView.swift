import AppKit
import InkBridgeCore
import SwiftUI

/// Projects & Storage window: where work is saved, the save status, the
/// export folder, and project/session management. Opened from the menu bar,
/// the toolbar ••• menu, Settings, or ⌃⌥J.
final class StorageWindowController {
  private var window: NSWindow?
  private unowned let coordinator: InkCoordinator

  init(coordinator: InkCoordinator) { self.coordinator = coordinator }

  func show() {
    coordinator.storage.refreshProjects()
    if window == nil {
      let w = NSWindow(
        contentViewController: NSHostingController(
          rootView: StorageView(storage: coordinator.storage, journal: coordinator.journal)))
      w.title = "Projects & Storage"
      w.styleMask = [.titled, .closable, .resizable]
      w.isReleasedWhenClosed = false
      w.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
      window = w
    }
    NSApp.activate(ignoringOtherApps: true)
    window?.center()
    window?.makeKeyAndOrderFront(nil)
  }
}

struct SaveStatusLabel: View {
  let status: SaveStatus

  var body: some View {
    switch status {
    case .empty:
      Label("Nothing to save yet", systemImage: "doc").foregroundStyle(.secondary)
    case .saved(let d):
      Label(
        "Saved \(d.formatted(date: .omitted, time: .shortened))", systemImage: "checkmark.circle"
      ).foregroundStyle(.green)
    case .saving:
      Label("Saving…", systemImage: "arrow.triangle.2.circlepath").foregroundStyle(.secondary)
    case .unsaved:
      Label("Unsaved changes", systemImage: "circle.fill").foregroundStyle(.orange)
    case .failed(let m):
      Label("Save failed: \(m)", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
    }
  }
}

struct StorageView: View {
  @ObservedObject var storage: StorageController
  @ObservedObject var journal: JournalController
  @State private var query = ""
  @State private var sessionQuery = ""
  @State private var selected: String?
  @State private var error: String?
  @State private var newName = ""
  @State private var renaming: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      location
      Divider()
      journalSection
      Divider()
      HStack(alignment: .top, spacing: 16) {
        projectList.frame(width: 260)
        sessionList
      }
      if let error {
        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(
          .callout
        )
        .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(18)
    .frame(minWidth: 720, minHeight: 520)
    .onAppear { selected = storage.activeProject }
  }

  // MARK: Location and status

  private var location: some View {
    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
      GridRow {
        Text("Projects folder").foregroundStyle(.secondary)
        Text(StorageController.displayPath(storage.config.rootPath)).textSelection(.enabled)
          .lineLimit(1).truncationMode(.middle)
        HStack {
          Button("Change Location…", action: changeLocation)
          Button("Show in Finder") {
            NSWorkspace.shared.open(URL(fileURLWithPath: storage.config.rootPath))
          }
        }
      }
      GridRow {
        Text("Exports go to").foregroundStyle(.secondary)
        Text(
          storage.config.exportsPath.map(StorageController.displayPath)
            ?? "Ask each time (starts in the project’s exports folder)"
        )
        .lineLimit(1).truncationMode(.middle)
        HStack {
          Button("Change…", action: changeExports)
          if storage.config.exportsPath != nil {
            Button("Ask Each Time") { run { try storage.setExportsFolder(nil) } }
          }
        }
      }
      GridRow {
        Text("Now editing").foregroundStyle(.secondary)
        HStack(spacing: 6) {
          Text(storage.activeProject).bold()
          Text("›").foregroundStyle(.secondary)
          TextField(
            "Session name", text: $storage.sessionTitle,
            onCommit: { storage.renameSession(storage.sessionTitle) }
          )
          .textFieldStyle(.roundedBorder).frame(width: 220)
        }
        HStack {
          Button("Save Now") { run { try storage.saveNow() } }
          Button("New Session") { run { try storage.newSession() } }
        }
      }
      GridRow {
        Text("Status").foregroundStyle(.secondary)
        SaveStatusLabel(status: storage.status)
        Text(
          storage.freeBytes.map {
            ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) + " free"
          } ?? ""
        )
        .foregroundStyle(.secondary)
      }
    }
  }

  // MARK: Daily Journal (separate from projects)

  private var journalSection: some View {
    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
      GridRow {
        Text("Daily Journal").foregroundStyle(.secondary)
        Text(StorageController.displayPath(journal.rootPath)).lineLimit(1).truncationMode(.middle)
        HStack {
          Button("Change…", action: changeJournalLocation)
          Button("Show in Finder") {
            try? FileManager.default.createDirectory(
              atPath: journal.rootPath, withIntermediateDirectories: true)
            NSWorkspace.shared.open(URL(fileURLWithPath: journal.rootPath))
          }
        }
      }
      GridRow {
        Text("Uses").foregroundStyle(.secondary)
        Text(
          "\(journal.store.days().count) days · \(ByteCountFormatter.string(fromByteCount: journal.store.usageBytes(), countStyle: .file))"
        )
        Text("Each day is its own folder (YYYY/MM/YYYY-MM-DD).").font(.caption).foregroundStyle(
          .secondary)
      }
    }
  }

  private func changeJournalLocation() {
    guard let url = journal.pickFolder() else { return }
    let alert = NSAlert()
    alert.messageText = "Use “\(url.lastPathComponent)” for the Daily Journal?"
    alert.informativeText =
      "Existing journal days are never moved or deleted. Copy them to the new folder too?"
    alert.addButton(withTitle: "Copy Existing Days")
    alert.addButton(withTitle: "Start Fresh There")
    alert.addButton(withTitle: "Cancel")
    switch alert.runModal() {
    case .alertFirstButtonReturn: run { try journal.changeLocation(to: url, copyExisting: true) }
    case .alertSecondButtonReturn: run { try journal.changeLocation(to: url, copyExisting: false) }
    default: break
    }
  }

  // MARK: Projects

  private var projectList: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Projects").font(.headline)
      TextField("Search projects", text: $query).textFieldStyle(.roundedBorder)
      List(selection: $selected) {
        ForEach(
          storage.projects.filter {
            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)
          }
        ) { p in
          HStack {
            Image(systemName: p.name == storage.activeProject ? "folder.fill" : "folder")
            Text(p.name)
            Spacer()
            Text("\(p.sessionCount)").foregroundStyle(.secondary).monospacedDigit()
          }
          .tag(p.name)
          .contextMenu {
            Button("Open") { run { try storage.switchProject(p.name) } }
            Button("Rename…") {
              renaming = p.name
              newName = p.name
            }
            Button("Duplicate") { run { try storage.duplicateProject(p.name) } }
            Button("Show in Finder") {
              NSWorkspace.shared.activateFileViewerSelecting([
                storage.projectStore.projectDir(p.name)
              ])
            }
            Divider()
            Button("Move to Trash…", role: .destructive) { confirmDelete(p.name) }
          }
        }
      }
      .frame(minHeight: 240)
      HStack {
        TextField("New project name", text: $newName).textFieldStyle(.roundedBorder)
        if let renaming {
          Button("Rename") {
            run {
              try storage.renameProject(renaming, to: newName)
              self.renaming = nil
              newName = ""
            }
          }
        } else {
          Button("Create") {
            run {
              selected = try storage.createProject(newName)
              newName = ""
            }
          }
          .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
      }
      if let s = selected, s != storage.activeProject {
        Button("Open “\(s)”") { run { try storage.switchProject(s) } }
      }
    }
  }

  // MARK: Sessions

  private var sessionList: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Sessions in \(selected ?? storage.activeProject)").font(.headline)
      TextField("Search sessions", text: $sessionQuery).textFieldStyle(.roundedBorder)
      let project = selected ?? storage.activeProject
      List(storage.projectStore.listSessions(project, query: sessionQuery)) { s in
        HStack {
          VStack(alignment: .leading) {
            Text(s.title)
            Text(
              "\(s.savedAt.formatted(date: .abbreviated, time: .shortened)) · \(s.strokeCount) strokes"
            )
            .font(.caption).foregroundStyle(.secondary)
          }
          Spacer()
          Button("Open") { run { try storage.openSession(project: project, id: s.id) } }
        }
      }
    }
  }

  // MARK: Actions

  private func run(_ body: () throws -> Void) {
    do {
      try body()
      error = nil
    } catch { self.error = error.localizedDescription }
  }

  private func changeLocation() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.prompt = "Use This Folder"
    panel.message = "Choose where InkBridge keeps your projects."
    panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 3)
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do { try ProjectStore.validateDestination(url) } catch {
      self.error = error.localizedDescription
      return
    }
    let count = storage.projects.count
    let alert = NSAlert()
    alert.messageText = "Use “\(url.lastPathComponent)” for projects?"
    alert.informativeText =
      count == 0
      ? "New work will be saved there."
      : "You have \(count) project(s) in \(StorageController.displayPath(storage.config.rootPath)). Move them to the new folder, or leave them where they are? (Left projects stay on disk; switch back to this folder to see them.)"
    alert.addButton(withTitle: count == 0 ? "Use Folder" : "Move Projects")
    if count > 0 { alert.addButton(withTitle: "Leave Them Here") }
    alert.addButton(withTitle: "Cancel")
    let r = alert.runModal()
    switch (count, r) {
    case (_, .alertFirstButtonReturn): run { try storage.changeRoot(to: url, migrate: count > 0) }
    case (1..., .alertSecondButtonReturn): run { try storage.changeRoot(to: url, migrate: false) }
    default: break
    }
  }

  private func changeExports() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.prompt = "Use for Exports"
    panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 3)
    guard panel.runModal() == .OK, let url = panel.url else { return }
    run { try storage.setExportsFolder(url) }
  }

  private func confirmDelete(_ name: String) {
    let alert = NSAlert()
    alert.messageText = "Move “\(name)” to the Trash?"
    alert.informativeText =
      "All its sessions and exports go to the Trash. You can restore them from there."
    alert.addButton(withTitle: "Move to Trash")
    alert.addButton(withTitle: "Cancel")
    if alert.runModal() == .alertFirstButtonReturn { run { try storage.deleteProject(name) } }
  }
}
