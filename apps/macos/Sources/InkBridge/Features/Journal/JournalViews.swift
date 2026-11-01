import AppKit
import InkBridgeCore
import SwiftUI

/// The journal's floating panel: date, title, timestamped entries, quick capture.
final class JournalPanelController {
    private var panel: NSPanel?
    private let journal: JournalController

    init(journal: JournalController) { self.journal = journal }

    func show(on screen: NSScreen?) {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 560),
                            styleMask: [.titled, .utilityWindow, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
            p.title = "Daily Journal"
            p.isFloatingPanel = true
            p.becomesKeyOnlyIfNeeded = true
            p.hidesOnDeactivate = false
            p.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.contentViewController = NSHostingController(rootView: JournalPanelView(journal: journal))
            panel = p
        }
        if let f = (screen ?? NSScreen.screens.first)?.visibleFrame {
            let h = min(620, f.height - 40)
            panel?.setFrame(NSRect(x: f.minX + 12, y: f.maxY - h - 12, width: 320, height: h), display: true)
        }
        panel?.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }
}

struct JournalPanelView: View {
    @ObservedObject var journal: JournalController
    @State private var draft = ""
    @State private var asTask = false

    private var date: Date { JournalCalendar.start(of: journal.day) ?? Date() }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button { journal.step(-1) } label: { Image(systemName: "chevron.left") }.help("Previous day")
                VStack(alignment: .leading, spacing: 1) {
                    Text(date.formatted(.dateTime.weekday(.wide))).font(.caption).foregroundStyle(.secondary)
                    Text(date.formatted(.dateTime.day().month(.wide).year())).font(.headline)
                }
                Spacer()
                if journal.isToday {
                    Text("Today").font(.caption.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                } else {
                    Button("Today") { journal.switchDay(to: JournalCalendar.dayID(for: Date())) }.controlSize(.small)
                }
                Button { journal.step(1) } label: { Image(systemName: "chevron.right") }.help("Next day")
            }
            TextField("Title or summary for the day (optional)", text: Binding(get: { journal.page.title }, set: { journal.setTitle($0) }))
                .textFieldStyle(.roundedBorder)

            HStack {
                TextField(asTask ? "New task…" : "Quick note… (Return to add)", text: $draft, onCommit: add)
                    .textFieldStyle(.roundedBorder)
                Toggle(isOn: $asTask) { Image(systemName: "checklist") }.toggleStyle(.button).help("Add as a task")
            }

            List {
                ForEach(journal.page.entries.reversed()) { e in entryRow(e) }
            }
            .listStyle(.plain)
            .frame(minHeight: 200)

            HStack {
                Toggle("Times on page", isOn: $journal.showTimes).font(.caption)
                Spacer()
                if let err = journal.pageError {
                    Label("Save failed", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.caption).help(err)
                }
            }
            HStack {
                Button("History…") { journal.coordinatorHistory() }
                Spacer()
                Button("Done") { journal.close() }.keyboardShortcut(.defaultAction).help("Back to your work, exactly as you left it (⌃⌥N)")
            }
        }
        .padding(12)
        .frame(minWidth: 300)
    }

    private func add() {
        journal.addEntry(draft, kind: asTask ? .task : .note)
        draft = ""
    }

    @ViewBuilder private func entryRow(_ e: JournalEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(e.createdAt.formatted(date: .omitted, time: .shortened)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .help("Created \(e.createdAt.formatted(date: .abbreviated, time: .standard)) · edited \(e.modifiedAt.formatted(date: .abbreviated, time: .standard))")
            switch e.kind {
            case .ink:
                Label("Handwriting · \(e.strokeIDs.count) stroke\(e.strokeIDs.count == 1 ? "" : "s")", systemImage: "pencil.tip")
                    .font(.callout).foregroundStyle(.secondary)
                if e.modifiedAt.timeIntervalSince(e.createdAt) > 60 {
                    Text("until \(e.modifiedAt.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                }
            case .task:
                Toggle("", isOn: Binding(get: { e.done }, set: { journal.update(e.id, done: $0) })).labelsHidden()
                TextField("", text: Binding(get: { e.text }, set: { journal.update(e.id, text: $0) })).strikethrough(e.done)
            case .note:
                TextField("", text: Binding(get: { e.text }, set: { journal.update(e.id, text: $0) }))
            }
            Spacer(minLength: 0)
            if e.kind != .ink {
                Button { journal.remove(e.id) } label: { Image(systemName: "xmark.circle") }.buttonStyle(.borderless).help("Remove")
            }
        }
    }
}

extension JournalController {
    func coordinatorHistory() { historyOpener?() }
}

/// Calendar + search over every journal day.
final class JournalHistoryWindow {
    private var window: NSWindow?
    private let journal: JournalController

    init(journal: JournalController) {
        self.journal = journal
        journal.historyOpener = { [weak self] in self?.show() }
    }

    func show() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: JournalHistoryView(journal: journal)))
            w.title = "Journal History"
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

struct JournalHistoryView: View {
    @ObservedObject var journal: JournalController
    @State private var month = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: Date()))!
    @State private var selected = JournalCalendar.dayID(for: Date())
    @State private var query = ""

    private var days: Set<String> { _ = journal.page; return Set(journal.store.days()) }

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(spacing: 10) {
                HStack {
                    Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                    Spacer()
                    Text(month.formatted(.dateTime.month(.wide).year())).font(.headline)
                    Spacer()
                    Button { shift(1) } label: { Image(systemName: "chevron.right") }
                }
                calendarGrid
                Button("Go to Today") { pick(JournalCalendar.dayID(for: Date())) }
                Spacer()
            }
            .frame(width: 300)
            VStack(alignment: .leading, spacing: 8) {
                TextField("Search all days", text: $query).textFieldStyle(.roundedBorder)
                if !query.isEmpty {
                    List(Array(journal.store.search(query).enumerated()), id: \.offset) { _, hit in
                        Button { pick(hit.day); query = "" } label: {
                            VStack(alignment: .leading) {
                                Text(hit.day).font(.caption).foregroundStyle(.secondary)
                                Text(hit.snippet).lineLimit(2)
                            }
                        }.buttonStyle(.plain)
                    }
                } else {
                    let page = journal.store.loadPage(selected)
                    Text(JournalCalendar.start(of: selected)?.formatted(date: .complete, time: .omitted) ?? selected).font(.headline)
                    if !page.title.isEmpty { Text(page.title).foregroundStyle(.secondary) }
                    List(page.entries) { e in
                        HStack(alignment: .firstTextBaseline) {
                            Text(e.createdAt.formatted(date: .omitted, time: .shortened)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            Text(e.kind == .ink ? "✎ Handwriting" : (e.kind == .task ? (e.done ? "☑ " : "☐ ") + e.text : e.text)).lineLimit(2)
                        }
                    }
                    Button(selected == journal.day && journal.active ? "Open now" : "Open and edit this day") { journal.open(day: selected) }
                        .disabled(selected == journal.day && journal.active)
                }
            }
        }
        .padding(16)
        .frame(minWidth: 680, minHeight: 420)
    }

    private var calendarGrid: some View {
        let cal = Calendar.current
        let first = cal.component(.weekday, from: month) - cal.firstWeekday
        let count = cal.range(of: .day, in: .month, for: month)!.count
        let cells = Array(repeating: 0, count: (first + 7) % 7) + Array(1...count)
        return VStack(spacing: 6) {
            HStack { ForEach(cal.veryShortWeekdaySymbols.rotated(cal.firstWeekday - 1), id: \.self) { Text($0).font(.caption).frame(maxWidth: .infinity) } }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 6) {
                ForEach(Array(cells.enumerated()), id: \.offset) { _, d in
                    if d == 0 { Color.clear.frame(height: 30) } else {
                        let id = dayID(d)
                        Button { pick(id) } label: {
                            Text("\(d)").font(.callout.weight(days.contains(id) ? .bold : .regular))
                                .frame(maxWidth: .infinity, minHeight: 30)
                                .background(RoundedRectangle(cornerRadius: 6).fill(id == selected ? Color.accentColor.opacity(0.3)
                                                                                   : days.contains(id) ? Color.secondary.opacity(0.15) : .clear))
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(id == JournalCalendar.dayID(for: Date()) ? Color.accentColor : .clear, lineWidth: 1.5))
                        }
                        .buttonStyle(.plain)
                        .help(days.contains(id) ? "Has entries" : "Empty")
                    }
                }
            }
        }
    }

    private func dayID(_ d: Int) -> String {
        let c = Calendar.current.dateComponents([.year, .month], from: month)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, d)
    }

    private func shift(_ m: Int) { month = Calendar.current.date(byAdding: .month, value: m, to: month)! }

    private func pick(_ id: String) {
        selected = id
        if let s = JournalCalendar.start(of: id) { month = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: s))! }
    }
}

private extension Array {
    func rotated(_ n: Int) -> [Element] {
        guard !isEmpty else { return self }
        let k = ((n % count) + count) % count
        return Array(self[k...]) + Array(self[..<k])
    }
}
