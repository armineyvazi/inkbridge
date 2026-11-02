import AppKit
import InkBridgeCore
import SwiftUI

enum DiagramTool: String, CaseIterable { case select, connect }

/// Engineering workspace state shown in the panel (the diagram itself lives in StrokeStore).
final class EngineeringModel: ObservableObject {
  @Published var active = false
  @Published var tool: DiagramTool = .select
  @Published var connectorKind: DiagramEdge.Kind = .http
  @Published var connectorStyle: DiagramEdge.Style = .orthogonal
  @Published var snap = true
  @Published var selection: Set<String> = []
  @Published var query = ""
  /// Bumped when the diagram changes so the inspector re-reads it.
  @Published var diagramVersion = 0
}

/// Actions the panel triggers; implemented by InkCoordinator.
protocol EngineeringActions: AnyObject {
  var diagram: Diagram { get }
  func addComponent(_ kind: String)
  func insertTemplate(_ t: DiagramTemplate)
  func updateNode(_ id: String, label: String?, detail: String?)
  func updateEdge(_ id: String, label: String?, kind: DiagramEdge.Kind?, style: DiagramEdge.Style?)
  func align(_ a: DiagramEditing.Alignment)
  func deleteSelection()
  func duplicateSelection()
  func setEngineering(_ on: Bool)
}

/// A floating tool panel docked to the right of the drawing display.
final class EngineeringPanelController: NSObject, NSWindowDelegate {
  private var panel: NSPanel?
  private let model: EngineeringModel
  private weak var actions: EngineeringActions?

  init(model: EngineeringModel, actions: EngineeringActions) {
    self.model = model
    self.actions = actions
  }

  func show(on screen: NSScreen?) {
    if panel == nil {
      let p = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: 300, height: 640),
        styleMask: [.titled, .closable, .utilityWindow, .resizable, .nonactivatingPanel],
        backing: .buffered, defer: false)
      p.title = "Engineering"
      p.isFloatingPanel = true
      p.becomesKeyOnlyIfNeeded = true
      p.hidesOnDeactivate = false
      p.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
      p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
      p.contentViewController = NSHostingController(
        rootView: EngineeringPanelView(model: model, actions: actions))
      p.delegate = self
      panel = p
    }
    place(on: screen)
    panel?.orderFrontRegardless()
  }

  func hide() { panel?.orderOut(nil) }

  func place(on screen: NSScreen?) {
    guard let panel, let f = (screen ?? NSScreen.screens.first)?.visibleFrame else { return }
    let h = min(720, f.height - 40)
    panel.setFrame(
      NSRect(x: f.maxX - 312, y: f.maxY - h - 12, width: 300, height: h), display: true)
  }

  /// The red traffic-light close must leave Engineering, not just order the panel out
  /// (otherwise the studio stays click-catching with Engineering still "on").
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    actions?.setEngineering(false)
    return false
  }
}

struct EngineeringPanelView: View {
  @ObservedObject var model: EngineeringModel
  weak var actions: EngineeringActions?

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Picker("", selection: $model.tool) {
        Label("Select", systemImage: "cursorarrow").tag(DiagramTool.select)
        Label("Connect", systemImage: "arrow.right.circle").tag(DiagramTool.connect)
      }
      .pickerStyle(.segmented).labelsHidden()
      .help(
        "Select: click, drag to move, corner to resize, drag empty space to select several. Connect: drag from one component to another. (V / C)"
      )

      if model.tool == .connect || selectedEdge != nil { connectorOptions }
      inspector
      Divider()
      library
    }
    .padding(12)
    .frame(minWidth: 280)
    .onAppear { model.diagramVersion += 0 }
  }

  // MARK: Connector style

  private var connectorOptions: some View {
    VStack(alignment: .leading, spacing: 6) {
      Picker(
        "Connection",
        selection: Binding(
          get: { selectedEdge?.kind ?? model.connectorKind },
          set: { k in
            model.connectorKind = k
            if let e = selectedEdge {
              actions?.updateEdge(
                e.id, label: e.label == e.kind.defaultLabel ? k.defaultLabel : nil, kind: k,
                style: nil)
            }
          })
      ) {
        ForEach(DiagramEdge.Kind.allCases, id: \.self) { Text($0.title).tag($0) }
      }
      Picker(
        "Route",
        selection: Binding(
          get: { selectedEdge?.style ?? model.connectorStyle },
          set: { s in
            model.connectorStyle = s
            if let e = selectedEdge { actions?.updateEdge(e.id, label: nil, kind: nil, style: s) }
          })
      ) {
        Text("Orthogonal").tag(DiagramEdge.Style.orthogonal)
        Text("Straight").tag(DiagramEdge.Style.straight)
        Text("Curved").tag(DiagramEdge.Style.curved)
      }
      .pickerStyle(.segmented)
    }
  }

  // MARK: Inspector

  private var selectedNode: DiagramNode? {
    _ = model.diagramVersion
    guard model.selection.count == 1, let id = model.selection.first else { return nil }
    return actions?.diagram.node(id)
  }

  private var selectedEdge: DiagramEdge? {
    _ = model.diagramVersion
    guard model.selection.count == 1, let id = model.selection.first else { return nil }
    return actions?.diagram.edges.first { $0.id == id }
  }

  @ViewBuilder private var inspector: some View {
    if let n = selectedNode {
      VStack(alignment: .leading, spacing: 6) {
        Text(n.component.title).font(.caption).foregroundStyle(.secondary)
        TextField(
          "Label",
          text: Binding(
            get: { n.label }, set: { actions?.updateNode(n.id, label: $0, detail: nil) })
        )
        .textFieldStyle(.roundedBorder)
        Text(
          n.kind == "table"
            ? "Columns (one per line, e.g. id UUID PK)" : "Details (optional, one per line)"
        )
        .font(.caption).foregroundStyle(.secondary)
        TextEditor(
          text: Binding(
            get: { n.detail }, set: { actions?.updateNode(n.id, label: nil, detail: $0) })
        )
        .font(.system(.caption, design: .monospaced)).frame(height: 70)
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(.secondary.opacity(0.3)))
        selectionButtons
      }
    } else if let e = selectedEdge {
      VStack(alignment: .leading, spacing: 6) {
        Text("Connector").font(.caption).foregroundStyle(.secondary)
        TextField(
          "Label",
          text: Binding(
            get: { e.label }, set: { actions?.updateEdge(e.id, label: $0, kind: nil, style: nil) })
        )
        .textFieldStyle(.roundedBorder)
        selectionButtons
      }
    } else if model.selection.count > 1 {
      VStack(alignment: .leading, spacing: 6) {
        Text("\(model.selection.count) selected").font(.caption).foregroundStyle(.secondary)
        HStack {
          alignButton("align.horizontal.left", .left, "Align left edges")
          alignButton("align.horizontal.center", .centerX, "Align centres (vertical line)")
          alignButton("align.horizontal.right", .right, "Align right edges")
          alignButton("align.vertical.top", .top, "Align tops")
          alignButton("align.vertical.center", .centerY, "Align middles")
          alignButton("align.vertical.bottom", .bottom, "Align bottoms")
        }
        HStack {
          alignButton("distribute.horizontal.center", .distributeH, "Distribute horizontally")
          alignButton("distribute.vertical.center", .distributeV, "Distribute vertically")
        }
        selectionButtons
      }
    } else {
      Text(
        "Add a component or a template below, then drag to move. Double-click a component to rename it. Delete removes, ⌘D duplicates, ⌘Z undoes."
      )
      .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
    Toggle("Snap to grid", isOn: $model.snap).font(.caption)
  }

  private var selectionButtons: some View {
    HStack {
      Button("Duplicate") { actions?.duplicateSelection() }
      Button("Delete", role: .destructive) { actions?.deleteSelection() }
    }
    .controlSize(.small)
  }

  private func alignButton(_ symbol: String, _ a: DiagramEditing.Alignment, _ help: String)
    -> some View
  {
    Button {
      actions?.align(a)
    } label: {
      Image(systemName: symbol)
    }.buttonStyle(.borderless).help(help)
  }

  // MARK: Library

  private var library: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        TextField("Search components", text: $model.query).textFieldStyle(.roundedBorder)
        Menu("Templates") {
          ForEach(DiagramTemplate.allCases, id: \.self) { t in
            Button(t.title) { actions?.insertTemplate(t) }
          }
        }
        .fixedSize()
      }
      ScrollView {
        let found = ComponentCatalog.search(model.query)
        LazyVStack(alignment: .leading, spacing: 8) {
          ForEach(ComponentCatalog.categories, id: \.self) { cat in
            let items = found.filter { $0.category == cat }
            if !items.isEmpty {
              Text(cat).font(.caption.bold()).foregroundStyle(.secondary)
              LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), spacing: 6)], spacing: 6) {
                ForEach(items) { c in
                  Button {
                    actions?.addComponent(c.id)
                  } label: {
                    VStack(spacing: 3) {
                      Image(systemName: c.symbol).font(.system(size: 17))
                      Text(c.title).font(.system(size: 10)).lineLimit(2).multilineTextAlignment(
                        .center)
                    }
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(
                      RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))
                  }
                  .buttonStyle(.plain)
                  .help("Add \(c.title)")
                }
              }
            }
          }
        }
      }
    }
  }
}
