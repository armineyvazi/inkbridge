import AppKit
import CoreImage.CIFilterBuiltins
import InkBridgeCore
import SwiftUI

/// Owns the Connect Device window. Opening it issues a fresh single-use code
/// (valid five minutes); closing it voids the code, so pairing is only
/// possible while someone is looking at this window.
final class ConnectDeviceController: NSObject, NSWindowDelegate {
    private unowned let coordinator: InkCoordinator
    private var window: NSWindow?

    init(coordinator: InkCoordinator) {
        self.coordinator = coordinator
    }

    func show() {
        let model = coordinator.model
        if !model.wifiEnabled { model.wifiEnabled = true }
        model.justPaired = nil
        newCode()
        if window == nil {
            let view = ConnectDeviceView(model: model, newCode: { [weak self] in self?.newCode() },
                                         forget: { [weak self] in self?.coordinator.forget($0) },
                                         done: { [weak self] in self?.window?.close() })
            let w = NSWindow(contentViewController: NSHostingController(rootView: view))
            w.title = "Connect Device"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
            w.delegate = self
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    private func newCode() {
        coordinator.model.justPaired = nil
        coordinator.server.openPairing()
    }

    func windowWillClose(_ notification: Notification) {
        coordinator.server.closePairing()
    }
}

struct ConnectDeviceView: View {
    @ObservedObject var model: AppModel
    var newCode: () -> Void
    var forget: (PairedDevice) -> Void
    var done: () -> Void

    private var hostName: String { Host.current().localizedName ?? "this Mac" }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            if let paired = model.justPaired {
                success(paired)
            } else if let ticket = model.pairingTicket {
                pairing(ticket)
            } else {
                expired
            }
            Divider()
            pairedList
            footer
        }
        .padding(24)
        .frame(width: 520)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Connect a BOOX over Wi-Fi").font(.title2.weight(.semibold))
            Text("Both devices must be on the same Wi-Fi network. No cable or USB debugging is needed.")
                .foregroundStyle(.secondary)
        }
    }

    private func pairing(_ ticket: PairingTicket) -> some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 12) {
                step(1, "On the BOOX, open InkBridge and tap **Connect to Mac**.")
                step(2, "Choose **\(hostName)** from the list.")
                step(3, "Enter this code:")
                Text(ticket.code)
                    .font(.system(size: 34, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.leading, 28)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let left = max(0, Int(ticket.expiresAt.timeIntervalSince(context.date)))
                    HStack {
                        Text("Expires in \(left / 60):\(String(format: "%02d", left % 60)) · works once")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("New code", action: newCode).controlSize(.small)
                    }
                    .padding(.leading, 28)
                }
            }
            Spacer(minLength: 0)
            if let link = link(for: ticket), let image = QRCode.image(for: link.url.absoluteString, size: 168) {
                VStack(spacing: 6) {
                    Image(nsImage: image).interpolation(.none)
                        .frame(width: 168, height: 168)
                    Text("Or scan with a device\nthat has a camera")
                        .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }
        }
    }

    private var expired: some View {
        HStack {
            Image(systemName: "clock.badge.exclamationmark")
            Text("The code expired or was used.")
            Button("Show a new code", action: newCode)
        }
    }

    private func success(_ device: PairedDevice) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill").font(.largeTitle).foregroundStyle(.green)
            VStack(alignment: .leading) {
                Text("Paired with \(device.name)").font(.headline)
                Text("It reconnects automatically from now on. Start drawing on the tablet.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done", action: done).keyboardShortcut(.defaultAction)
        }
    }

    private var pairedList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Paired tablets").font(.headline)
            if model.pairedDevices.isEmpty {
                Text("None yet.").foregroundStyle(.secondary)
            }
            ForEach(model.pairedDevices) { d in
                HStack {
                    Image(systemName: "ipad.landscape")
                    VStack(alignment: .leading) {
                        Text(d.name)
                        Text(lastSeen(d)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Forget") { forget(d) }
                        .help("Removes this tablet's key. It has to pair again to connect over Wi-Fi.")
                }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Using a cable instead? Choose USB on the tablet; it needs USB debugging and `adb reverse tcp:8765 tcp:8765`.")
            Text("Mac certificate \(model.hostFingerprint) — the tablet shows the same value under Diagnostics.")
        }
        .font(.caption).foregroundStyle(.secondary)
    }

    private func step(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)").font(.callout.monospacedDigit().weight(.semibold))
                .frame(width: 20, height: 20).background(Circle().fill(Color.secondary.opacity(0.2)))
            Text(text)
        }
    }

    private func lastSeen(_ d: PairedDevice) -> String {
        if model.connection.deviceName == d.name && model.connection.transport == .wifi { return "Connected now" }
        guard let seen = d.lastSeen else { return "Never connected" }
        return "Last connected " + RelativeDateTimeFormatter().localizedString(for: seen, relativeTo: Date())
    }

    private func link(for ticket: PairingTicket) -> PairingLink? {
        guard let fp = Data(hex: model.hostFingerprintHex) else { return nil }
        return PairingLink(hostName: hostName, hostID: model.hostID, addresses: LocalAddresses.ipv4(), port: 8766,
                           code: ticket.code, fingerprint: fp, expiresAt: ticket.expiresAt)
    }
}

enum QRCode {
    static func image(for text: String, size: CGFloat) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scale = floor(size / output.extent.width)
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
