import InkBridgeCore
import SwiftUI

/// Connection, display and capture preferences, plus first-run instructions.
struct SettingsView: View {
    @ObservedObject var model: AppModel
    var connectDevice: () -> Void
    var forget: (PairedDevice) -> Void
    var exportDiagnostics: () -> Void

    var body: some View {
        Form {
            Section("Wi-Fi") {
                Toggle("Allow Wi-Fi connections", isOn: $model.wifiEnabled)
                LabeledContent("Status") {
                    Text(model.connection.wifiListening ? "Ready · encrypted (TLS) · port 8766" : "Not listening")
                        .foregroundStyle(.secondary)
                }
                Button("Connect Device…", action: connectDevice)
                Text("Shows a one-time code for pairing a new tablet. Paired tablets reconnect by themselves.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Paired tablets") {
                if model.pairedDevices.isEmpty {
                    Text("None yet.").foregroundStyle(.secondary)
                }
                ForEach(model.pairedDevices) { d in
                    LabeledContent(d.name) {
                        Button("Forget") { forget(d) }
                    }
                }
            }

            Section("USB") {
                LabeledContent("USB (adb reverse)") {
                    Text(model.connection.usbListening ? "listening on 127.0.0.1:8765" : "not listening")
                        .foregroundStyle(.secondary)
                }
                Text("Optional. Needs USB debugging on the tablet and `adb reverse tcp:8765 tcp:8765` once per cable connection.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("When both are connected", selection: $model.transportPreference) {
                    Text("Prefer USB").tag(PeerArbiter.Preference.preferUSB)
                    Text("USB only").tag(PeerArbiter.Preference.usbOnly)
                    Text("Wi-Fi only").tag(PeerArbiter.Preference.wifiOnly)
                }
            }

            Section("Display") {
                Toggle("Follow the screen I click", isOn: $model.followMouse)
                Text("With several monitors, ink, Studio Canvas and the toolbar move to the display you last clicked on.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Otherwise draw on", selection: $model.displayID) {
                    ForEach(DisplayManager.displays) { d in
                        Text("\(d.name) (\(Int(d.size.width))×\(Int(d.size.height)))").tag(Optional(d.id))
                    }
                }
                .disabled(model.followMouse)
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
