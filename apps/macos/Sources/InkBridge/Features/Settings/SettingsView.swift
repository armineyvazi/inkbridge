import InkBridgeCore
import SwiftUI

/// Connection, display and capture preferences, plus first-run instructions.
struct SettingsView: View {
    @ObservedObject var model: AppModel
    var regenerateCode: () -> Void
    var exportDiagnostics: () -> Void

    var body: some View {
        Form {
            Section("Connect your BOOX") {
                LabeledContent("USB (adb reverse)") {
                    Text(model.connection.usbListening ? "listening on 127.0.0.1:8765" : "not listening")
                        .foregroundStyle(.secondary)
                }
                Text("Run `adb reverse tcp:8765 tcp:8765` once per cable connection, then choose USB in the InkBridge app on the tablet.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Allow Wi-Fi connections", isOn: $model.wifiEnabled)
                if model.wifiEnabled {
                    LabeledContent("Pairing code") {
                        HStack {
                            Text(model.pairingCode).font(.system(.title3, design: .monospaced)).textSelection(.enabled)
                            Button("New code", action: regenerateCode)
                        }
                    }
                    Text("Enter this code on the tablet. Changing it disconnects Wi-Fi devices paired with the old one.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Picker("When both are connected", selection: $model.transportPreference) {
                    Text("Prefer USB").tag(PeerArbiter.Preference.preferUSB)
                    Text("USB only").tag(PeerArbiter.Preference.usbOnly)
                    Text("Wi-Fi only").tag(PeerArbiter.Preference.wifiOnly)
                }
            }

            Section("Display") {
                Picker("Draw on", selection: $model.displayID) {
                    ForEach(DisplayManager.displays) { d in
                        Text("\(d.name) (\(Int(d.size.width))×\(Int(d.size.height)))").tag(Optional(d.id))
                    }
                }
                Picker("Tablet mapping", selection: $model.fit) {
                    Text("Keep tablet proportions").tag(CoordinateMapper.Fit.aspectFit)
                    Text("Stretch to fill display").tag(CoordinateMapper.Fit.stretch)
                }
            }

            Section("Saving") {
                Toggle("Include a screenshot when saving", isOn: $model.includeScreenshot)
                Text("Needs Screen Recording permission. Ink is always saved as vector strokes, PNG and PDF without it.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Diagnostics") {
                LabeledContent("Round trip") { Text(model.rttMs.map { String(format: "%.1f ms", $0) } ?? "–") }
                LabeledContent("Pen to Mac (p50)") { Text(model.inputLatencyMs.map { String(format: "%.1f ms", $0) } ?? "–") }
                LabeledContent("Receive to draw (p50)") { Text(model.renderLatencyMs.map { String(format: "%.2f ms", $0) } ?? "–") }
                Button("Export diagnostic report…", action: exportDiagnostics)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .padding(.vertical, 8)
    }
}
