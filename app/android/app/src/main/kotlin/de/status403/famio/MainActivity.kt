package de.status403.famio

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.location.LocationManager
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Hosts Flutter and the channels `famio/location` (location sharing),
 * `famio/notify` (Famio's own push) and `famio/sos` (emergency button).
 */
class MainActivity : FlutterActivity() {
    companion object {
        const val ACTION_SOS = "de.status403.famio.SOS"

        fun sosIntent(context: Context) =
            Intent(context, MainActivity::class.java).setAction(ACTION_SOS)
    }

    private var permissionResult: MethodChannel.Result? = null
    private var sos: SosChannel? = null

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        if (intent?.action == ACTION_SOS) SosChannel.launchPending = true
        addSosShortcut()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (intent.action == ACTION_SOS) {
            SosChannel.launchPending = true
            sos?.announceLaunch()
        }
    }

    /** "Notruf" when long-pressing the app icon (any build flavour). */
    private fun addSosShortcut() {
        if (Build.VERSION.SDK_INT < 25) return
        runCatching {
            val manager = getSystemService(android.content.pm.ShortcutManager::class.java)
            val shortcut = android.content.pm.ShortcutInfo.Builder(this, "sos")
                .setShortLabel("Notruf")
                .setLongLabel("Famio-Notruf auslösen")
                .setIcon(android.graphics.drawable.Icon.createWithResource(this, R.mipmap.ic_launcher))
                .setIntent(sosIntent(this))
                .build()
            manager.dynamicShortcuts = listOf(shortcut)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        sos = SosChannel(this, flutterEngine.dartExecutor.binaryMessenger)
        OcrChannel(applicationContext, flutterEngine.dartExecutor.binaryMessenger)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "famio/location")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "status" -> result.success(status())
                    "requestPermission" -> requestPermission(
                        call.argument<Boolean>("background") ?: false,
                        result,
                    )
                    "start" -> {
                        val prefs = prefs()
                        LocationSecrets.migrate(this)
                        val secrets = LocationSecrets.prefs(this)
                        val wasEnabled = prefs.getBoolean("enabled", false)
                        prefs.edit()
                            .putBoolean("enabled", true)
                            .putLong("alertsSince", System.currentTimeMillis())
                            .apply {
                                if (!wasEnabled) {
                                    for (key in locationDiagnosticKeys) remove(key)
                                }
                            }
                            .apply()
                        val url = call.argument<String>("url")
                        val token = call.argument<String>("token")
                        // Positions buffered for another server or account
                        // must not go to this one.
                        val sameSession = secrets.getString("url", null) == url &&
                            secrets.getString("token", null) == token
                        secrets.edit()
                            .putString("url", url)
                            .putString("token", token)
                            .putString("pin", call.argument<String>("pin"))
                            .putString("device", call.argument<String>("device"))
                            .apply { if (!sameSession) remove(LocationSecrets.PENDING) }
                            .apply()
                        LocationService.start(this)
                        result.success(null)
                    }
                    "stop" -> {
                        prefs().edit().clear().apply()
                        LocationSecrets.clear(this)
                        LocationService.stop(this)
                        result.success(null)
                    }
                    "token" -> {
                        LocationSecrets.migrate(this)
                        result.success(LocationSecrets.prefs(this).getString("token", null))
                    }
                    // iOS uses system geofences for its low-power background
                    // strategy. Android already has a foreground location
                    // service and deliberately keeps this as a no-op.
                    "setRegions" -> result.success(null)
                    "openBatterySettings" -> {
                        openBatterySettings()
                        result.success(null)
                    }
                    "openAppSettings" -> {
                        startActivity(
                            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                                .setData(Uri.parse("package:$packageName")),
                        )
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "famio/notify")
            .setMethodCallHandler { call, result ->
                val notify = getSharedPreferences(NotifyService.PREFS, Context.MODE_PRIVATE)
                when (call.method) {
                    "status" -> result.success(
                        mapOf(
                            "enabled" to notify.getBoolean("enabled", false),
                            "notifications" to (Build.VERSION.SDK_INT < 33 ||
                                granted(Manifest.permission.POST_NOTIFICATIONS)),
                            "batteryUnrestricted" to (getSystemService(Context.POWER_SERVICE) as PowerManager)
                                .isIgnoringBatteryOptimizations(packageName),
                        ),
                    )
                    "requestPermission" -> {
                        if (Build.VERSION.SDK_INT >= 33 &&
                            !granted(Manifest.permission.POST_NOTIFICATIONS)
                        ) {
                            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 4712)
                        }
                        result.success(null)
                    }
                    "start" -> {
                        val sameServer = notify.getString("url", null) == call.argument<String>("url")
                        notify.edit()
                            .putBoolean("enabled", true)
                            .putString("url", call.argument<String>("url"))
                            .putString("token", call.argument<String>("token"))
                            .putString("pin", call.argument<String>("pin"))
                            .putBoolean("details", call.argument<Boolean>("details") ?: true)
                            .apply {
                                // Another server: start at its newest notification.
                                if (!sameServer) remove("last")
                            }
                            .apply()
                        NotifyService.start(this)
                        result.success(null)
                    }
                    "stop" -> {
                        notify.edit().clear().apply()
                        NotifyService.stop(this)
                        result.success(null)
                    }
                    "token" -> result.success(notify.getString("token", null))
                    else -> result.notImplemented()
                }
            }
    }

    private fun prefs() = getSharedPreferences(LocationService.PREFS, Context.MODE_PRIVATE)

    private fun granted(permission: String) =
        checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    private fun status(): Map<String, Any?> {
        val prefs = prefs()
        val locations = getSystemService(Context.LOCATION_SERVICE) as LocationManager
        val power = getSystemService(Context.POWER_SERVICE) as PowerManager
        val background = Build.VERSION.SDK_INT < 29 ||
            granted(Manifest.permission.ACCESS_BACKGROUND_LOCATION)
        return mapOf(
            "enabled" to prefs.getBoolean("enabled", false),
            "permission" to when {
                !LocationService.hasPermission(this) -> "none"
                !background -> "foreground"
                else -> "always"
            },
            "precise" to granted(Manifest.permission.ACCESS_FINE_LOCATION),
            "locationOn" to (Build.VERSION.SDK_INT < 28 || locations.isLocationEnabled),
            "batteryUnrestricted" to power.isIgnoringBatteryOptimizations(packageName),
            "notifications" to (Build.VERSION.SDK_INT < 33 ||
                granted(Manifest.permission.POST_NOTIFICATIONS)),
            "lastFixAt" to prefs.timeOrNull("lastFixAt"),
            "lastSuccessfulUploadAt" to prefs.timeOrNull("lastSuccessfulUploadAt"),
            "lastServerResponseAt" to prefs.timeOrNull("lastServerResponseAt"),
            "lastServerStatus" to prefs.getString("lastServerStatus", null),
            "lastErrorAt" to prefs.timeOrNull("lastErrorAt"),
            "lastError" to prefs.getString("lastError", null),
        )
    }

    private fun android.content.SharedPreferences.timeOrNull(key: String): Long? =
        getLong(key, 0).takeIf { it > 0 }

    private val locationDiagnosticKeys = listOf(
        "lastFixAt",
        "lastSuccessfulUploadAt",
        "lastServerResponseAt",
        "lastServerStatus",
        "lastErrorAt",
        "lastError",
    )

    /**
     * Android asks in two steps: first "while using the app", then (on its
     * own settings page) "all the time", which sharing in the background
     * needs after a restart.
     */
    private fun requestPermission(background: Boolean, result: MethodChannel.Result) {
        if (permissionResult != null) {
            result.error("busy", "Anfrage läuft bereits", null)
            return
        }
        val wanted = if (background && Build.VERSION.SDK_INT >= 29) {
            arrayOf(Manifest.permission.ACCESS_BACKGROUND_LOCATION)
        } else {
            listOfNotNull(
                Manifest.permission.ACCESS_FINE_LOCATION,
                Manifest.permission.ACCESS_COARSE_LOCATION,
                if (Build.VERSION.SDK_INT >= 33) Manifest.permission.POST_NOTIFICATIONS else null,
            ).toTypedArray()
        }
        permissionResult = result
        requestPermissions(wanted, 4711)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (sos?.onPermissionResult(requestCode) == true) return
        if (requestCode != 4711) return
        permissionResult?.success(status())
        permissionResult = null
    }

    private fun openBatterySettings() {
        try {
            startActivity(
                Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
                    .setData(Uri.parse("package:$packageName")),
            )
        } catch (e: Exception) {
            startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
        }
    }
}
