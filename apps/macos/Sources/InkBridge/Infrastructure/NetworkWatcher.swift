import AppKit
import Network

/// Calls `onChange` (on main) after the Mac wakes or its network path changes,
/// debounced, so the Wi-Fi listener and its Bonjour advertisement can be
/// re-registered on the interfaces that exist now. NWListener usually
/// survives these events, but a stale advertisement after wake is exactly
/// the kind of failure that makes a tablet "not find the Mac".
final class NetworkWatcher {
  private let monitor = NWPathMonitor()
  private let onChange: () -> Void
  private var pending: DispatchWorkItem?
  private var lastPath: String?

  init(onChange: @escaping () -> Void) {
    self.onChange = onChange
  }

  func start() {
    monitor.pathUpdateHandler = { [weak self] path in
      // Describe what matters: status plus the interfaces in use.
      let key = "\(path.status) " + path.availableInterfaces.map(\.name).joined(separator: ",")
      DispatchQueue.main.async {
        guard let self else { return }
        if let last = self.lastPath, last != key { self.schedule() }
        self.lastPath = key
      }
    }
    monitor.start(queue: DispatchQueue(label: "inkbridge.path"))
    NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification, object: nil,
      queue: .main
    ) { [weak self] _ in self?.schedule() }
  }

  private func schedule() {
    pending?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.onChange() }
    pending = work
    // Interfaces come up in stages after wake; wait for them to settle.
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
  }
}
