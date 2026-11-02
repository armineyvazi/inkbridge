import AppKit
import InkBridgeCore
import SwiftUI

/// `InkBridge --self-test`: interaction checks inside the real app process,
/// against the displays actually connected. Prints PASS/FAIL lines and exits
/// with the number of failures. It never starts the server or touches sessions.
///
/// Covers what unit tests cannot: real NSScreen geometry (negative and
/// non-zero origins, mixed scale factors), real NSWindow flags, and real
/// event routing from the window to the view.
enum SelfTest {
  static func run() -> Int32 {
    var failures = 0
    func check(_ ok: Bool, _ what: String) {
      print(ok ? "PASS" : "FAIL", what)
      if !ok { failures += 1 }
    }
    let screens = NSScreen.screens
    print("displays: \(screens.count)")
    for s in screens {
      print("  \(s.localizedName) frame=\(s.frame) scale=\(s.backingScaleFactor)")
    }

    let store = StrokeStore()
    for (i, screen) in screens.enumerated() {
      let surface = CGSize(width: 1404, height: 1872)
      let mapper = CoordinateMapper(
        canvas: screen.frame.size, surface: surface, viewport: Viewport(x: -50, y: 30, zoom: 1.3))
      let view = OverlayView(store: store, mapper: mapper)
      let window = OverlayWindow(screen: screens[0], content: view)
      window.move(to: screens[(i + 1) % screens.count])
      window.move(to: screen)  // moving between displays must land exactly on the target
      check(
        window.frame == screen.frame,
        "[\(screen.localizedName)] overlay covers exactly \(screen.frame) (got \(window.frame))")

      for mode in CanvasBackground.Mode.allCases {
        for pm in PointerMode.allCases {
          let w = WindowInteraction.resolve(workspace: mode, pointer: pm)
          window.apply(w, studio: mode == .studio)
          check(
            window.ignoresMouseEvents == w.clickThrough && window.canBecomeKey == w.canBecomeKey,
            "[\(screen.localizedName)] \(mode)/\(pm): clickThrough=\(window.ignoresMouseEvents) key=\(window.canBecomeKey)"
          )
        }
      }

      // Event routing: synthetic mouse events through the window reach the view at the right points.
      window.apply(.resolve(workspace: .studio, pointer: .draw), studio: true)
      window.alphaValue = 0.01
      window.orderFrontRegardless()
      var got: [OverlayView.MouseEvent] = []
      view.onMouse = { got.append($0) }
      let targets = [
        CGPoint(x: 120, y: 90), CGPoint(x: screen.frame.width - 40, y: screen.frame.height - 30),
      ]
      for (k, t) in targets.enumerated() {
        // locationInWindow is bottom-left; the view is flipped (top-left).
        let loc = NSPoint(x: t.x, y: screen.frame.height - t.y)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseDragged, .leftMouseUp] {
          if let e = NSEvent.mouseEvent(
            with: type, location: loc, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: k,
            clickCount: 1, pressure: 1)
          {
            window.sendEvent(e)
          }
        }
      }
      var b = MouseStrokeBuilder(prefix: "st")
      var ok = got.count == 6
      for (k, t) in targets.enumerated() where ok {
        guard case .down(let p) = got[k * 3] else {
          ok = false
          break
        }
        ok = abs(p.x - t.x) < 0.5 && abs(p.y - t.y) < 0.5
        if case .begin(_, let ink) = b.down(p, mapper: mapper, t: 0) {
          let back = mapper.map(ink)
          ok = ok && abs(back.x - t.x) < 0.5 && abs(back.y - t.y) < 0.5
        }
        _ = b.up()
      }
      check(
        ok,
        "[\(screen.localizedName)] mouse events reach the view and map to canvas and back (\(got.count) events)"
      )
      window.orderOut(nil)
    }
    print(failures == 0 ? "SELF-TEST PASSED" : "SELF-TEST FAILED: \(failures)")
    return Int32(failures)
  }

  /// Renders a template exactly as the overlay and exports do.
  static func render(_ t: DiagramTemplate, to url: URL, dark: Bool) -> Int32 {
    let d = t.build(center: CGPoint(x: 700, y: 450))
    let mapper = CoordinateMapper(
      canvas: CGSize(width: 1400, height: 900), surface: CGSize(width: 1400, height: 900))
    let bg = CanvasBackground.studio(
      dark ? CanvasBackground.black : CanvasBackground.white, pattern: .engineering)
    SessionArchive.exportDiagram = d
    SessionArchive.exportIcon = InkCoordinator.icon
    defer {
      SessionArchive.exportDiagram = Diagram()
      SessionArchive.exportIcon = nil
    }
    guard
      let img = try? SessionArchive.renderImage(
        [], mapper: mapper, background: nil, canvasBackground: bg, scale: 1),
      (try? SessionArchive.writeImage(img, to: url, type: .png)) != nil
    else { return 1 }
    print(
      "rendered \(t.rawValue): \(d.nodes.count) components, \(d.edges.count) connectors → \(url.path)"
    )
    return 0
  }

  /// Developer: renders the journal panel (and History) with sample content, for design review
  /// without screen-recording permission. `--render-journal OUT_DIR [--dark]`.
  static func renderJournal(to dir: URL, dark: Bool) -> Int32 {
    let c = InkCoordinator(model: AppModel())
    // Two bursts of "handwriting": looping strokes like cursive.
    func word(_ id: String, x0: Double, y0: Double, len: Int) -> Stroke {
      Stroke(
        id: id, tool: .pen, style: StrokeStyle(color: .black, width: 3, pressureSensitive: true),
        points: (0..<len).map { k in
          let t = Double(k) / 6
          return InkPoint(
            x: x0 + t * 9 + cos(t * 2.1) * 8, y: y0 + sin(t * 2.1) * 14 + sin(t * 0.7) * 4,
            p: 0.4 + 0.4 * abs(sin(t)), t: Int64(k))
        })
    }
    let strokes = [
      word("a1", x0: 200, y0: 300, len: 160), word("a2", x0: 420, y0: 300, len: 120),
      word("b1", x0: 200, y0: 520, len: 200),
    ]
    c.store.load(strokes)
    let cal = Calendar.current
    let at = { (h: Int, m: Int) in cal.date(bySettingHour: h, minute: m, second: 0, of: Date())! }
    var page = JournalPage(
      day: JournalCalendar.dayID(for: Date()), title: "Planning the sync engine")
    page.trackInk(present: ["a1", "a2"], at: at(9, 15))
    _ = page.addNote(
      "Offline-first: the tablet never waits for the Mac before drawing", at: at(9, 24))
    _ = page.addNote("Measure input → ink on the BOOX", kind: .task, at: at(10, 2))
    let done = page.addNote("Book the design review", kind: .task, at: at(10, 5))
    page.update(done.id, done: true, at: at(11, 40))
    page.trackInk(present: ["a1", "a2", "b1"], at: at(14, 31))
    c.journal.page = page
    let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    var ok = true
    func snap<V: View>(_ v: V, _ size: NSSize, _ name: String) {
      let host = NSHostingView(rootView: v.frame(width: size.width, height: size.height))
      host.frame = NSRect(origin: .zero, size: size)
      let w = NSWindow(
        contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
      w.appearance = appearance
      w.backgroundColor = dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.97, alpha: 1)
      w.contentView = host
      host.layoutSubtreeIfNeeded()
      RunLoop.main.run(until: Date().addingTimeInterval(0.6))  // thumbnails, async loads
      guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
        ok = false
        return
      }
      host.cacheDisplay(in: host.bounds, to: rep)
      let url = dir.appendingPathComponent("\(name)\(dark ? "-dark" : "").png")
      if (try? rep.representation(using: .png, properties: [:])?.write(to: url)) == nil {
        ok = false
      }
      print("rendered \(url.path)")
    }
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    snap(
      JournalPanelView(journal: c.journal, storage: c.storage), NSSize(width: 308, height: 620),
      "journal-panel")
    c.journal.page = JournalPage(day: JournalCalendar.dayID(for: Date()))
    snap(
      JournalPanelView(journal: c.journal, storage: c.storage), NSSize(width: 308, height: 420),
      "journal-panel-empty")
    return ok ? 0 : 1
  }
}
