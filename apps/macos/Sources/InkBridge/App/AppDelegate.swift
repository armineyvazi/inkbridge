import AppKit
import InkBridgeCore

/// App lifecycle, including crash recovery of the last session.
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var coordinator: InkCoordinator!
  private var menuBar: MenuBarController!
  private let defaults = UserDefaults.standard

  func applicationDidFinishLaunching(_ notification: Notification) {
    let args = CommandLine.arguments
    if args.contains("--self-test") {
      exit(SelfTest.run())
    }
    // Developer: render a template with the real renderer and icons, then exit.
    if let i = args.firstIndex(of: "--render-template"), args.count > i + 2,
      let t = DiagramTemplate(rawValue: args[i + 1])
    {
      exit(SelfTest.render(t, to: URL(fileURLWithPath: args[i + 2]), dark: args.contains("--dark")))
    }
    if let i = args.firstIndex(of: "--render-journal"), args.count > i + 1 {
      exit(
        SelfTest.renderJournal(to: URL(fileURLWithPath: args[i + 1]), dark: args.contains("--dark"))
      )
    }
    // A menu-bar utility: no Dock icon, never steals focus by launching.
    NSApp.setActivationPolicy(.accessory)

    let model = AppModel()
    // If the last run did not exit cleanly, continue its session so
    // strokes drawn before the crash come back.
    let crashed = defaults.object(forKey: "cleanExit") as? Bool == false
    coordinator = InkCoordinator(model: model)
    coordinator.start()
    if crashed, coordinator.restoreLastSession() {
      model.statusMessage = "Recovered your last session"
    }
    defaults.set(false, forKey: "cleanExit")
    menuBar = MenuBarController(coordinator: coordinator)
    // Developer: open Engineering with a template, for end-to-end checks with the tablet.
    if let i = CommandLine.arguments.firstIndex(of: "--demo-template"),
      CommandLine.arguments.count > i + 1,
      let t = DiagramTemplate(rawValue: CommandLine.arguments[i + 1])
    {
      coordinator.setEngineering(true)
      coordinator.insertTemplate(t)
    }
    // First run (no tablet paired yet): show the pairing code right away instead of
    // making people find the menu-bar icon, which a MacBook notch can hide.
    if model.pairedDevices.isEmpty {
      DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
        self?.coordinator.openConnectDevice()
      }
    }
  }

  /// Opening InkBridge again (Finder, Spotlight, Launchpad) while it runs shows Connect Device:
  /// a menu-bar utility has no other window to bring forward.
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    coordinator.openConnectDevice()
    return false
  }

  func applicationWillTerminate(_ notification: Notification) {
    coordinator.stop()
    defaults.set(true, forKey: "cleanExit")
  }
}
