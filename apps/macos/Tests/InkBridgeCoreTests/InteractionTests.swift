import CoreGraphics
import XCTest

@testable import InkBridgeCore

final class WorkspaceTests: XCTestCase {
  func testJournalOutranksEngineeringAndBackground() {
    let ws = Workspace.resolve(
      background: .overlay, pointer: .draw, engineering: true,
      journalActive: true, journalHidden: false)
    XCTAssertEqual(ws.surface, .journal)
    XCTAssertFalse(ws.allowsOverlayBackground)
    XCTAssertFalse(ws.allowsStorageSessionChange)
    XCTAssertTrue(ws.escapeHidesJournal)
    XCTAssertTrue(ws.usesStudioChrome)
  }

  func testEngineeringForcesPointerInteraction() {
    let ws = Workspace.resolve(
      background: .studio, pointer: .draw, engineering: true, journalActive: false)
    XCTAssertEqual(ws.surface, .engineering)
    XCTAssertFalse(ws.interaction.mouseDraws, "Engineering owns the mouse as a pointer")
    XCTAssertTrue(ws.interaction.mousePans)
    XCTAssertFalse(ws.allowsOverlayBackground)
  }

  func testHiddenJournalIsOffScreen() {
    let hidden = Workspace.resolve(
      background: .studio, pointer: .pointer, engineering: false,
      journalActive: true, journalHidden: true)
    XCTAssertFalse(hidden.canvasOnScreen)
    let putAwayInk = Workspace(surface: .studio, inkVisible: false)
    XCTAssertFalse(putAwayInk.canvasOnScreen)
  }

  /// Regression: opening the journal while "Hide ink" is on must still treat the
  /// canvas as needing to be forced on (UI layer clears inkVisible). Document the
  /// workspace rule so a future change cannot silently drop tablet ink.
  func testJournalWithInkHiddenIsNotOnScreenUntilForced() {
    let ws = Workspace.resolve(
      background: .studio, pointer: .pointer, engineering: false,
      journalActive: true, journalHidden: false, inkVisible: false)
    XCTAssertEqual(ws.surface, .journal)
    XCTAssertFalse(ws.canvasOnScreen, "UI must force overlayVisible before drawing journal ink")
    let visible = Workspace.resolve(
      background: .studio, pointer: .pointer, engineering: false,
      journalActive: true, journalHidden: false, inkVisible: true)
    XCTAssertTrue(visible.canvasOnScreen)
    XCTAssertTrue(visible.escapeLeavesJournal)
  }

  func testOverlayAllowsBackgroundFlip() {
    let ws = Workspace.resolve(
      background: .studio, pointer: .pointer, engineering: false, journalActive: false)
    XCTAssertEqual(ws.surface, .studio)
    XCTAssertTrue(ws.allowsOverlayBackground)
    XCTAssertTrue(ws.allowsStorageSessionChange)
  }
}

final class InteractionTests: XCTestCase {
  func testOverlayPointerIsClickThroughAndOnlyItFollowsClicks() {
    for ws in CanvasBackground.Mode.allCases {
      for pm in PointerMode.allCases {
        let w = WindowInteraction.resolve(workspace: ws, pointer: pm)
        XCTAssertEqual(
          w.followsClicks, w.clickThrough,
          "only a click-through window may follow clicks (\(ws), \(pm))")
        XCTAssertFalse(w.mouseDraws && w.mousePans)
      }
    }
    let overlay = WindowInteraction.resolve(workspace: .overlay, pointer: .pointer)
    XCTAssertTrue(overlay.clickThrough)
    XCTAssertFalse(
      overlay.canBecomeKey, "the overlay never steals keyboard focus from the app being annotated")
  }

  func testStudioCatchesTheMouseAndNeverFollows() {
    // Regression: the opaque studio followed clicks onto the monitor the user was trying to use.
    for pm in PointerMode.allCases {
      let w = WindowInteraction.resolve(workspace: .studio, pointer: pm)
      XCTAssertFalse(w.clickThrough)
      XCTAssertFalse(w.followsClicks)
      XCTAssertTrue(w.canBecomeKey)
      XCTAssertTrue(w.mouseDraws || w.mousePans, "a click on the studio always does something")
    }
  }

  func testOverlayDrawModeLeavesOtherDisplaysUsable() {
    let w = WindowInteraction.resolve(workspace: .overlay, pointer: .draw)
    XCTAssertTrue(w.mouseDraws)
    XCTAssertFalse(w.followsClicks)
    XCTAssertFalse(w.canBecomeKey)
  }

  /// The same view point maps to the same canvas point on any display:
  /// view coordinates are window-local, so a display's global origin
  /// (negative, or not 0,0) and its scale factor never enter the maths.
  func testMouseStrokesMapThroughTheViewportOnAnyDisplay() {
    let surface = CGSize(width: 1404, height: 1872)
    let builtIn = CoordinateMapper(canvas: CGSize(width: 1512, height: 982), surface: surface)
    let msi = CoordinateMapper(
      canvas: CGSize(width: 1920, height: 1080), surface: surface,
      viewport: Viewport(x: 100, y: 200, zoom: 2))
    for mapper in [builtIn, msi] {
      var b = MouseStrokeBuilder(prefix: "m")
      let start = mapper.map(x: 300, y: 400)
      guard case .begin(let id, let p) = b.down(start, mapper: mapper, t: 1) else {
        return XCTFail()
      }
      XCTAssertEqual(id, "m-1")
      XCTAssertEqual(p.x, 300, accuracy: 0.01)
      XCTAssertEqual(p.y, 400, accuracy: 0.01)
      let next = mapper.map(x: 350, y: 420)
      guard case .append(_, let pts)? = b.drag(next, mapper: mapper, t: 2) else { return XCTFail() }
      XCTAssertEqual(pts[0].x, 350, accuracy: 0.01)
      XCTAssertEqual(b.up(), .end(id: "m-1"))
      XCTAssertNil(b.drag(next, mapper: mapper, t: 3), "no stroke after mouse-up")
    }
  }

  func testMouseStrokeGoesIntoTheDocument() {
    let store = StrokeStore()
    let mapper = CoordinateMapper(
      canvas: CGSize(width: 800, height: 600), surface: CGSize(width: 800, height: 600))
    var b = MouseStrokeBuilder(prefix: "m")
    let style = StrokeStyle(color: .red, width: 3, pressureSensitive: false)
    if case .begin(let id, let p) = b.down(CGPoint(x: 10, y: 10), mapper: mapper, t: 0) {
      store.begin(id: id, tool: .pen, style: style, point: p)
    }
    if case .append(let id, let pts)? = b.drag(CGPoint(x: 100, y: 80), mapper: mapper, t: 1) {
      _ = store.append(id: id, points: pts)
    }
    if case .end(let id)? = b.up() { store.end(id: id) }
    XCTAssertEqual(store.strokes.count, 1)
    XCTAssertEqual(store.strokes[0].points.count, 2)
    store.undo()
    XCTAssertTrue(store.strokes.isEmpty, "mouse strokes are undoable like pen strokes")
  }

  func testFitNeverMagnifiesPastActualSize() {
    let v = Viewport.fitting(
      CGRect(x: 100, y: 100, width: 40, height: 20), in: CGSize(width: 1404, height: 1872))
    XCTAssertEqual(v.zoom, 1)
    XCTAssertLessThan(
      Viewport.fitting(
        CGRect(x: 0, y: 0, width: 14040, height: 18720), in: CGSize(width: 1404, height: 1872)
      ).zoom, 0.11)
  }
}
