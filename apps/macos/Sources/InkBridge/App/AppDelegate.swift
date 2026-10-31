import AppKit
import InkBridgeCore

/// App lifecycle, including crash recovery of the last session.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: InkCoordinator!
    private var menuBar: MenuBarController!
    private let defaults = UserDefaults.standard

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A menu-bar utility: no Dock icon, never steals focus by launching.
        NSApp.setActivationPolicy(.accessory)

        let model = AppModel()
        // If the last run did not exit cleanly, continue its session so
        // strokes drawn before the crash come back.
        let crashed = defaults.object(forKey: "cleanExit") as? Bool == false
        let lastSession = defaults.string(forKey: "lastSessionID")
        coordinator = InkCoordinator(model: model, sessionID: crashed ? lastSession : nil)
        coordinator.start()
        if crashed, let lastSession, coordinator.restore(sessionID: lastSession) {
            model.statusMessage = "Recovered unsaved session"
        }
        defaults.set(false, forKey: "cleanExit")
        menuBar = MenuBarController(coordinator: coordinator)
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.stop()
        defaults.set(true, forKey: "cleanExit")
    }
}
