package app.inkbridge.android.input

import android.os.Build
import android.view.InputDevice
import android.view.MotionEvent
import app.inkbridge.core.protocol.Capabilities

/**
 * Reports what the digitizer advertises, before any pen touches the screen.
 *
 * These are *advertised* ranges from the input driver; whether pressure is
 * meaningful is confirmed separately by watching live samples in the
 * diagnostics line. Phase 0 records both in docs/research.
 */
object StylusCapabilityProbe {
    private fun stylusDevices(): List<InputDevice> =
        InputDevice.getDeviceIds().toList().mapNotNull(InputDevice::getDevice)
            .filter { it.supportsSource(InputDevice.SOURCE_STYLUS) }

    fun capabilities(): Capabilities {
        val pens = stylusDevices()
        fun has(axis: Int) = pens.any { d -> d.getMotionRange(axis, InputDevice.SOURCE_STYLUS)?.let { it.max > it.min } == true }
        return Capabilities(
            pressure = has(MotionEvent.AXIS_PRESSURE),
            tilt = has(MotionEvent.AXIS_TILT),
            // Android exposes no "has eraser end" flag; TOOL_TYPE_ERASER is seen only when used.
            eraser = false,
            stylusButton = false,
        )
    }

    /** Human-readable dump of the build and every input device, for the Phase 0 report. */
    fun report(): String = buildString {
        appendLine("manufacturer=${Build.MANUFACTURER} brand=${Build.BRAND} model=${Build.MODEL} device=${Build.DEVICE} product=${Build.PRODUCT}")
        appendLine("android=${Build.VERSION.RELEASE} api=${Build.VERSION.SDK_INT} build=${Build.DISPLAY} fingerprint=${Build.FINGERPRINT}")
        for (id in InputDevice.getDeviceIds()) {
            val d = InputDevice.getDevice(id) ?: continue
            if (d.isVirtual) continue
            appendLine("input #$id \"${d.name}\" vendor=0x%04x product=0x%04x sources=0x%08x stylus=%s".format(
                d.vendorId, d.productId, d.sources, d.supportsSource(InputDevice.SOURCE_STYLUS)))
            for (r in d.motionRanges) {
                appendLine("    axis=${MotionEvent.axisToString(r.axis)} source=0x%08x min=%.2f max=%.2f res=%.4f fuzz=%.2f".format(
                    r.source, r.min, r.max, r.resolution, r.fuzz))
            }
        }
        append("advertised: ${capabilities()}")
    }
}
