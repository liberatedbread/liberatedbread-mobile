package ca.pigscanfly.liberatedbread

import android.content.Context
import android.net.wifi.WifiManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Hosts the Flutter engine and lends it an Android multicast lock.
 *
 * Android's Wi-Fi driver drops multicast and broadcast packets not addressed to
 * the device unless something holds a `WifiManager.MulticastLock`. It is a
 * power optimisation and it is on by default, so a pure-Dart mDNS or SSDP
 * client can send its queries perfectly well and never see a single reply.
 * Nothing errors: the scan just comes back empty, on exactly the devices the
 * Wi-Fi tab exists to find.
 *
 * `CHANGE_WIFI_MULTICAST_STATE` in the manifest only grants permission to take
 * the lock; it does not take it. This is the part that takes it.
 */
class MainActivity : FlutterActivity() {
    private var multicastLock: WifiManager.MulticastLock? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "acquire" -> {
                        acquireMulticastLock()
                        result.success(null)
                    }
                    "release" -> {
                        releaseMulticastLock()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * Idempotent: a second scan starting while one is running must not stack a
     * second lock that the matching single release would then leave held.
     */
    private fun acquireMulticastLock() {
        if (multicastLock?.isHeld == true) return
        val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        multicastLock = wifi.createMulticastLock(LOCK_TAG).apply {
            // Not reference counted, so acquire and release pair up by state
            // rather than by count. A dropped release — a crash mid-scan, an
            // activity killed while scanning — then costs one held lock rather
            // than leaving a counter that can never reach zero.
            setReferenceCounted(false)
            acquire()
        }
    }

    private fun releaseMulticastLock() {
        multicastLock?.takeIf { it.isHeld }?.release()
        multicastLock = null
    }

    /**
     * The lock costs battery — it stops the Wi-Fi chip filtering multicast for
     * the whole device — so it must not outlive the activity even if a scan is
     * torn down without its release reaching us.
     */
    override fun onDestroy() {
        releaseMulticastLock()
        super.onDestroy()
    }

    companion object {
        private const val CHANNEL = "ca.pigscanfly.liberatedbread/multicast"
        private const val LOCK_TAG = "liberatedbread-network-scan"
    }
}
