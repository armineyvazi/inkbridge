package app.inkbridge.android.features.connection

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Handler
import android.os.Looper
import app.inkbridge.core.transport.BONJOUR_SERVICE_TYPE

/**
 * Finds InkBridge hosts advertised over Bonjour (mDNS/DNS-SD) on the LAN.
 * Discovery only proposes an address; the pairing code is still what
 * authorises the connection.
 */
class BonjourDiscovery(context: Context) {
    data class Host(val name: String, val address: String, val port: Int)

    private val nsd = context.getSystemService(Context.NSD_SERVICE) as NsdManager
    private val main = Handler(Looper.getMainLooper())
    private var listener: NsdManager.DiscoveryListener? = null

    /** Calls [onFound] on the main thread for each resolved host until [stop]. */
    fun start(onFound: (Host) -> Unit, onError: (String) -> Unit) {
        stop()
        val l = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) {}
            override fun onDiscoveryStopped(serviceType: String) {}
            override fun onServiceLost(info: NsdServiceInfo) {}
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) = main.post { onError("discovery failed ($errorCode)") }.let {}
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {}
            override fun onServiceFound(info: NsdServiceInfo) = resolve(info, onFound)
        }
        listener = l
        nsd.discoverServices(BONJOUR_SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, l)
    }

    @Suppress("DEPRECATION") // resolveService is deprecated on API 34 but is the only API below it.
    private fun resolve(info: NsdServiceInfo, onFound: (Host) -> Unit) {
        nsd.resolveService(info, object : NsdManager.ResolveListener {
            override fun onResolveFailed(info: NsdServiceInfo, errorCode: Int) {}
            override fun onServiceResolved(info: NsdServiceInfo) {
                val address = info.host?.hostAddress ?: return
                main.post { onFound(Host(info.serviceName, address, info.port)) }
            }
        })
    }

    fun stop() {
        listener?.let { runCatching { nsd.stopServiceDiscovery(it) } }
        listener = null
    }
}
