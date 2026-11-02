import Foundation

/// The primary surface the user is working on. These are mutually exclusive:
/// Engineering implies Studio; Journal owns the canvas while open (including when
/// put away). Overlay and Studio are the document's background modes when no
/// higher surface is active.
///
/// Derived from the existing flags (`background.mode`, `engineering.active`,
/// `journal.active`/`hidden`, `pointerMode`, `overlayVisible`) so callers can
/// keep writing those until every path goes through a single transition API.
/// See ADR-010 and `docs/architecture/macos-interaction-model.md`.
public enum WorkspaceSurface: String, CaseIterable, Sendable, Equatable {
  case overlay
  case studio
  case engineering
  case journal
}

/// A single, consistent view of what InkBridge is doing right now.
///
/// Built by [Workspace.resolve]. Use it to decide window policy, whether a
/// background or storage change is allowed, and what Esc should do — never by
/// reading the source flags independently (that is how contradictory states
/// used to appear).
public struct Workspace: Equatable, Sendable {
  public var surface: WorkspaceSurface
  public var pointer: PointerMode
  /// Journal put away without leaving (`journal.hidden`). Only meaningful when
  /// `surface == .journal`; ignored otherwise.
  public var journalHidden: Bool
  /// "Hide ink" — the drawing window is ordered out / not shown.
  public var inkVisible: Bool

  public init(
    surface: WorkspaceSurface, pointer: PointerMode = .pointer,
    journalHidden: Bool = false, inkVisible: Bool = true
  ) {
    self.surface = surface
    self.pointer = pointer
    self.journalHidden = journalHidden
    self.inkVisible = inkVisible
  }

  /// Priority: Journal > Engineering > Studio/Overlay (from the document background).
  public static func resolve(
    background: CanvasBackground.Mode,
    pointer: PointerMode,
    engineering: Bool,
    journalActive: Bool,
    journalHidden: Bool = false,
    inkVisible: Bool = true
  ) -> Workspace {
    let surface: WorkspaceSurface
    if journalActive {
      surface = .journal
    } else if engineering {
      surface = .engineering
    } else {
      surface = background == .studio ? .studio : .overlay
    }
    return Workspace(
      surface: surface, pointer: pointer,
      journalHidden: journalActive && journalHidden, inkVisible: inkVisible)
  }

  /// Window / mouse policy for the current surface.
  /// Engineering always uses the mouse as a pointer (select/pan), never as a pen —
  /// drawing over a diagram is a different mode the user leaves Engineering for.
  public var interaction: WindowInteraction {
    switch surface {
    case .overlay:
      return .resolve(workspace: .overlay, pointer: pointer)
    case .studio, .journal:
      return .resolve(workspace: .studio, pointer: pointer)
    case .engineering:
      return .resolve(workspace: .studio, pointer: .pointer)
    }
  }

  /// Desktop Overlay as a background is only legal when no higher surface owns the canvas.
  public var allowsOverlayBackground: Bool {
    switch surface {
    case .overlay, .studio: return true
    case .engineering, .journal: return false
    }
  }

  /// New/open/switch session would write into the journal day folder if allowed.
  public var allowsStorageSessionChange: Bool {
    surface != .journal
  }

  /// The canvas window should be on screen (not ordered out).
  public var canvasOnScreen: Bool {
    guard inkVisible else { return false }
    if case .journal = surface { return !journalHidden }
    return true
  }

  /// Esc while the journal is open puts it away; otherwise it returns to Desktop Overlay.
  public var escapeHidesJournal: Bool { surface == .journal && !journalHidden }

  /// Whether the opaque studio look (not click-through overlay chrome) is in effect.
  public var usesStudioChrome: Bool {
    switch surface {
    case .overlay: return false
    case .studio, .engineering, .journal: return true
    }
  }
}
