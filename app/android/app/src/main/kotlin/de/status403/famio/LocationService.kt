package de.status403.famio

import android.Manifest
import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.hardware.Sensor
import android.hardware.SensorManager
import android.hardware.TriggerEvent
import android.hardware.TriggerEventListener
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.location.LocationRequest
import android.os.BatteryManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import org.json.JSONArray
import org.json.JSONObject
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.security.cert.X509Certificate
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.Executors
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SSLContext
import javax.net.ssl.TrustManager
import javax.net.ssl.X509TrustManager

/**
 * Shares the phone's position with the family while enabled, also with the
 * app closed and after a restart. The notification it has to show keeps
 * this visible to whoever holds the phone.
 *
 * It talks to the Famio server itself with a token that can only report
 * positions, so it needs neither the app nor its login.
 *
 * Battery and accuracy: normally it listens in the battery-friendly
 * "balanced" mode (Wi-Fi/cell, no GPS). When the motion sensor notices the
 * phone is carried around, it switches to precise mode (GPS) until the
 * phone has stopped moving for a few minutes. A heartbeat alarm (allowed
 * while the phone dozes) reports regularly and measures a fresh position
 * when none came for a while – the screen-off phone otherwise sleeps through
 * short trips.
 */
class LocationService : Service(), LocationListener {
    companion object {
        const val PREFS = "famio_location"
        private const val CHANNEL = "famio_location"
        private const val ALERT_CHANNEL = "famio_places"
        private const val NOTIFICATION_ID = 47110
        private const val ACTION_HEARTBEAT = "de.status403.famio.LOCATION_HEARTBEAT"

        /** Precise mode lasts this long after the last noticeable move. */
        private const val MOVING_MS = 5 * 60_000L

        /** Without a fix for this long, the heartbeat measures one. */
        private const val STALE_FIX_MS = 10 * 60_000L

        /** A move this far is uploaded at once, not with the next batch. */
        private const val UPLOAD_MOVE_M = 50f

        fun start(context: Context) {
            val intent = Intent(context, LocationService::class.java)
            if (Build.VERSION.SDK_INT >= 26) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, LocationService::class.java))
        }

        fun hasPermission(context: Context): Boolean =
            context.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) ==
                PackageManager.PERMISSION_GRANTED ||
                context.checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION) ==
                PackageManager.PERMISSION_GRANTED
    }

    private val handler = Handler(Looper.getMainLooper())
    private val network = Executors.newSingleThreadExecutor()
    private lateinit var locations: LocationManager
    private lateinit var queue: FixQueue
    private var listening = false

    /** Whether updates come from the fused provider (else GPS/network). */
    private var fusedMode = false
    private var paused = false
    private var intervalMs = 120_000L

    /** When positions were last uploaded; at most one upload a minute. */
    private var lastFixUpload = 0L
    private var lastUploaded: Location? = null

    /** Precise (GPS) mode until this [SystemClock.elapsedRealtime]. */
    private var movingUntil = 0L
    private var movingAnchor: Location? = null
    private var preciseMode = false
    private var lastHeartbeat = 0L
    private var foreground = false

    /** Measure one position right away with the next [startUpdates]. */
    private var needsFirstFix = true

    private val heartbeat = object : Runnable {
        override fun run() {
            tick()
            handler.postDelayed(this, intervalMs)
        }
    }

    /** The phone started to be carried around (wakes it from doze). */
    private val motion = object : TriggerEventListener() {
        override fun onTrigger(event: TriggerEvent?) {
            handler.post { startMoving() }
        }
    }

    private val prefs get() = getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    private val secrets get() = LocationSecrets.prefs(this)

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        LocationSecrets.migrate(this)
        loadQueue()
        locations = getSystemService(Context.LOCATION_SERVICE) as LocationManager
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26) {
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL,
                    getString(R.string.channel_location),
                    NotificationManager.IMPORTANCE_LOW,
                ).apply { description = getString(R.string.channel_location_description) },
            )
            manager.createNotificationChannel(
                NotificationChannel(
                    ALERT_CHANNEL,
                    getString(R.string.channel_places),
                    NotificationManager.IMPORTANCE_DEFAULT,
                ).apply { description = getString(R.string.channel_places_description) },
            )
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (!prefs.getBoolean("enabled", false)) {
            stopSelf()
            return START_NOT_STICKY
        }
        val fromAlarm = intent?.action == ACTION_HEARTBEAT
        if (fromAlarm && foreground) {
            tick()
            return START_STICKY
        }
        // Started again from the app, maybe for another account: the saved
        // queue is the one that counts (the app drops it then).
        if (!fromAlarm) loadQueue()
        try {
            if (Build.VERSION.SDK_INT >= 29) {
                startForeground(
                    NOTIFICATION_ID,
                    notification(),
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION,
                )
            } else {
                startForeground(NOTIFICATION_ID, notification())
            }
        } catch (e: Exception) {
            // Started from the background without "always" permission (an
            // alarm of a stopped service says nothing about the permission).
            if (!fromAlarm) report(state = "denied")
            stopSelf()
            return START_NOT_STICKY
        }
        foreground = true
        startUpdates()
        handler.removeCallbacks(heartbeat)
        handler.post(heartbeat)
        return START_STICKY
    }

    override fun onDestroy() {
        handler.removeCallbacks(heartbeat)
        cancelAlarm()
        motionSensor()?.let { sensors()?.cancelTriggerSensor(motion, it) }
        stopUpdates()
        network.shutdown()
        super.onDestroy()
    }

    // --- heartbeat -----------------------------------------------------------

    /**
     * Regular work, from the handler while the phone is awake and from the
     * alarm while it dozes (the handler's clock stops then).
     */
    private fun tick() {
        val now = SystemClock.elapsedRealtime()
        scheduleAlarm()
        if (now - lastHeartbeat < intervalMs / 2) return
        lastHeartbeat = now
        if (listening) {
            val wantPrecise = now < movingUntil
            // Network location switched on or off, or the phone stopped
            // moving: switch the way.
            if (useFused() != fusedMode || wantPrecise != preciseMode) {
                stopUpdates()
                startUpdates()
            }
            val lastFix = prefs.getLong("lastFixAt", 0L)
            if (!paused && System.currentTimeMillis() - lastFix > STALE_FIX_MS) {
                currentPosition(precise = false)
            }
        }
        flush()
    }

    private fun scheduleAlarm() {
        val alarms = getSystemService(AlarmManager::class.java) ?: return
        // Dozing phones grant such alarms about every 9 minutes at most.
        alarms.setAndAllowWhileIdle(
            AlarmManager.ELAPSED_REALTIME_WAKEUP,
            SystemClock.elapsedRealtime() + intervalMs,
            heartbeatIntent(),
        )
    }

    private fun cancelAlarm() {
        getSystemService(AlarmManager::class.java)?.cancel(heartbeatIntent())
    }

    private fun heartbeatIntent(): PendingIntent = PendingIntent.getService(
        this,
        1,
        Intent(this, LocationService::class.java).setAction(ACTION_HEARTBEAT),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )

    private fun sensors(): SensorManager? = getSystemService(SensorManager::class.java)

    private fun motionSensor(): Sensor? =
        sensors()?.getDefaultSensor(Sensor.TYPE_SIGNIFICANT_MOTION)

    /** One-shot: fires once when the phone starts moving, then re-armed. */
    private fun armMotion() {
        if (paused) return
        val sensor = motionSensor() ?: return
        sensors()?.requestTriggerSensor(motion, sensor)
    }

    private fun startMoving() {
        if (paused || !listening) return
        movingUntil = SystemClock.elapsedRealtime() + MOVING_MS
        movingAnchor = null
        if (!preciseMode) {
            stopUpdates()
            startUpdates()
        }
    }

    // --- positions -----------------------------------------------------------

    /**
     * Unconfirmed positions survive a restart, encrypted like the token.
     * Once sharing is off nothing is written any more.
     */
    private fun loadQueue() {
        val store = secrets
        queue = FixQueue.restore(
            store.getString(LocationSecrets.PENDING, null),
            System.currentTimeMillis(),
        ) { json ->
            val enabled = prefs.getBoolean("enabled", false)
            store.edit().apply {
                if (json == null || !enabled) {
                    remove(LocationSecrets.PENDING)
                } else {
                    putString(LocationSecrets.PENDING, json)
                }
            }.apply()
        }
    }

    private fun startUpdates() {
        if (paused || listening) return
        if (!hasPermission(this)) {
            updateNotification()
            return
        }
        try {
            // The battery-friendly fused mode needs network location (Wi-Fi,
            // cell); without it (switched off, emulator) only GPS works.
            fusedMode = useFused()
            preciseMode = SystemClock.elapsedRealtime() < movingUntil
            val interval = if (preciseMode) 30_000L else intervalMs
            if (fusedMode) {
                val request = LocationRequest.Builder(interval)
                    .setQuality(
                        if (preciseMode) {
                            LocationRequest.QUALITY_HIGH_ACCURACY
                        } else {
                            LocationRequest.QUALITY_BALANCED_POWER_ACCURACY
                        },
                    )
                    .setMinUpdateIntervalMillis(if (preciseMode) 15_000L else 30_000L)
                    .setMinUpdateDistanceMeters(if (preciseMode) 15f else 25f)
                    .build()
                locations.requestLocationUpdates(
                    LocationManager.FUSED_PROVIDER,
                    request,
                    mainExecutor,
                    this,
                )
            } else {
                for (provider in listOf(
                    LocationManager.NETWORK_PROVIDER,
                    LocationManager.GPS_PROVIDER,
                )) {
                    if (locations.allProviders.contains(provider)) {
                        locations.requestLocationUpdates(
                            provider,
                            interval,
                            if (preciseMode) 15f else 25f,
                            this,
                            Looper.getMainLooper(),
                        )
                    }
                }
            }
            listening = true
            if (needsFirstFix) {
                needsFirstFix = false
                currentPosition(precise = true)
            }
            if (!preciseMode) armMotion()
        } catch (e: SecurityException) {
            listening = false
        }
        updateNotification()
    }

    private fun networkLocation(): Boolean = try {
        locations.isProviderEnabled(LocationManager.NETWORK_PROVIDER)
    } catch (e: Exception) {
        false
    }

    private fun useFused(): Boolean =
        Build.VERSION.SDK_INT >= 31 &&
            locations.hasProvider(LocationManager.FUSED_PROVIDER) &&
            networkLocation()

    /**
     * One position right away, so the family need not wait for the first
     * movement: precise (GPS for up to a minute) at the start, otherwise a
     * cheap Wi-Fi/cell position that still shows a short trip.
     */
    private fun currentPosition(precise: Boolean) {
        try {
            if (Build.VERSION.SDK_INT >= 31 &&
                locations.hasProvider(LocationManager.FUSED_PROVIDER)
            ) {
                val request = LocationRequest.Builder(0L)
                    .setQuality(
                        if (precise || !networkLocation()) {
                            LocationRequest.QUALITY_HIGH_ACCURACY
                        } else {
                            LocationRequest.QUALITY_BALANCED_POWER_ACCURACY
                        },
                    )
                    .setDurationMillis(if (precise) 60_000L else 30_000L)
                    .build()
                locations.getCurrentLocation(
                    LocationManager.FUSED_PROVIDER,
                    request,
                    null,
                    mainExecutor,
                ) { location -> if (location != null) onLocationChanged(location) }
            } else if (Build.VERSION.SDK_INT >= 30) {
                val provider = if (locations.isProviderEnabled(LocationManager.GPS_PROVIDER)) {
                    LocationManager.GPS_PROVIDER
                } else {
                    LocationManager.NETWORK_PROVIDER
                }
                locations.getCurrentLocation(provider, null, mainExecutor) { location ->
                    if (location != null) onLocationChanged(location)
                }
            } else {
                for (provider in listOf(
                    LocationManager.GPS_PROVIDER,
                    LocationManager.NETWORK_PROVIDER,
                )) {
                    val location = locations.getLastKnownLocation(provider) ?: continue
                    if (System.currentTimeMillis() - location.time < 10 * 60_000L) {
                        onLocationChanged(location)
                        break
                    }
                }
            }
        } catch (e: Exception) {
            // Provider missing or permission gone; regular updates follow.
        }
    }

    private fun stopUpdates() {
        if (!listening) return
        locations.removeUpdates(this)
        listening = false
    }

    override fun onLocationChanged(location: Location) {
        prefs.edit().putLong("lastFixAt", location.time).apply()
        if (preciseMode) {
            // Still moving: stay precise a little longer.
            val anchor = movingAnchor
            if (anchor == null || anchor.distanceTo(location) > 30f) {
                movingAnchor = location
                movingUntil = SystemClock.elapsedRealtime() + MOVING_MS
            }
        }
        queue.add(
            JSONObject()
                .put("lat", location.latitude)
                .put("lon", location.longitude)
                .put("acc", if (location.hasAccuracy()) location.accuracy.toDouble() else JSONObject.NULL)
                .put("at", location.time)
                .put("battery", battery()),
            System.currentTimeMillis(),
        )
        // At most one upload a minute unless the phone moved noticeably;
        // the heartbeat sends the rest.
        val moved = lastUploaded?.let { it.distanceTo(location) >= UPLOAD_MOVE_M } ?: true
        if (moved || System.currentTimeMillis() - lastFixUpload >= 60_000L) {
            lastUploaded = location
            flush()
        }
    }

    override fun onProviderEnabled(provider: String) = providersChanged()

    override fun onProviderDisabled(provider: String) = providersChanged()

    /** Location or network location switched on/off: pick the way again. */
    private fun providersChanged() {
        if (listening) {
            stopUpdates()
            startUpdates()
        }
        flush()
    }

    @Deprecated("Needed below API 29")
    override fun onStatusChanged(provider: String?, status: Int, extras: android.os.Bundle?) {}

    private fun state(): String = when {
        !hasPermission(this) -> "denied"
        Build.VERSION.SDK_INT >= 28 && !locations.isLocationEnabled -> "off"
        else -> "active"
    }

    private fun battery(): Int? {
        val manager = getSystemService(Context.BATTERY_SERVICE) as? BatteryManager
        val level = manager?.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY) ?: -1
        return if (level in 0..100) level else null
    }

    // --- server --------------------------------------------------------------

    private fun flush() = report(state = state())

    private fun report(state: String) {
        val url = secrets.getString("url", null) ?: return
        val token = secrets.getString("token", null) ?: return
        val pin = secrets.getString("pin", null)
        val device = secrets.getString("device", null)
        val alertsSince = prefs.getLong("alertsSince", System.currentTimeMillis())
        val batch = queue.snapshot()
        if (batch.isNotEmpty()) lastFixUpload = System.currentTimeMillis()
        if (network.isShutdown) return
        // A dozing phone would fall asleep in the middle of the upload.
        val wake = (getSystemService(Context.POWER_SERVICE) as PowerManager)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "famio:location")
            .apply {
                setReferenceCounted(false)
                acquire(45_000L)
            }
        network.execute {
            val body = JSONObject()
                .put("fixes", JSONArray(batch))
                .put("state", state)
                .put("platform", "android")
                .put("device", device)
                .put("alertsSince", alertsSince)
            try {
                val (status, text) = post(URL(URL(url), "api/location/report"), token, pin, body)
                recordServerResponse(status, uploadedPosition = batch.isNotEmpty())
                when {
                    status in 200..299 -> {
                        queue.confirm(batch)
                        handler.post { applyAnswer(JSONObject(text)) }
                    }
                    status == 401 -> handler.post { revoked() }
                }
            } catch (e: IOException) {
                // Offline: keep the positions for the next attempt.
                recordTransferError(getString(R.string.error_network))
            } catch (e: Exception) {
                // Unexpected answer; try again with the next heartbeat.
                recordTransferError(getString(R.string.error_transfer))
            } finally {
                if (wake.isHeld) wake.release()
            }
        }
    }

    private fun recordServerResponse(status: Int, uploadedPosition: Boolean) {
        val now = System.currentTimeMillis()
        prefs.edit()
            .putLong("lastServerResponseAt", now)
            .putString("lastServerStatus", "HTTP $status")
            .apply {
                if (uploadedPosition && status in 200..299) {
                    putLong("lastSuccessfulUploadAt", now)
                }
                // A server response means the previous transport failure is
                // no longer the current diagnosis.
                remove("lastErrorAt")
                remove("lastError")
            }
            .apply()
    }

    private fun recordTransferError(message: String) {
        prefs.edit()
            .putLong("lastErrorAt", System.currentTimeMillis())
            .putString("lastError", message)
            .apply()
    }

    private fun applyAnswer(answer: JSONObject) {
        val nowPaused = answer.optBoolean("paused", false)
        intervalMs = answer.optLong("interval", 120).coerceIn(30, 3600) * 1000
        val until = answer.optString("pausedUntil", "")
        prefs.edit().putString("pausedUntil", until.ifEmpty { null }).apply()
        if (nowPaused != paused) {
            paused = nowPaused
            if (paused) {
                stopUpdates()
                motionSensor()?.let { sensors()?.cancelTriggerSensor(motion, it) }
            } else {
                needsFirstFix = true
                startUpdates()
            }
            handler.removeCallbacks(heartbeat)
            handler.postDelayed(heartbeat, intervalMs)
        }
        updateNotification()
        showAlerts(answer.optJSONArray("alerts"))
    }

    private fun showAlerts(alerts: JSONArray?) {
        if (alerts == null || alerts.length() == 0) return
        val manager = getSystemService(NotificationManager::class.java)
        var newest = prefs.getLong("alertsSince", 0)
        for (i in 0 until alerts.length()) {
            val alert = alerts.getJSONObject(i)
            val id = alert.getString("id")
            val at = alert.optLong("at", 0)
            if (at > newest) newest = at
            val notification = builder(ALERT_CHANNEL)
                .setContentTitle("Famio")
                .setContentText(alert.getString("text"))
                .setAutoCancel(true)
                .setWhen(at)
                .setShowWhen(true)
                .build()
            // Same id as the app uses, so it never shows twice.
            manager.notify(alertNotificationId(id), notification)
        }
        prefs.edit().putLong("alertsSince", newest).apply()
    }

    private fun alertNotificationId(id: String): Int =
        id.substring(0, 7).toIntOrNull(16) ?: id.hashCode()

    /** The token was signed out (e.g. in the device list): stop for good. */
    private fun revoked() {
        prefs.edit().putBoolean("enabled", false).apply()
        LocationSecrets.clear(this)
        val manager = getSystemService(NotificationManager::class.java)
        manager.notify(
            NOTIFICATION_ID + 1,
            builder(ALERT_CHANNEL)
                .setContentTitle(getString(R.string.location_sharing_ended))
                .setContentText(getString(R.string.device_signed_out))
                .setAutoCancel(true)
                .build(),
        )
        stopSelf()
    }

    private fun post(url: URL, token: String, pin: String?, body: JSONObject): Pair<Int, String> {
        val connection = url.openConnection() as HttpURLConnection
        if (connection is HttpsURLConnection && !pin.isNullOrEmpty()) {
            // The server's own certificate, confirmed by the user in the app.
            val context = SSLContext.getInstance("TLS")
            context.init(null, arrayOf<TrustManager>(PinnedTrust(pin)), null)
            connection.sslSocketFactory = context.socketFactory
            connection.setHostnameVerifier { _, _ -> true }
        }
        connection.requestMethod = "POST"
        connection.connectTimeout = 20_000
        connection.readTimeout = 20_000
        connection.doOutput = true
        connection.setRequestProperty("content-type", "application/json")
        connection.setRequestProperty("authorization", "Bearer $token")
        try {
            connection.outputStream.use { it.write(body.toString().toByteArray()) }
            val status = connection.responseCode
            val stream = if (status < 400) connection.inputStream else connection.errorStream
            val text = stream?.bufferedReader()?.use { it.readText() } ?: ""
            return status to text
        } finally {
            connection.disconnect()
        }
    }

    // --- notification --------------------------------------------------------

    private fun builder(channel: String): Notification.Builder {
        val builder = if (Build.VERSION.SDK_INT >= 26) {
            Notification.Builder(this, channel)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        return builder
            .setSmallIcon(R.drawable.ic_launcher_monochrome)
            .setContentIntent(open)
    }

    private fun notification(): Notification {
        val text = when {
            paused -> {
                val until = prefs.getString("pausedUntil", null)
                    ?.let { runCatching { parseIso(it) }.getOrNull() }
                if (until == null) {
                    getString(R.string.location_paused)
                } else {
                    getString(
                        R.string.location_paused_until,
                        android.text.format.DateFormat.getTimeFormat(this).format(until),
                    )
                }
            }
            !hasPermission(this) -> getString(R.string.location_permission_missing)
            else -> getString(R.string.location_visible)
        }
        return builder(CHANNEL)
            .setContentTitle(getString(R.string.location_sharing_title))
            .setContentText(text)
            .setOngoing(true)
            .build()
    }

    private fun updateNotification() {
        getSystemService(NotificationManager::class.java)
            .notify(NOTIFICATION_ID, notification())
    }

    private fun parseIso(text: String): Date? {
        val format = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss", Locale.ROOT)
        format.timeZone = java.util.TimeZone.getTimeZone("UTC")
        return format.parse(text.substring(0, 19))
    }
}

/**
 * Accepts exactly the server key with the given SHA-256 fingerprint (of the
 * certificate's SubjectPublicKeyInfo; it stays when the server renews its
 * certificate), as the Dart client does.
 */
internal class PinnedTrust(pin: String) : X509TrustManager {
    private val expected = pin.replace(":", "").uppercase()

    override fun checkServerTrusted(chain: Array<out X509Certificate>, authType: String?) {
        val leaf = chain.firstOrNull() ?: throw java.security.cert.CertificateException("Kein Zertifikat")
        val digest = MessageDigest.getInstance("SHA-256").digest(subjectPublicKeyInfo(leaf.encoded))
        val actual = digest.joinToString("") { "%02X".format(it) }
        if (actual != expected) {
            throw java.security.cert.CertificateException("Unbekanntes Zertifikat")
        }
    }

    override fun checkClientTrusted(chain: Array<out X509Certificate>, authType: String?) =
        throw java.security.cert.CertificateException("Nicht unterstützt")

    override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
}

/** The DER SubjectPublicKeyInfo inside an X.509 certificate. */
internal fun subjectPublicKeyInfo(der: ByteArray): ByteArray {
    fun read(offset: Int): Pair<Int, Int> { // content start, end
        if (offset + 2 > der.size) throw java.security.cert.CertificateException("DER zu kurz")
        var length = der[offset + 1].toInt() and 0xff
        var start = offset + 2
        if (length and 0x80 != 0) {
            val count = length and 0x7f
            if (count == 0 || count > 4) throw java.security.cert.CertificateException("DER-Länge")
            length = 0
            repeat(count) { length = (length shl 8) or (der[start + it].toInt() and 0xff) }
            start += count
        }
        if (start + length > der.size) throw java.security.cert.CertificateException("DER zu kurz")
        return start to start + length
    }
    val tbs = read(read(0).first)
    var offset = tbs.first
    if (der[offset].toInt() and 0xff == 0xA0) offset = read(offset).second
    repeat(5) { offset = read(offset).second } // serial, algorithm, issuer, validity, subject
    return der.copyOfRange(offset, read(offset).second)
}
