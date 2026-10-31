import AppKit
import ScreenCaptureKit

/// Optional background screenshot for saved sessions.
///
/// Uses ScreenCaptureKit, which goes through the Screen Recording privacy
/// permission and honours DRM-protected content (it is blacked out, not
/// bypassed). InkBridge's own windows are excluded so ink is not baked into
/// the background twice.
enum ScreenCapture {
    enum CaptureError: Error { case unsupported, noDisplay }

    static func capture(displayID: CGDirectDisplayID) async throws -> CGImage {
        guard #available(macOS 14.0, *) else { throw CaptureError.unsupported }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else { throw CaptureError.noDisplay }
        let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
        let config = SCStreamConfiguration()
        let scale = NSScreen.screens.first { DisplayManager.displayID(of: $0) == displayID }?.backingScaleFactor ?? 2
        config.width = Int(CGFloat(display.width) * scale)
        config.height = Int(CGFloat(display.height) * scale)
        config.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}
