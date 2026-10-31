package app.inkbridge.android.features.settings

import android.app.AlertDialog
import android.content.Context
import android.text.InputType
import android.view.View
import android.widget.CheckBox
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.RadioButton
import android.widget.RadioGroup
import android.widget.TextView
import app.inkbridge.android.features.connection.BonjourDiscovery
import app.inkbridge.android.features.connection.ConnectionSettings
import app.inkbridge.core.transport.TransportKind

/** Connection settings, built in code to keep the UI dependency-free. */
object SettingsDialog {
    fun show(context: Context, current: ConnectionSettings, onSave: (ConnectionSettings) -> Unit) {
        val pad = (16 * context.resources.displayMetrics.density).toInt()
        val root = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(pad, pad, pad, 0)
        }
        val usb = RadioButton(context).apply { text = "USB cable (adb reverse)"; id = View.generateViewId() }
        val wifi = RadioButton(context).apply { text = "Wi-Fi"; id = View.generateViewId() }
        val group = RadioGroup(context).apply {
            addView(usb)
            addView(wifi)
            check(if (current.mode == TransportKind.USB) usb.id else wifi.id)
        }
        val host = EditText(context).apply {
            hint = "Mac IP address"
            setText(current.wifiHost)
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_URI
        }
        val port = EditText(context).apply {
            hint = "Port"
            setText(current.wifiPort.toString())
            inputType = InputType.TYPE_CLASS_NUMBER
        }
        val code = EditText(context).apply {
            hint = "Pairing code shown on the Mac"
            setText(current.pairingCode)
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_CAP_CHARACTERS
        }
        val discoveryStatus = TextView(context).apply { text = "Searching for Macs on this network…" }
        val ink = CheckBox(context).apply { text = "Also show ink on the tablet (slower: adds latency on e-ink)"; isChecked = current.showLocalInk }

        root.addView(group)
        root.addView(TextView(context).apply { text = "\nWi-Fi" })
        root.addView(discoveryStatus)
        root.addView(host)
        root.addView(port)
        root.addView(code)
        root.addView(ink)
        root.addView(TextView(context).apply {
            text = "\nUSB needs USB debugging on the tablet and, on the Mac:\nadb reverse tcp:${current.usbPort} tcp:${current.usbPort}"
        })

        val discovery = BonjourDiscovery(context)
        discovery.start(
            onFound = { h ->
                discoveryStatus.text = "Found \"${h.name}\" at ${h.address}"
                if (host.text.isBlank()) {
                    host.setText(h.address)
                    port.setText(h.port.toString())
                }
            },
            onError = { discoveryStatus.text = it },
        )

        AlertDialog.Builder(context)
            .setTitle("Connection")
            .setView(root)
            .setPositiveButton("Save") { _, _ ->
                onSave(current.copy(
                    mode = if (group.checkedRadioButtonId == usb.id) TransportKind.USB else TransportKind.WIFI,
                    wifiHost = host.text.toString().trim(),
                    wifiPort = port.text.toString().toIntOrNull() ?: current.wifiPort,
                    pairingCode = code.text.toString().trim(),
                    showLocalInk = ink.isChecked,
                ))
            }
            .setNegativeButton("Cancel", null)
            .setOnDismissListener { discovery.stop() }
            .show()
    }
}
