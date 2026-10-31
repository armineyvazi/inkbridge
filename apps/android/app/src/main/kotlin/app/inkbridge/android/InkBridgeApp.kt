package app.inkbridge.android

import android.app.Activity
import android.app.Application
import android.content.Context
import android.os.Bundle
import app.inkbridge.android.features.connection.ConnectionManager

/**
 * Holds the app-wide [ConnectionManager] and tells it when InkBridge is on
 * screen, so the connection and the canvas mirror survive moving between
 * screens.
 */
class InkBridgeApp : Application() {
    lateinit var connection: ConnectionManager
        private set

    override fun onCreate() {
        super.onCreate()
        connection = ConnectionManager(this)
        registerActivityLifecycleCallbacks(object : ActivityLifecycleCallbacks {
            override fun onActivityStarted(a: Activity) = connection.foreground(true)
            override fun onActivityStopped(a: Activity) = connection.foreground(false)
            override fun onActivityCreated(a: Activity, b: Bundle?) {}
            override fun onActivityResumed(a: Activity) {}
            override fun onActivityPaused(a: Activity) {}
            override fun onActivitySaveInstanceState(a: Activity, b: Bundle) {}
            override fun onActivityDestroyed(a: Activity) {}
        })
    }
}

val Context.connection: ConnectionManager get() = (applicationContext as InkBridgeApp).connection
