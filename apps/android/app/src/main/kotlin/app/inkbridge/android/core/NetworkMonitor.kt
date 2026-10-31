package app.inkbridge.android.core

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiManager
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** The tablet's current Wi-Fi, as far as the UI needs it. */
data class WifiInfo(val connected: Boolean, val address: String?)

/**
 * Watches Wi-Fi so the connection can react in under a second instead of
 * waiting for the keep-alive to time out:
 *
 * - Wi-Fi came up / changed network → [onAvailable]: search again, retry now.
 * - Wi-Fi went away → [onLost]: drop the dead socket now.
 *
 * No location permission is requested, so the network name (SSID) is never
 * read; the IP address is enough to show "on Wi-Fi" and for diagnostics.
 */
class NetworkMonitor(ctx: Context, private val onAvailable: () -> Unit, private val onLost: () -> Unit) {
    private val cm = ctx.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    private val wifi = ctx.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
    private val _state = MutableStateFlow(WifiInfo(false, null))
    val state: StateFlow<WifiInfo> = _state.asStateFlow()
    private var current: Network? = null

    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            current = network
            refresh()
            onAvailable()
        }

        override fun onLost(network: Network) {
            if (network != current) return
            current = null
            _state.value = WifiInfo(false, null)
            onLost()
        }

        override fun onLinkPropertiesChanged(network: Network, lp: android.net.LinkProperties) = refresh()
    }

    fun start() {
        val req = NetworkRequest.Builder().addTransportType(NetworkCapabilities.TRANSPORT_WIFI).build()
        cm.registerNetworkCallback(req, callback)
    }

    fun stop() {
        runCatching { cm.unregisterNetworkCallback(callback) }
    }

    private fun refresh() {
        val n = current ?: return
        val addr = cm.getLinkProperties(n)?.linkAddresses
            ?.map { it.address }?.firstOrNull { it is java.net.Inet4Address }?.hostAddress
        _state.value = WifiInfo(true, addr)
    }

    /** Whether the radio is on at all (to tell "Wi-Fi off" from "not connected"). */
    val wifiEnabled get() = wifi.isWifiEnabled
}
