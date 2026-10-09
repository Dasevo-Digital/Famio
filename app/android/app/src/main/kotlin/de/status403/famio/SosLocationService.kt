package de.status403.famio

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.BatteryManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SSLContext
import javax.net.ssl.TrustManager

/**
 * During an emergency (see the app's SOS button): sends the phone's position
 * every [INTERVAL_MS] to the Famio server for up to half an hour, also with
 * the screen off or the app closed. Started from the app while it is in
 * front, so "while in use" location permission is enough.
 *
 * It uses a token that can only send emergency positions and signs it out
 * when it stops.
 */
class SosLocationService : Service() {
    companion object {
        private const val CHANNEL = "famio_sos_live"
        private const val NOTIFICATION_ID = 4730
        private const val INTERVAL_MS = 20_000L
        private const val STOP = "de.status403.famio.STOP_SOS_LIVE"

        fun start(context: Context, url: String, token: String, pin: String?, alertId: String, untilMs: Long) {
            val intent = Intent(context, SosLocationService::class.java)
                .putExtra("url", url)
                .putExtra("token", token)
                .putExtra("pin", pin)
                .putExtra("alert", alertId)
                .putExtra("until", untilMs)
            if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent) else context.startService(intent)
        }

        fun stop(context: Context) {
            context.startService(Intent(context, SosLocationService::class.java).setAction(STOP))
        }
    }

    private val main = Handler(Looper.getMainLooper())
    private var url: String? = null
    private var token: String? = null
    private var pin: String? = null
    private var alertId: String? = null
    private var until = 0L
    private var lastSent = 0L
    private var listening = false
    private val stopLater = Runnable { finish() }

    private val listener = LocationListener { location -> onLocation(location) }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == STOP) {
            finish()
            return START_NOT_STICKY
        }
        val extras = intent ?: run {
            stopSelf()
            return START_NOT_STICKY
        }
        startInForeground()
        // A new alarm replaces a running one; its token is signed out.
        token?.let { old -> if (old != extras.getStringExtra("token")) logout(url, old, pin) }
        url = extras.getStringExtra("url")
        token = extras.getStringExtra("token")
        pin = extras.getStringExtra("pin")
        alertId = extras.getStringExtra("alert")
        until = extras.getLongExtra("until", System.currentTimeMillis() + 30 * 60_000L)
        main.removeCallbacks(stopLater)
        main.postDelayed(stopLater, (until - System.currentTimeMillis()).coerceAtLeast(0))
        listen()
        return START_REDELIVER_INTENT
    }

    private fun startInForeground() {
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26) {
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL,
                    getString(R.string.channel_sos_running),
                    NotificationManager.IMPORTANCE_LOW,
                ).apply {
                    description = getString(R.string.channel_sos_running_description)
                },
            )
        }
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val builder = if (Build.VERSION.SDK_INT >= 26) {
            Notification.Builder(this, CHANNEL)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        val notification = builder
            .setSmallIcon(R.drawable.ic_launcher_monochrome)
            .setContentTitle(getString(R.string.sos_active))
            .setContentText(getString(R.string.sos_active_text))
            .setContentIntent(open)
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    @Suppress("MissingPermission")
    private fun listen() {
        if (listening) return
        val granted = checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED ||
            checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED
        if (!granted) {
            finish()
            return
        }
        val manager = getSystemService(LocationManager::class.java)
        for (provider in listOf(LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER)) {
            if (runCatching { manager.isProviderEnabled(provider) }.getOrDefault(false)) {
                manager.requestLocationUpdates(provider, INTERVAL_MS / 2, 0f, listener, Looper.getMainLooper())
                listening = true
            }
        }
        if (!listening) finish()
    }

    private fun onLocation(location: Location) {
        val now = System.currentTimeMillis()
        if (now > until) {
            finish()
            return
        }
        // GPS and network both report: one position per interval is enough,
        // the more accurate one when they come together.
        if (now - lastSent < INTERVAL_MS) return
        lastSent = now
        val battery = getSystemService(BatteryManager::class.java)
            .getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
            .takeIf { it in 0..100 }
        val body = JSONObject()
            .put("latitude", location.latitude)
            .put("longitude", location.longitude)
            .apply {
                if (location.hasAccuracy()) put("accuracy", location.accuracy.toDouble())
                if (battery != null) put("battery", battery)
            }
        val target = url ?: return
        val auth = token ?: return
        val alert = alertId ?: return
        Thread {
            val status = post(URL(URL(target), "api/sos/${alert}/position"), auth, pin, body.toString())
            // Over (ended, half an hour passed) or signed out: stop.
            if (status == 404 || status == 409 || status == 401) main.post { finish() }
        }.start()
    }

    private fun finish() {
        main.removeCallbacks(stopLater)
        if (listening) {
            runCatching { getSystemService(LocationManager::class.java).removeUpdates(listener) }
            listening = false
        }
        token?.let { logout(url, it, pin) }
        token = null
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun logout(base: String?, auth: String, pin: String?) {
        val target = base ?: return
        Thread { post(URL(URL(target), "api/auth/logout"), auth, pin, "{}") }.start()
    }

    /** Returns the HTTP status, or 0 without a connection. */
    private fun post(url: URL, auth: String, pin: String?, body: String): Int {
        return try {
            val connection = url.openConnection() as HttpURLConnection
            if (connection is HttpsURLConnection && !pin.isNullOrEmpty()) {
                // The server's own certificate, confirmed by the user in the app.
                val context = SSLContext.getInstance("TLS")
                context.init(null, arrayOf<TrustManager>(PinnedTrust(pin)), null)
                connection.sslSocketFactory = context.socketFactory
                connection.setHostnameVerifier { _, _ -> true }
            }
            connection.requestMethod = "POST"
            connection.connectTimeout = 15_000
            connection.readTimeout = 15_000
            connection.doOutput = true
            connection.setRequestProperty("content-type", "application/json")
            connection.setRequestProperty("authorization", "Bearer $auth")
            try {
                connection.outputStream.use { it.write(body.toByteArray()) }
                connection.responseCode
            } finally {
                connection.disconnect()
            }
        } catch (_: Exception) {
            0
        }
    }

    override fun onDestroy() {
        main.removeCallbacks(stopLater)
        if (listening) runCatching { getSystemService(LocationManager::class.java).removeUpdates(listener) }
        super.onDestroy()
    }
}
