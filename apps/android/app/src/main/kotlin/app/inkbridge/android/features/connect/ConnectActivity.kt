package app.inkbridge.android.features.connect

import android.os.Bundle
import android.text.Editable
import android.text.InputFilter
import android.text.InputType
import android.text.TextWatcher
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.inputmethod.EditorInfo
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import app.inkbridge.android.R
import app.inkbridge.android.design.Ink
import app.inkbridge.android.design.InkActivity
import app.inkbridge.android.design.SpacedColumn
import app.inkbridge.android.features.canvas.CanvasActivity
import app.inkbridge.android.features.connection.DiscoveredMac
import app.inkbridge.android.features.connection.PairingRequest
import app.inkbridge.core.connection.ConnectionMode
import app.inkbridge.core.connection.PairingLink
import app.inkbridge.core.connection.Stage
import app.inkbridge.core.connection.StatusView
import app.inkbridge.core.transport.DEFAULT_WIFI_PORT

/**
 * Connect to Mac: pick a Mac found on the network, type the code from its
 * Connect Device window, done. Also the manual-address fallback, USB, and
 * the `inkbridge://pair` link from the Mac's QR code.
 *
 * One screen with three states (list → code → result) swapped in place, so
 * the flow never opens a dialog over a dialog on e-ink.
 */
class ConnectActivity : InkActivity() {
    private lateinit var body: FrameLayout
    private var target: PairingRequest? = null
    private var codeField: EditText? = null
    private var message: TextView? = null
    private var pairButton: View? = null
    private var listColumn: SpacedColumn? = null
    private var searching: TextView? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        body = FrameLayout(this)
        setContentView(LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Ink.PAPER)
            addView(Ink.topBar(this@ConnectActivity, "Connect to Mac", onBack = ::onBack))
            addView(body, LinearLayout.LayoutParams(-1, 0, 1f))
        })
        val link = intent?.dataString?.let(PairingLink::parse)
        when {
            link != null -> showLink(link)
            intent?.dataString != null -> showList("That pairing link is not valid. Open Connect Device on the Mac for a new one.")
            else -> showList(null)
        }
        onBackPressedDispatcher.addCallback(this, object : androidx.activity.OnBackPressedCallback(true) {
            override fun handleOnBackPressed() = onBack()
        })
        observe(manager.discovery.macs) { renderMacs(it) }
        observe(manager.status) { renderStatus(it) }
    }

    override fun onStart() {
        super.onStart()
        if (manager.settings.mode == ConnectionMode.WIFI) manager.discovery.start()
    }

    private fun onBack() {
        if (target != null && manager.status.value.stage != Stage.CONNECTED) {
            manager.cancelPairing()
            target = null
            showList(null)
        } else {
            finish()
        }
    }


    // MARK: List

    private fun showList(error: String?) {
        codeField = null
        val c = Ink.column(this)
        c.add(Ink.title(this, "Pair with your Mac"))
        c.add(Ink.body(this, "On the Mac, click the InkBridge pen in the menu bar and choose Connect Device… (⌃⌥K). Then choose that Mac here.")
            .apply { setTextColor(Ink.GREY) }, Ink.dp(this, Ink.S))
        error?.let { c.add(problem(it), Ink.dp(this, Ink.M)) }
        // A pairing that just failed (forgotten, certificate changed) is not offered as a shortcut:
        // the user came here to pair again, and the same name appears in the list below.
        manager.paired.value?.takeIf { manager.status.value.stage != Stage.FAILED }?.let { p ->
            c.add(Ink.section(this, "Paired"))
            c.add(Ink.listRow(this, R.drawable.ic_check, p.name, "Paired · certificate ${p.shortFingerprint}") {
                manager.resume(); finish()
            }, 0)
        }
        c.add(Ink.section(this, "Macs on this network"))
        searching = Ink.caption(this, "Searching…")
        c.add(searching!!, 0)
        listColumn = Ink.column(this)
        c.add(listColumn!!, 0)
        c.add(Ink.button(this, "Search again", Ink.ButtonStyle.GHOST, R.drawable.ic_refresh) { manager.discovery.restart() }, Ink.dp(this, Ink.S))
        if (!manager.network.state.value.connected && !manager.network.wifiEnabled) {
            c.add(problem("Wi-Fi is off. Turn it on in the BOOX settings, on the same network as the Mac."), Ink.dp(this, Ink.S))
        }
        c.add(Ink.section(this, "Other ways to connect"))
        c.add(Ink.listRow(this, R.drawable.ic_laptop, "Enter the Mac's address", "If the Mac doesn't appear above") { showManual() }, 0)
        c.add(Ink.listRow(this, R.drawable.ic_usb, "Use a USB cable instead",
            if (manager.settings.mode == ConnectionMode.USB) "Selected" else "Needs USB debugging and adb on the Mac") { useUsb() }, 0)
        swap(c)
        renderMacs(manager.discovery.macs.value)
    }

    private fun renderMacs(macs: List<DiscoveredMac>) {
        val col = listColumn ?: return
        searching?.let { Ink.setText(it, if (macs.isEmpty()) "Searching… Make sure InkBridge is open on the Mac." else "") }
        searching?.visibility = if (macs.isEmpty()) View.VISIBLE else View.GONE
        val key = macs.joinToString { it.name + it.address }
        if (col.tag == key) return
        col.tag = key
        col.removeAllViews()
        for (m in macs) {
            val isPaired = m.hostId != null && m.hostId == manager.paired.value?.hostId && manager.status.value.stage != Stage.FAILED
            col.add(Ink.listRow(this, R.drawable.ic_laptop, m.name, if (isPaired) "Paired · ${m.address}" else m.address) {
                if (isPaired) { manager.resume(); finish() } else showCode(PairingRequest(m.name, m.address, m.port, ""))
            }, 0)
        }
    }

    // MARK: Code

    private fun showCode(req: PairingRequest, prefilled: String = "") {
        target = req
        val c = Ink.column(this)
        c.add(Ink.title(this, "Enter the code"))
        c.add(Ink.body(this, "Type the 8-character code shown in Connect Device on “${req.name}”.").apply { setTextColor(Ink.GREY) }, Ink.dp(this, Ink.S))
        val field = codeEdit(prefilled)
        codeField = field
        c.add(field, Ink.dp(this, Ink.L))
        message = Ink.body(this, "").apply { visibility = View.GONE }
        c.add(message!!, Ink.dp(this, Ink.M))
        pairButton = Ink.button(this, "Pair", Ink.ButtonStyle.PRIMARY, R.drawable.ic_check) { submit() }
        c.add(pairButton!!, Ink.dp(this, Ink.L))
        c.add(Ink.caption(this, "The code works once and expires after five minutes. It is never sent over the network: the tablet and the Mac each prove they know it, over an encrypted connection."),
            Ink.dp(this, Ink.L))
        swap(c)
        field.requestFocus()
    }

    private fun codeEdit(prefilled: String) = EditText(this).apply {
        setText(format(prefilled))
        textSize = Ink.DISPLAY
        typeface = android.graphics.Typeface.MONOSPACE
        gravity = Gravity.CENTER
        letterSpacing = 0.12f
        inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_CAP_CHARACTERS or InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
        filters = arrayOf(InputFilter.AllCaps(), InputFilter.LengthFilter(9))
        hint = "XXXX-XXXX"
        imeOptions = EditorInfo.IME_ACTION_DONE
        background = Ink.box(context, Ink.PAPER, Ink.INK)
        setPadding(Ink.dp(context, Ink.M), Ink.dp(context, Ink.M), Ink.dp(context, Ink.M), Ink.dp(context, Ink.M))
        setOnEditorActionListener { _, _, _ -> submit(); true }
        addTextChangedListener(object : TextWatcher {
            private var editing = false
            override fun beforeTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
            override fun onTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
            override fun afterTextChanged(s: Editable) {
                if (editing) return
                editing = true
                val f = format(s.toString())
                if (f != s.toString()) { s.replace(0, s.length, f) }
                editing = false
            }
        })
    }

    /** "k7qwm3xp" → "K7QW-M3XP", tolerant of spaces and a typed dash. */
    private fun format(raw: String): String {
        val clean = raw.uppercase().filter { it.isLetterOrDigit() }.take(8)
        return if (clean.length > 4) clean.substring(0, 4) + "-" + clean.substring(4) else clean
    }

    private fun submit() {
        val req = target ?: return
        val code = codeField?.text?.toString().orEmpty().filter { it.isLetterOrDigit() }
        if (code.length != 8) return say("The code has 8 characters.", problem = true)
        say("Pairing…", problem = false)
        manager.pair(req.copy(code = code))
    }

    private fun say(text: String, problem: Boolean) {
        val m = message ?: return
        m.visibility = View.VISIBLE
        Ink.setText(m, text)
        m.setTypeface(null, if (problem) android.graphics.Typeface.BOLD else android.graphics.Typeface.NORMAL)
    }

    // MARK: Status while pairing

    private fun renderStatus(s: StatusView) {
        if (target == null || codeField == null) return
        when (s.stage) {
            Stage.PAIRING, Stage.AUTHENTICATING, Stage.CONNECTING -> say(s.title, problem = false)
            Stage.CONNECTED -> showDone(s)
            Stage.FAILED -> say("${s.title}. ${s.detail}", problem = true)
            else -> Unit
        }
    }

    private fun showDone(s: StatusView) {
        codeField = null
        target = null
        val c = Ink.column(this)
        c.add(Ink.row(this).apply {
            addView(Ink.statusMark(this@ConnectActivity, app.inkbridge.core.connection.Tone.GOOD, 26))
            addView(Ink.title(this@ConnectActivity, s.title).apply { setPadding(Ink.dp(context, 14), 0, 0, 0) })
        })
        c.add(Ink.body(this, "This tablet now reconnects to the Mac by itself whenever both are on the same Wi-Fi. No cable needed.")
            .apply { setTextColor(Ink.GREY) }, Ink.dp(this, Ink.M))
        c.add(Ink.button(this, "Start drawing", Ink.ButtonStyle.PRIMARY, R.drawable.ic_pen) { open<CanvasActivity>(); finish() }, Ink.dp(this, Ink.L))
        c.add(Ink.button(this, "Done", Ink.ButtonStyle.SECONDARY) { finish() }, Ink.dp(this, Ink.S))
        swap(c)
        cleanRefresh()
    }

    // MARK: Manual, USB, QR link

    private fun showManual() {
        val c = Ink.column(this)
        c.add(Ink.title(this, "Enter the Mac's address"))
        c.add(Ink.body(this, "The address is under Settings → Wi-Fi on the Mac (for example 192.168.1.20). Use this when the network blocks discovery.")
            .apply { setTextColor(Ink.GREY) }, Ink.dp(this, Ink.S))
        val host = field("IP address", manager.settings.manualHost, InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_URI)
        val port = field("Port", manager.settings.manualPort.toString(), InputType.TYPE_CLASS_NUMBER)
        c.add(host, Ink.dp(this, Ink.L)).add(port, Ink.dp(this, Ink.S))
        c.add(Ink.button(this, "Continue", Ink.ButtonStyle.PRIMARY) {
            val h = host.text.toString().trim()
            if (h.isEmpty()) return@button
            val p = port.text.toString().toIntOrNull() ?: DEFAULT_WIFI_PORT
            manager.update(manager.settings.copy(manualHost = h, manualPort = p))
            showCode(PairingRequest(h, h, p, ""))
        }, Ink.dp(this, Ink.L))
        swap(c)
    }

    private fun field(hintText: String, value: String, type: Int) = EditText(this).apply {
        hint = hintText
        setText(value)
        inputType = type
        textSize = Ink.BODY + 2
        background = Ink.box(context, Ink.PAPER, Ink.INK)
        setPadding(Ink.dp(context, Ink.M), Ink.dp(context, 14), Ink.dp(context, Ink.M), Ink.dp(context, 14))
    }

    private fun useUsb() {
        val c = Ink.column(this)
        c.add(Ink.title(this, "Connect with a USB cable"))
        c.add(Ink.body(this, "USB is optional; Wi-Fi does everything without a cable. USB can be steadier on busy networks.\n\n" +
            "1. On the BOOX: Settings → About → tap the build number 7 times, then turn on USB debugging.\n" +
            "2. Connect the cable and allow the Mac when asked.\n" +
            "3. On the Mac, run: adb reverse tcp:8765 tcp:8765"), Ink.dp(this, Ink.S))
        c.add(Ink.button(this, "Use USB", Ink.ButtonStyle.PRIMARY, R.drawable.ic_usb) {
            manager.update(manager.settings.copy(mode = ConnectionMode.USB))
            manager.resume()
            finish()
        }, Ink.dp(this, Ink.L))
        if (manager.settings.mode == ConnectionMode.USB) {
            c.add(Ink.button(this, "Switch back to Wi-Fi", Ink.ButtonStyle.SECONDARY, R.drawable.ic_wifi) {
                manager.update(manager.settings.copy(mode = ConnectionMode.WIFI))
                showList(null)
            }, Ink.dp(this, Ink.S))
        }
        swap(c)
    }

    /** Opened from the QR link: everything is known, including the certificate to pin. */
    private fun showLink(link: PairingLink) {
        if (link.expired()) return showList("That code has expired. Open Connect Device on the Mac for a new one.")
        val address = link.addresses.firstOrNull() ?: return showList("The link has no address. Choose the Mac from the list instead.")
        showCode(PairingRequest(link.hostName, address, link.port, "", link.fingerprint), prefilled = link.code)
        submit()
    }

    private fun problem(text: String) = Ink.row(this).apply {
        addView(Ink.statusMark(this@ConnectActivity, app.inkbridge.core.connection.Tone.PROBLEM, 18))
        addView(Ink.body(this@ConnectActivity, text).apply { setPadding(Ink.dp(context, 12), 0, 0, 0) },
            LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
    }

    private fun swap(content: View) {
        body.removeAllViews()
        body.addView(Ink.page(this, content))
    }
}
