package ca.pigscanfly.liberatedbread

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Bundle
import android.provider.OpenableColumns
import android.provider.Settings
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

    /** A file shared in before Dart asked for it (a cold start), held once. */
    private var pendingShare: Map<String, Any?>? = null
    private var shareChannel: MethodChannel? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Not on a re-creation (rotation, process restore): the intent is the
        // one already handled, and printing it twice would be a surprise.
        if (savedInstanceState == null) pendingShare = readShare(intent)
    }

    /**
     * A share while the app is already running (launchMode singleTop reuses
     * this activity): hand it straight to Dart, or hold it if the engine has
     * not asked yet.
     */
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        val share = readShare(intent) ?: return
        val channel = shareChannel
        if (channel == null) {
            pendingShare = share
        } else {
            channel.invokeMethod("shared", share)
        }
    }

    /**
     * The shared or opened file's bytes, type and name, or null for an intent
     * that is not a share. Copied now, while the URI permission the sharing
     * app granted is still live; it lapses when this activity goes.
     */
    private fun readShare(intent: Intent?): Map<String, Any?>? {
        intent ?: return null
        val uri: Uri = when (intent.action) {
            Intent.ACTION_SEND -> if (Build.VERSION.SDK_INT >= 33) {
                intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
            } else {
                @Suppress("DEPRECATION")
                intent.getParcelableExtra(Intent.EXTRA_STREAM)
            }
            Intent.ACTION_VIEW -> intent.data
            else -> null
        } ?: return null
        return try {
            val bytes = contentResolver.openInputStream(uri)?.use { input ->
                // A label or a page is never this big; a 4K video someone
                // shared by mistake would be, and should not be read into RAM.
                val limit = MAX_SHARE_BYTES + 1
                val buffer = ByteArray(8192)
                val out = java.io.ByteArrayOutputStream()
                var total = 0
                while (true) {
                    val n = input.read(buffer)
                    if (n < 0) break
                    total += n
                    if (total > limit) return null
                    out.write(buffer, 0, n)
                }
                out.toByteArray()
            } ?: return null
            mapOf(
                "bytes" to bytes,
                "mime" to (intent.type ?: contentResolver.getType(uri)),
                "name" to displayName(uri),
            )
        } catch (e: Exception) {
            null
        }
    }

    private fun displayName(uri: Uri): String? = try {
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
            ?.use { c -> if (c.moveToFirst()) c.getString(0) else null }
    } catch (e: Exception) {
        null
    }

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
        shareChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SHARE_CHANNEL)
            .apply {
                setMethodCallHandler { call, result ->
                    when (call.method) {
                        "initialShare" -> {
                            result.success(pendingShare)
                            pendingShare = null
                        }
                        else -> result.notImplemented()
                    }
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PRINT_SETTINGS_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "open" -> result.success(openPrintSettings())
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, WIFI_SCAN_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "scanResults" -> result.success(wifiScanResults())
                    "openWifiSettings" -> result.success(openWifiSettings())
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * The SSIDs in the OS's most recent Wi-Fi scan cache, for the adoption
     * hint. Reads the cache with `getScanResults()` rather than forcing a scan:
     * `startScan()` is throttled to a handful of calls per two minutes on
     * Android 9+ and returns cached results anyway, so forcing it would spend
     * battery to animate an icon.
     *
     * Returns an empty list rather than throwing on the failure that actually
     * happens in the field — a `SecurityException` when the location permission
     * has not been granted, since `getScanResults()` is gated behind it. The
     * Dart side treats "cannot see" and "nothing there" identically.
     */
    private fun wifiScanResults(): List<String> {
        return try {
            val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            // SSID is quoted for a UTF-8 network and bare for a hex one; strip
            // the surrounding quotes so a prefix match sees "Wemo.1A2", not
            // "\"Wemo.1A2\"". Blank/unknown SSIDs are dropped Dart-side.
            wifi.scanResults.orEmpty().map { it.SSID.orEmpty().trim('"') }
        } catch (e: SecurityException) {
            emptyList()
        } catch (e: Exception) {
            emptyList()
        }
    }

    /**
     * The system Wi-Fi list, for the adopt flow's "join the setup network"
     * step. False when no activity handles the intent, which the Dart side
     * treats as "tell the user how to get there by hand".
     */
    private fun openWifiSettings(): Boolean {
        return try {
            startActivity(Intent(Settings.ACTION_WIFI_SETTINGS))
            true
        } catch (e: Exception) {
            false
        }
    }

    /**
     * The system print-service settings, for "add to system printers": the
     * app cannot add a printer itself, but it can open the page where the
     * user turns on the service that finds them. False when no activity
     * handles the intent, and the Dart side then says where to look.
     */
    private fun openPrintSettings(): Boolean {
        return try {
            startActivity(Intent(Settings.ACTION_PRINT_SETTINGS))
            true
        } catch (e: Exception) {
            false
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
        private const val WIFI_SCAN_CHANNEL = "ca.pigscanfly.liberatedbread/wifi_scan"
        private const val LOCK_TAG = "liberatedbread-network-scan"
        private const val SHARE_CHANNEL = "ca.pigscanfly.liberatedbread/share_in"
        private const val PRINT_SETTINGS_CHANNEL = "ca.pigscanfly.liberatedbread/print_settings"
        private const val MAX_SHARE_BYTES = 32 * 1024 * 1024
    }
}
