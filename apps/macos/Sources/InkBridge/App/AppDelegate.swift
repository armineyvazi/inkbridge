import AppKit
import InkBridgeCore

/// App lifecycle, including crash recovery of the last session.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: InkCoordinator!
    private var menuBar: MenuBarController!
    private let defaults = UserDefaults.standard

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--self-test") {
            exit(SelfTest.run())
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
        // First run (no tablet paired yet): show the pairing code right away instead of
        // making people find the menu-bar icon, which a MacBook notch can hide.
        if model.pairedDevices.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.coordinator.openConnectDevice() }
        }
    }

    /// Opening InkBridge again (Finder, Spotlight, Launchpad) while it runs shows Connect Device:
    /// a menu-bar utility has no other window to bring forward.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        coordinator.openConnectDevice()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.stop()
        defaults.set(true, forKey: "cleanExit")
    }
}
