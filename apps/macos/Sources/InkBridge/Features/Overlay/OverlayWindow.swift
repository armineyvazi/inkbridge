import AppKit
import InkBridgeCore

/// A transparent, click-through window covering one display.
///
/// - `ignoresMouseEvents` makes the window server deliver clicks and scrolls
///   to whatever is underneath, so the overlay never blocks the user.
/// - `.screenSaver` level keeps ink above normal and full-screen app windows
///   (but below system alerts).
/// - `.canJoinAllSpaces` + `.fullScreenAuxiliary` let it appear on every
///   Space, including a full-screen app's Space; `.stationary` keeps it from
///   sliding during Space transitions.
final class OverlayWindow: NSWindow {
  init(screen: NSScreen, content: NSView) {
    super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
    isOpaque = false
    backgroundColor = .clear
    hasShadow = false
    ignoresMouseEvents = true
    isReleasedWhenClosed = false
    level = .screenSaver
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    animationBehavior = .none
    contentView = content
    move(to: screen)
  }

  private var mayBecomeKey = false

  /// Applies the interaction policy (InteractionPolicy.swift).
  func apply(_ interaction: WindowInteraction, studio: Bool) {
    ignoresMouseEvents = interaction.clickThrough
    isOpaque = studio
    mayBecomeKey = interaction.canBecomeKey
    if !mayBecomeKey && isKeyWindow { resignKey() }
  }

  func move(to screen: NSScreen) {
    setFrame(screen.frame, display: true)
  }

  // The overlay never steals keyboard focus from the app being annotated;
  // the studio may, so Esc / ⌘Z reach it.
  override var canBecomeKey: Bool { mayBecomeKey }
  override var canBecomeMain: Bool { false }
}

/// Screens with stable identifiers for the display picker.
enum DisplayManager {
  struct Display: Identifiable, Hashable {
    let id: CGDirectDisplayID
    let name: String
    let size: CGSize

    // CGSize was not Hashable on older SDKs used by GitHub's macos-14 image.
    static func == (lhs: Display, rhs: Display) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
  }

  static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
    (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map {
      CGDirectDisplayID($0.uint32Value)
    }
  }

  static var displays: [Display] {
    NSScreen.screens.compactMap { s in
      displayID(of: s).map { Display(id: $0, name: s.localizedName, size: s.frame.size) }
    }
  }

  /// The selected screen, or the primary display (the one with the menu bar)
  /// if none is selected or it was unplugged. Not `NSScreen.main`: that follows
  /// the focused window, so ink would jump between monitors as you click around.
  static func screen(for id: CGDirectDisplayID?) -> NSScreen? {
    if let id, let s = NSScreen.screens.first(where: { displayID(of: $0) == id }) { return s }
    return NSScreen.screens.first
  }

  /// The display under the mouse pointer.
  static func screenUnderMouse() -> NSScreen? {
    let p = NSEvent.mouseLocation
    return NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) }
  }
}
