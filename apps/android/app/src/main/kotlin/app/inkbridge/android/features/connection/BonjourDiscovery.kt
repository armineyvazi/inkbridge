package app.inkbridge.android.features.connection

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import app.inkbridge.core.transport.BONJOUR_SERVICE_TYPE
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** A Mac advertising InkBridge on the LAN. [hostId] comes from the TXT record. */
data class DiscoveredMac(val name: String, val address: String, val port: Int, val hostId: String?)

/**
 * Finds InkBridge Macs via Bonjour (mDNS / DNS-SD, `_inkbridge._tcp`).
 *
 * Discovery only proposes addresses; trust comes from the pinned TLS
 * certificate and the token or code. The TXT `id` lets a paired tablet find
 * its Mac again after the Mac's IP address changes.
 *
 * NsdManager resolves one service at a time below API 34, so resolves are
 * queued. A multicast lock is held while searching: some Wi-Fi drivers drop
 * multicast to save power, which makes mDNS answers vanish.
 */
class BonjourDiscovery(ctx: Context) {
    private val nsd = ctx.getSystemService(Context.NSD_SERVICE) as NsdManager
    private val wifi = ctx.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
    private var lock: WifiManager.MulticastLock? = null
    private var listener: NsdManager.DiscoveryListener? = null
    private val queue = ArrayDeque<NsdServiceInfo>()
    private var resolving = false
    private val found = LinkedHashMap<String, DiscoveredMac>()

    private val _macs = MutableStateFlow<List<DiscoveredMac>>(emptyList())
    val macs: StateFlow<List<DiscoveredMac>> = _macs.asStateFlow()

    private val _error = MutableStateFlow<String?>(null)
    val error: StateFlow<String?> = _error.asStateFlow()

    val running get() = listener != null

    @Synchronized
    fun start() {
        if (listener != null) return
        lock = wifi.createMulticastLock("inkbridge-mdns").apply { setReferenceCounted(false); acquire() }
        _error.value = null
        val l = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) {}
            override fun onDiscoveryStopped(serviceType: String) {}
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                _error.value = "Searching failed (code $errorCode)"
                synchronized(this@BonjourDiscovery) { listener = null }
            }
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {}
            override fun onServiceFound(info: NsdServiceInfo) = enqueue(info)
            override fun onServiceLost(info: NsdServiceInfo) = synchronized(this@BonjourDiscovery) {
                found.remove(info.serviceName)
                publish()
            }
        }
        listener = l
        try {
            nsd.discoverServices(BONJOUR_SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, l)
        } catch (e: RuntimeException) {
            // NSD unavailable (system service missing, or the platform refused): manual address still works.
            listener = null
            _error.value = "Searching is unavailable on this device"
        }
    }

    @Synchronized
    fun stop() {
        listener?.let { runCatching { nsd.stopServiceDiscovery(it) } }
        listener = null
        queue.clear()
        resolving = false
        found.clear()
        publish()
        lock?.let { if (it.isHeld) it.release() }
        lock = null
    }

    /** Forget what was seen and search again, e.g. after the network changed. */
    fun restart() {
        stop()
        start()
    }

    @Synchronized
    private fun enqueue(info: NsdServiceInfo) {
        queue.addLast(info)
        next()
    }

    @Synchronized
    @Suppress("DEPRECATION") // resolveService is deprecated on API 34 but is the only API below it.
    private fun next() {
        if (resolving || listener == null) return
        val info = queue.removeFirstOrNull() ?: return
        resolving = true
        nsd.resolveService(info, object : NsdManager.ResolveListener {
            override fun onResolveFailed(info: NsdServiceInfo, errorCode: Int) = done(null)
            override fun onServiceResolved(info: NsdServiceInfo) {
                val address = info.host?.hostAddress
                val id = info.attributes["id"]?.decodeToString()
                done(address?.let { DiscoveredMac(info.serviceName, it, info.port, id) })
            }
        })
    }

    private fun done(mac: DiscoveredMac?) = synchronized(this) {
        resolving = false
        if (mac != null && listener != null) {
            found[mac.name] = mac
            publish()
        }
        next()
    }

    private fun publish() {
        _macs.value = found.values.sortedBy { it.name.lowercase() }
    }
}
