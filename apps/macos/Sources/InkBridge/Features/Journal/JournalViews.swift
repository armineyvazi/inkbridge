import AppKit
import InkBridgeCore
import SwiftUI

// MARK: - Panel window

/// The journal's side panel. The page itself (the canvas) is the writing surface;
/// the panel stays narrow and holds only navigation, the day's timeline and quick capture.
///
/// Closing the panel (red button, ⌘W) *hides* the journal; it does not leave it.
/// The window keeps its SwiftUI state (scroll position, draft text) while hidden.
final class JournalPanelController: NSObject, NSWindowDelegate {
  private var panel: NSPanel?
  private let journal: JournalController
  private let storage: StorageController
  /// Where the person put the panel; reused when it comes back.
  private var placedOn: CGDirectDisplayID?

  init(journal: JournalController, storage: StorageController) {
    self.journal = journal
    self.storage = storage
  }

  func show(on screen: NSScreen?) {
    if panel == nil {
      let p = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: 308, height: 560),
        styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
        backing: .buffered, defer: false)
      p.title = "Daily Journal"
      p.titleVisibility = .hidden
      p.titlebarAppearsTransparent = true
      p.isMovableByWindowBackground = true
      p.isFloatingPanel = true
      p.becomesKeyOnlyIfNeeded = true
      p.hidesOnDeactivate = false
      p.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
      p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
      p.minSize = NSSize(width: 280, height: 360)
      p.delegate = self
      p.contentViewController = NSHostingController(
        rootView: JournalPanelView(journal: journal, storage: storage))
      panel = p
    }
    guard let panel else { return }
    let target = screen ?? NSScreen.screens.first
    let id = target.flatMap {
      $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
    // First time on this display: top-left, out of the way of the page. After that, where it was left.
    if placedOn != id, let f = target?.visibleFrame {
      let h = min(640, f.height - 24)
      panel.setFrame(
        NSRect(x: f.minX + 12, y: f.maxY - h - 12, width: 308, height: h), display: true)
      placedOn = id
    }
    panel.orderFrontRegardless()
  }

  func hide() { panel?.orderOut(nil) }

  /// Moves an already-visible panel onto `screen` (display change / follow-mouse).
  /// Resets the remembered placement so `show` docks it top-left on the new display.
  func place(on screen: NSScreen?) {
    guard panel?.isVisible == true else { return }
    placedOn = nil
    show(on: screen)
  }

  /// The close button puts the journal away (it stays open; ⌃⌥N or 📖 brings it back).
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    journal.hide()
    return false
  }
}

// MARK: - Panel content

struct JournalPanelView: View {
  @ObservedObject var journal: JournalController
  @ObservedObject var storage: StorageController
  @State private var draft = ""
  @State private var asTask = false
  @State private var showCalendar = false
  @FocusState private var composing: Bool

  private var date: Date { JournalCalendar.start(of: journal.day) ?? Date() }

  var body: some View {
    VStack(spacing: 0) {
      header
        .padding(.horizontal, 14)
        .padding(.top, 26)  // under the transparent title bar (close button)
        .padding(.bottom, 6)
      TextField(
        "Add a title", text: Binding(get: { journal.page.title }, set: { journal.setTitle($0) })
      )
      .textFieldStyle(.plain)
      .font(.headline)
      .padding(.horizontal, 14)
      .padding(.bottom, 8)
      Divider()
      timeline
      Divider()
      composer.padding(10)
      footer
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }
    .frame(minWidth: 280)
    .background(.regularMaterial)
  }

  // MARK: Header: date and navigation

  private var header: some View {
    HStack(alignment: .center, spacing: 4) {
      plainIcon("chevron.left", "Previous day (⌘[)") { journal.step(-1) }
        .keyboardShortcut("[", modifiers: .command)
      Button {
        showCalendar.toggle()
      } label: {
        VStack(alignment: .leading, spacing: 0) {
          Text(relativeDay)
            .font(.caption.weight(.semibold))
            .foregroundStyle(journal.isToday ? Color.accentColor : .secondary)
            .textCase(.uppercase)
          Text(date.formatted(.dateTime.day().month(.wide).year()))
            .font(.title3.weight(.semibold))
            .lineLimit(1)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("Choose a day")
      .popover(isPresented: $showCalendar, arrowEdge: .bottom) { calendar }
      plainIcon("chevron.right", "Next day (⌘])") { journal.step(1) }
        .keyboardShortcut("]", modifiers: .command)
      Spacer(minLength: 4)
      if !journal.isToday {
        Button("Today") { journal.switchDay(to: JournalCalendar.dayID(for: Date())) }
          .controlSize(.small)
          .keyboardShortcut("t", modifiers: .command)
      }
      plainIcon("magnifyingglass", "Search and history (⌘F)") { journal.coordinatorHistory() }
        .keyboardShortcut("f", modifiers: .command)
      Menu {
        Toggle("Show Times on the Page", isOn: $journal.showTimes)
        Button("History and Search…") { journal.coordinatorHistory() }
        Divider()
        Button("Hide Journal") { journal.hide() }
        Button("Done — Back to My Work") { journal.close() }
      } label: {
        Image(systemName: "ellipsis.circle")
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .help("More")
    }
  }

  /// "Today · Sunday", "Yesterday · Saturday", or just the weekday.
  private var relativeDay: String {
    let weekday = date.formatted(.dateTime.weekday(.wide))
    let today = JournalCalendar.dayID(for: Date())
    if journal.day == today { return "Today · \(weekday)" }
    if JournalCalendar.offset(today, by: -1) == journal.day { return "Yesterday · \(weekday)" }
    return weekday
  }

  private var calendar: some View {
    DatePicker(
      "",
      selection: Binding(
        get: { date },
        set: { d in
          showCalendar = false
          journal.open(day: JournalCalendar.dayID(for: d))
        }), displayedComponents: .date
    )
    .datePickerStyle(.graphical)
    .labelsHidden()
    .padding(10)
  }

  // MARK: Timeline

  private var timeline: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          if journal.page.entries.isEmpty {
            emptyState
          }
          ForEach(journal.page.entries) { e in
            JournalEntryRow(entry: e, journal: journal).id(e.id)
          }
        }
        .padding(.vertical, 8)
      }
      .frame(maxHeight: .infinity)
      .onChange(of: journal.page.entries.count) { _ in
        guard let last = journal.page.entries.last?.id else { return }
        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last, anchor: .bottom) }
      }
      .onAppear {
        if let last = journal.page.entries.last?.id { proxy.scrollTo(last, anchor: .bottom) }
      }
    }
  }

  private var emptyState: some View {
    VStack(spacing: 8) {
      Image(systemName: "pencil.and.scribble")
        .font(.system(size: 28, weight: .light))
        .foregroundStyle(.tertiary)
      Text(journal.isToday ? "Nothing yet today" : "Nothing on this day")
        .font(.headline)
      Text(
        "Write anywhere on the page with your pen, or type a note below. Every entry keeps the time you wrote it."
      )
      .font(.callout)
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity)
    .padding(.horizontal, 24)
    .padding(.vertical, 40)
  }

  // MARK: Quick capture

  private var composer: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Button {
        asTask.toggle()
      } label: {
        Image(systemName: asTask ? "checklist" : "text.alignleft")
          .foregroundStyle(asTask ? Color.accentColor : .secondary)
          .frame(width: 18)
      }
      .buttonStyle(.borderless)
      .help(
        asTask
          ? "Adding a task. Click to add a note instead."
          : "Adding a note. Click to add a task instead.")
      TextField(asTask ? "Add a task" : "Write a note", text: $draft, axis: .vertical)
        .textFieldStyle(.plain)
        .lineLimit(1...6)
        .focused($composing)
        .onSubmit(add)
      if !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        Button(action: add) { Image(systemName: "arrow.up.circle.fill").font(.title3) }
          .buttonStyle(.borderless)
          .help("Add (Return)")
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .background(
      RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.06)))
  }

  private func add() {
    journal.addEntry(draft, kind: asTask ? .task : .note)
    draft = ""
    composing = true
  }

  // MARK: Footer: save state, hide, done

  private var footer: some View {
    HStack(spacing: 8) {
      saveState
      Spacer()
      Button("Hide") { journal.hide() }
        .controlSize(.small)
        .help(
          "Put the journal away and use your desktop. It stays open: ⌃⌥N or 📖 brings it back as you left it."
        )
      Button("Done") { journal.close() }
        .controlSize(.small)
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.return, modifiers: .command)
        .help("Close the journal and go back to your work, exactly as you left it (⌘Return)")
    }
  }

  @ViewBuilder private var saveState: some View {
    Group {
      if let err = journal.pageError ?? storage.status.failureMessage {
        Label("Not saved", systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.red)
          .help(err)
      } else if journal.pageSaving || storage.status == .saving {
        HStack(spacing: 4) {
          ProgressView().controlSize(.mini)
          Text("Saving…")
        }
      } else if storage.status == .unsaved {
        Text("Edited")
      } else {
        Label("Saved", systemImage: "checkmark")
      }
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .labelStyle(.titleAndIcon)
  }

  private func plainIcon(_ name: String, _ help: String, action: @escaping () -> Void) -> some View
  {
    Button(action: action) {
      Image(systemName: name).frame(width: 22, height: 22).contentShape(Rectangle())
    }
    .buttonStyle(.borderless)
    .help(help)
  }
}

/// One timeline row: time, a rail dot, the content. Actions show on hover.
struct JournalEntryRow: View {
  let entry: JournalEntry
  /// nil: read-only (History).
  var journal: JournalController?
  var thumbnail: NSImage?
  @State private var hovered = false
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Text(entry.createdAt.formatted(date: .omitted, time: .shortened))
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .fixedSize()
        .frame(minWidth: 40, alignment: .trailing)
        .padding(.top, 2)
        .help(stamp)
      Circle()
        .fill(dot)
        .frame(width: 6, height: 6)
        .padding(.top, 6)
      content
      Spacer(minLength: 0)
      if hovered, let journal {
        actions(journal)
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 5)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous).fill(
        hovered ? Color.primary.opacity(0.05) : .clear)
    )
    .padding(.horizontal, 4)
    .onHover { hovered = $0 }
    .contextMenu { if let journal { menu(journal) } }
  }

  private var stamp: String {
    let f = { (d: Date) in d.formatted(date: .abbreviated, time: .standard) }
    return entry.modifiedAt.timeIntervalSince(entry.createdAt) > 1
      ? "Written \(f(entry.createdAt)) · edited \(f(entry.modifiedAt))"
      : "Written \(f(entry.createdAt))"
  }

  private var dot: Color {
    switch entry.kind {
    case .ink: return .accentColor
    case .task: return entry.done ? .secondary.opacity(0.5) : .orange
    case .note: return .secondary.opacity(0.6)
    }
  }

  @ViewBuilder private var content: some View {
    switch entry.kind {
    case .ink:
      VStack(alignment: .leading, spacing: 3) {
        if let img = thumbnail ?? journal?.thumbnail(for: entry, dark: scheme == .dark) {
          Image(nsImage: img)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(
              maxWidth: min(img.size.width, 220), maxHeight: img.size.height, alignment: .leading
            )
            .onTapGesture { journal?.reveal(entry) }
            .help(journal == nil ? "" : "Show on the page")
        }
        Text(inkCaption).font(.caption).foregroundStyle(.secondary)
      }
    case .task:
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Button {
          journal?.update(entry.id, done: !entry.done)
        } label: {
          Image(systemName: entry.done ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(entry.done ? Color.accentColor : .secondary)
        }
        .buttonStyle(.borderless)
        .disabled(journal == nil)
        text.strikethrough(entry.done).foregroundStyle(entry.done ? .secondary : .primary)
      }
    case .note:
      text
    }
  }

  @ViewBuilder private var text: some View {
    if let journal {
      TextField(
        "", text: Binding(get: { entry.text }, set: { journal.update(entry.id, text: $0) }),
        axis: .vertical
      )
      .textFieldStyle(.plain)
    } else {
      Text(entry.text).textSelection(.enabled)
    }
  }

  private var inkCaption: String {
    let n = entry.strokeIDs.count
    let span =
      entry.modifiedAt.timeIntervalSince(entry.createdAt) > 60
      ? " · until \(entry.modifiedAt.formatted(date: .omitted, time: .shortened))" : ""
    return "Handwriting · \(n) stroke\(n == 1 ? "" : "s")\(span)"
  }

  @ViewBuilder private func actions(_ journal: JournalController) -> some View {
    if entry.kind == .ink {
      Button {
        journal.reveal(entry)
      } label: {
        Image(systemName: "scope")
      }
      .buttonStyle(.borderless).help("Show on the page")
    } else {
      Button {
        journal.remove(entry.id)
      } label: {
        Image(systemName: "trash")
      }
      .buttonStyle(.borderless).help("Delete")
    }
  }

  @ViewBuilder private func menu(_ journal: JournalController) -> some View {
    if entry.kind == .ink {
      Button("Show on the Page") { journal.reveal(entry) }
    } else {
      Button("Copy") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.text, forType: .string)
      }
      if entry.kind == .task {
        Button(entry.done ? "Mark as Not Done" : "Mark as Done") {
          journal.update(entry.id, done: !entry.done)
        }
      }
      Divider()
      Button("Delete", role: .destructive) { journal.remove(entry.id) }
    }
  }
}

extension JournalController {
  func coordinatorHistory() { historyOpener?() }
}

extension SaveStatus {
  var failureMessage: String? {
    if case .failed(let m) = self { return m }
    return nil
  }
}

// MARK: - History

/// Loads the journal index off the main thread (it reads every day once).
final class JournalHistoryModel: ObservableObject {
  @Published private(set) var index: JournalIndex?
  @Published private(set) var thumbnails: [String: NSImage] = [:]
  private var thumbDay: String?

  func reload(_ store: JournalStore) {
    DispatchQueue.global(qos: .userInitiated).async {
      let i = JournalIndex(store: store)
      DispatchQueue.main.async { self.index = i }
    }
  }

  /// Handwriting previews for one day, rendered from its saved ink in the background.
  func loadThumbnails(_ store: JournalStore, day: String, page: JournalPage, dark: Bool) {
    guard thumbDay != day + (dark ? "d" : "l") else { return }
    thumbDay = day + (dark ? "d" : "l")
    thumbnails = [:]
    let inks = page.entries.filter { $0.kind == .ink }
    guard !inks.isEmpty else { return }
    DispatchQueue.global(qos: .userInitiated).async {
      guard let strokes = try? SessionArchive.load(from: store.dayDir(day)).1 else { return }
      let byID = Dictionary(strokes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
      var out: [String: NSImage] = [:]
      for e in inks {
        let s = e.strokeIDs.compactMap { byID[$0] }
        if let img = JournalController.renderThumbnail(s, dark: dark) { out[e.id] = img }
      }
      DispatchQueue.main.async {
        guard self.thumbDay == day + (dark ? "d" : "l") else { return }
        self.thumbnails = out
      }
    }
  }
}

final class JournalHistoryWindow {
  private var window: NSWindow?
  private let journal: JournalController
  private let model = JournalHistoryModel()

  init(journal: JournalController) {
    self.journal = journal
    journal.historyOpener = { [weak self] in self?.show() }
  }

  func show() {
    model.reload(journal.store)
    if window == nil {
      let w = NSWindow(
        contentViewController: NSHostingController(
          rootView: JournalHistoryView(journal: journal, model: model)))
      w.title = "Journal"
      w.styleMask = [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView]
      w.titlebarAppearsTransparent = true
      w.isReleasedWhenClosed = false
      w.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
      w.setContentSize(NSSize(width: 820, height: 560))
      w.center()
      window = w
    }
    NSApp.activate(ignoringOtherApps: true)
    window?.makeKeyAndOrderFront(nil)
  }
}

struct JournalHistoryView: View {
  @ObservedObject var journal: JournalController
  @ObservedObject var model: JournalHistoryModel
  @State private var month = Calendar.current.date(
    from: Calendar.current.dateComponents([.year, .month], from: Date()))!
  @State private var selected = JournalCalendar.dayID(for: Date())
  @State private var query = ""
  @Environment(\.colorScheme) private var scheme

  private var days: Set<String> { model.index?.dayIDs ?? [] }

  var body: some View {
    HStack(spacing: 0) {
      sidebar.frame(width: 290)
      Divider()
      detail.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .frame(minWidth: 720, minHeight: 460)
    // The open page may have changed (new entries): refresh the index.
    .onChange(of: journal.page) { _ in model.reload(journal.store) }
  }

  // MARK: Sidebar: search, month, days

  private var sidebar: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 6) {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        TextField("Search all days", text: $query).textFieldStyle(.plain)
        if !query.isEmpty {
          Button {
            query = ""
          } label: {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
          }
          .buttonStyle(.borderless)
        }
      }
      .padding(7)
      .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
      .padding(.top, 30)

      if query.isEmpty {
        monthHeader
        calendarGrid
        Divider().padding(.vertical, 2)
        dayList
      } else {
        searchResults
      }
    }
    .padding(.horizontal, 12)
    .padding(.bottom, 12)
    .background(.regularMaterial)
  }

  private var monthHeader: some View {
    HStack {
      Text(month.formatted(.dateTime.month(.wide).year())).font(.headline)
      Spacer()
      Button {
        shift(-1)
      } label: {
        Image(systemName: "chevron.left")
      }.buttonStyle(.borderless)
      Button("Today") { pick(JournalCalendar.dayID(for: Date())) }.buttonStyle(.borderless).font(
        .callout)
      Button {
        shift(1)
      } label: {
        Image(systemName: "chevron.right")
      }.buttonStyle(.borderless)
    }
  }

  private var calendarGrid: some View {
    let cal = Calendar.current
    let first = cal.component(.weekday, from: month) - cal.firstWeekday
    let count = cal.range(of: .day, in: .month, for: month)!.count
    let cells = Array(repeating: 0, count: (first + 7) % 7) + Array(1...count)
    let today = JournalCalendar.dayID(for: Date())
    return VStack(spacing: 2) {
      HStack(spacing: 0) {
        ForEach(cal.veryShortWeekdaySymbols.rotated(cal.firstWeekday - 1), id: \.self) {
          Text($0).font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity)
        }
      }
      LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 2)
      {
        ForEach(Array(cells.enumerated()), id: \.offset) { _, d in
          if d == 0 {
            Color.clear.frame(height: 28)
          } else {
            let id = dayID(d)
            let has = days.contains(id)
            let isSel = id == selected
            Button {
              pick(id)
            } label: {
              VStack(spacing: 1) {
                Text("\(d)")
                  .font(.callout.weight(id == today ? .bold : .regular))
                  .foregroundStyle(isSel ? Color.white : id == today ? Color.accentColor : .primary)
                Circle().fill(has ? (isSel ? Color.white : Color.accentColor) : .clear).frame(
                  width: 4, height: 4)
              }
              .frame(maxWidth: .infinity, minHeight: 28)
              .background(
                Circle().fill(isSel ? Color.accentColor : .clear).frame(width: 28, height: 28)
              )
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(has ? "Has entries" : "No entries")
          }
        }
      }
    }
  }

  private var dayList: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 2) {
        if let index = model.index, index.days.isEmpty {
          Text("Your journal is empty. Press ⌃⌥N to write today's first entry.")
            .font(.callout).foregroundStyle(.secondary).padding(.vertical, 8)
        }
        ForEach(model.index?.days ?? []) { d in
          Button {
            pick(d.day)
          } label: {
            dayRow(d)
          }.buttonStyle(.plain)
        }
        if model.index == nil {
          ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding()
        }
      }
    }
  }

  private func dayRow(_ d: JournalIndex.Day) -> some View {
    HStack(alignment: .top, spacing: 8) {
      VStack(alignment: .leading, spacing: 2) {
        Text(
          JournalCalendar.start(of: d.day)?.formatted(
            .dateTime.weekday(.abbreviated).day().month(.abbreviated)) ?? d.day
        )
        .font(.callout.weight(.semibold))
        if !d.preview.isEmpty {
          Text(d.preview).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
      }
      Spacer(minLength: 4)
      HStack(spacing: 6) {
        if d.ink > 0 { badge("pencil.tip", "\(d.ink)") }
        if d.notes > 0 { badge("text.alignleft", "\(d.notes)") }
        if d.tasks > 0 { badge("checklist", "\(d.tasksDone)/\(d.tasks)") }
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .background(
      RoundedRectangle(cornerRadius: 8).fill(
        d.day == selected ? Color.accentColor.opacity(0.18) : .clear)
    )
    .contentShape(Rectangle())
  }

  private func badge(_ icon: String, _ text: String) -> some View {
    HStack(spacing: 2) {
      Image(systemName: icon)
      Text(text)
    }
    .font(.caption2.monospacedDigit())
    .foregroundStyle(.secondary)
  }

  private var searchResults: some View {
    let hits = model.index?.search(query) ?? []
    return ScrollView {
      LazyVStack(alignment: .leading, spacing: 2) {
        Text(hits.isEmpty ? "No matches" : "\(hits.count) match\(hits.count == 1 ? "" : "es")")
          .font(.caption).foregroundStyle(.secondary)
        ForEach(Array(hits.enumerated()), id: \.offset) { _, hit in
          Button {
            pick(hit.day)
          } label: {
            VStack(alignment: .leading, spacing: 2) {
              Text(
                JournalCalendar.start(of: hit.day)?.formatted(date: .abbreviated, time: .omitted)
                  ?? hit.day
              )
              .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
              Text(hit.snippet).lineLimit(2)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
              RoundedRectangle(cornerRadius: 8).fill(
                hit.day == selected ? Color.accentColor.opacity(0.18) : .clear)
            )
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
        }
      }
    }
  }

  // MARK: Detail: the selected day

  private var detail: some View {
    let page =
      (selected == journal.day && journal.active)
      ? journal.page : (model.index?.page(selected) ?? JournalPage(day: selected))
    let isOpen = selected == journal.day && journal.active
    return VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 2) {
          Text(JournalCalendar.start(of: selected)?.formatted(.dateTime.weekday(.wide)) ?? "")
            .font(.callout.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
          Text(
            JournalCalendar.start(of: selected)?.formatted(.dateTime.day().month(.wide).year())
              ?? selected
          )
          .font(.largeTitle.weight(.semibold))
          if !page.title.isEmpty { Text(page.title).font(.title3).foregroundStyle(.secondary) }
        }
        Spacer()
        Button(isOpen && !journal.hidden ? "Open Now" : "Open in Journal") {
          journal.open(day: selected)
        }
        .buttonStyle(.borderedProminent)
        .disabled(isOpen && !journal.hidden)
      }
      .padding(.horizontal, 24)
      .padding(.top, 34)
      .padding(.bottom, 12)
      Divider()
      if page.entries.isEmpty {
        VStack(spacing: 6) {
          Image(systemName: "book.closed").font(.system(size: 30, weight: .light)).foregroundStyle(
            .tertiary)
          Text("No entries on this day").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(page.entries) { e in
              JournalEntryRow(entry: e, journal: nil, thumbnail: model.thumbnails[e.id])
            }
          }
          .padding(.horizontal, 14)
          .padding(.vertical, 10)
        }
      }
    }
    .onAppear {
      model.loadThumbnails(journal.store, day: selected, page: page, dark: scheme == .dark)
    }
    .onChange(of: selected) { d in
      let p = model.index?.page(d) ?? JournalPage(day: d)
      model.loadThumbnails(journal.store, day: d, page: p, dark: scheme == .dark)
    }
    .onChange(of: model.index?.days.count) { _ in
      model.loadThumbnails(journal.store, day: selected, page: page, dark: scheme == .dark)
    }
  }

  private func dayID(_ d: Int) -> String {
    let c = Calendar.current.dateComponents([.year, .month], from: month)
    return String(format: "%04d-%02d-%02d", c.year!, c.month!, d)
  }

  private func shift(_ m: Int) {
    month = Calendar.current.date(byAdding: .month, value: m, to: month)!
  }

  private func pick(_ id: String) {
    selected = id
    if let s = JournalCalendar.start(of: id) {
      month = Calendar.current.date(
        from: Calendar.current.dateComponents([.year, .month], from: s))!
    }
  }
}

extension Array {
  fileprivate func rotated(_ n: Int) -> [Element] {
    guard !isEmpty else { return self }
    let k = ((n % count) + count) % count
    return Array(self[k...]) + Array(self[..<k])
  }
}
