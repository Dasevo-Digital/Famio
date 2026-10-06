package de.status403.famio

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.os.Handler
import android.os.Looper
import android.os.Build
import android.os.IBinder
import org.json.JSONObject
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.text.SimpleDateFormat
import java.util.Locale
import java.util.TimeZone
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SSLContext
import javax.net.ssl.TrustManager

/**
 * Famio's own push: keeps a request to the Famio server open (it answers
 * as soon as something happens, at the latest after a few minutes) and
 * shows new messages, tasks etc. – also with the app closed, without ntfy
 * or Google.
 *
 * Like [LocationService] it uses its own token that can only fetch
 * notifications, and the pinned server key.
 */
class NotifyService : Service() {
    companion object {
        const val PREFS = "famio_notify"
        private const val CHANNEL = "famio_connection"
        private const val MESSAGES = "famio_messages"
        private const val QUIET = "famio_quiet"
        private const val ALARM = "famio_sos"
        private const val STOP_RING = "de.status403.famio.STOP_RING"

        /** How long a "ring the phone" from the parents sounds. */
        private const val RING_MS = 30_000L
        private const val NOTIFICATION_ID = 47120
        private const val WAIT_SECONDS = 240

        fun start(context: Context) {
            val intent = Intent(context, NotifyService::class.java)
            if (Build.VERSION.SDK_INT >= 26) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, NotifyService::class.java))
        }
    }

    @Volatile private var running = false
    private var worker: Thread? = null

    private val prefs get() = getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        if (Build.VERSION.SDK_INT >= 26) {
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL,
                    "Verbindung",
                    NotificationManager.IMPORTANCE_MIN,
                ).apply {
                    description = "Zeigt an, dass Famio Benachrichtigungen empfängt. " +
                        "Kann ausgeblendet werden."
                    setShowBadge(false)
                },
            )
            manager.createNotificationChannel(
                NotificationChannel(
                    MESSAGES,
                    "Nachrichten & Hinweise",
                    NotificationManager.IMPORTANCE_HIGH,
                ).apply { description = "Neue Nachrichten, Aufgaben, Termine und Anfragen" },
            )
            manager.createNotificationChannel(
                NotificationChannel(
                    QUIET,
                    "Ruhezeit",
                    NotificationManager.IMPORTANCE_LOW,
                ).apply { description = "Hinweise während der eigenen Ruhezeit, ohne Ton" },
            )
            manager.createNotificationChannel(
                NotificationChannel(
                    ALARM,
                    "Notfall (SOS)",
                    NotificationManager.IMPORTANCE_HIGH,
                ).apply {
                    description = "Wenn jemand aus der Familie den Notfallknopf drückt – " +
                        "laut, auch bei „Nicht stören“"
                    setSound(
                        RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM),
                        AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_ALARM)
                            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                            .build(),
                    )
                    enableVibration(true)
                    vibrationPattern = longArrayOf(0, 800, 400, 800, 400, 800)
                    setBypassDnd(true)
                    lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                },
            )
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == STOP_RING) {
            stopRing()
            return START_STICKY
        }
        if (!prefs.getBoolean("enabled", false)) {
            stopSelf()
            return START_NOT_STICKY
        }
        try {
            if (Build.VERSION.SDK_INT >= 34) {
                startForeground(
                    NOTIFICATION_ID,
                    connectionNotification(),
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_REMOTE_MESSAGING,
                )
            } else {
                startForeground(NOTIFICATION_ID, connectionNotification())
            }
        } catch (e: Exception) {
            // Not allowed from the background right now; the app starts it
            // again when opened.
            stopSelf()
            return START_NOT_STICKY
        }
        if (worker?.isAlive != true) {
            running = true
            worker = Thread({ loop() }, "famio-notify").apply {
                isDaemon = true
                start()
            }
        }
        return START_STICKY
    }

    override fun onDestroy() {
        stopRing()
        running = false
        worker?.interrupt()
        super.onDestroy()
    }

    // --- fetching ----------------------------------------------------------

    private fun loop() {
        var delayMs = 2_000L
        while (running) {
            val url = prefs.getString("url", null)
            val token = prefs.getString("token", null)
            if (url == null || token == null) break
            val pin = prefs.getString("pin", null)
            val last = prefs.getLong("last", -1)
            try {
                val path = if (last < 0) {
                    "api/notifications"
                } else {
                    "api/notifications?after=$last&wait=$WAIT_SECONDS"
                }
                val (status, text) = get(URL(URL(url), path), token, pin)
                when {
                    status in 200..299 -> {
                        val answer = JSONObject(text)
                        show(answer.optJSONArray("notices"))
                        prefs.edit().putLong("last", answer.optLong("last", last)).apply()
                        delayMs = 2_000L
                        continue
                    }
                    status == 401 -> {
                        revoked()
                        return
                    }
                }
            } catch (e: InterruptedException) {
                return
            } catch (e: IOException) {
                // Offline or the connection dropped: try again soon.
            } catch (e: Exception) {
                // Unexpected answer: try again later.
            }
            try {
                Thread.sleep(delayMs)
            } catch (e: InterruptedException) {
                return
            }
            delayMs = (delayMs * 2).coerceAtMost(300_000L)
        }
    }

    private fun show(notices: org.json.JSONArray?) {
        if (notices == null || notices.length() == 0) return
        val manager = getSystemService(NotificationManager::class.java)
        val details = prefs.getBoolean("details", true)
        // A sharing phone shows arrivals from its location service already.
        val placesElsewhere = getSharedPreferences(LocationService.PREFS, Context.MODE_PRIVATE)
            .getBoolean("enabled", false)
        for (i in 0 until notices.length()) {
            val notice = notices.getJSONObject(i)
            if (placesElsewhere && notice.optString("tag") == "round_pushpin") continue
            val at = runCatching { parseUtc(notice.optString("at")) }
                .getOrDefault(System.currentTimeMillis())
            val title = if (details) notice.optString("title", "Famio") else "Famio"
            val text = if (details) notice.optString("body") else notice.optString("brief")
            // In the member's quiet time (set on the server): no sound.
            val alarm = notice.optBoolean("alarm")
            val ring = notice.optString("tag") == "loud_sound"
            if (ring) startRing()
            val channel = when {
                alarm -> ALARM
                notice.optBoolean("quiet") -> QUIET
                else -> MESSAGES
            }
            val public = builder(channel)
                .setContentTitle("Famio")
                .setContentText(notice.optString("brief"))
                .build()
            val notification = builder(channel)
                .apply {
                    if (alarm) {
                        // Over the lock screen, like an alarm clock.
                        setCategory(Notification.CATEGORY_ALARM)
                        setFullScreenIntent(
                            PendingIntent.getActivity(
                                this@NotifyService,
                                1,
                                Intent(this@NotifyService, MainActivity::class.java)
                                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
                            ),
                            true,
                        )
                    }
                }
                .apply {
                    if (ring) {
                        val stop = PendingIntent.getService(
                            this@NotifyService,
                            2,
                            Intent(this@NotifyService, NotifyService::class.java).setAction(STOP_RING),
                            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
                        )
                        @Suppress("DEPRECATION")
                        addAction(Notification.Action.Builder(null, "Ruhe", stop).build())
                        setDeleteIntent(stop)
                        setContentIntent(stop)
                    }
                }
                .setContentTitle(title)
                .setContentText(text)
                .setStyle(Notification.BigTextStyle().bigText(text))
                .setAutoCancel(true)
                .setWhen(at)
                .setShowWhen(true)
                // The lock screen shows only the short hint.
                .setVisibility(Notification.VISIBILITY_PRIVATE)
                .setPublicVersion(public)
                .build()
            manager.notify(NOTIFICATION_ID + 1 + (notice.optLong("id") % 100_000).toInt(), notification)
        }
    }

    /** "2026-09-28T14:03:00.000Z" → epoch milliseconds (Android 7+). */
    private fun parseUtc(text: String): Long {
        val format = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss", Locale.ROOT)
        format.timeZone = TimeZone.getTimeZone("UTC")
        return format.parse(text.substring(0, 19))!!.time
    }

    /** The token was signed out (e.g. in the device list): stop for good. */
    private fun revoked() {
        prefs.edit().putBoolean("enabled", false).remove("token").apply()
        getSystemService(NotificationManager::class.java).notify(
            NOTIFICATION_ID + 1,
            builder(MESSAGES)
                .setContentTitle("Benachrichtigungen beendet")
                .setContentText("Das Gerät wurde abgemeldet. In Famio neu einschalten.")
                .setAutoCancel(true)
                .build(),
        )
        running = false
        stopSelf()
    }

    private fun get(url: URL, token: String, pin: String?): Pair<Int, String> {
        val connection = url.openConnection() as HttpURLConnection
        if (connection is HttpsURLConnection && !pin.isNullOrEmpty()) {
            // The server's own certificate, confirmed by the user in the app.
            val context = SSLContext.getInstance("TLS")
            context.init(null, arrayOf<TrustManager>(PinnedTrust(pin)), null)
            connection.sslSocketFactory = context.socketFactory
            connection.setHostnameVerifier { _, _ -> true }
        }
        connection.requestMethod = "GET"
        connection.connectTimeout = 20_000
        // The server answers after at most WAIT_SECONDS.
        connection.readTimeout = (WAIT_SECONDS + 60) * 1000
        connection.setRequestProperty("accept", "application/json")
        connection.setRequestProperty("authorization", "Bearer $token")
        try {
            val status = connection.responseCode
            val stream = if (status < 400) connection.inputStream else connection.errorStream
            val text = stream?.bufferedReader()?.use { it.readText() } ?: ""
            return status to text
        } finally {
            connection.disconnect()
        }
    }

    // --- ringing ---------------------------------------------------------------

    private val main = Handler(Looper.getMainLooper())
    private var ringer: MediaPlayer? = null
    private var previousAlarmVolume: Int? = null
    private val stopLater = Runnable { stopRing() }

    /** The parents let this phone ring: alarm sound, full volume, 30 s. */
    private fun startRing() = main.post {
        stopRing()
        val audio = getSystemService(AudioManager::class.java)
        previousAlarmVolume = audio.getStreamVolume(AudioManager.STREAM_ALARM)
        runCatching {
            audio.setStreamVolume(
                AudioManager.STREAM_ALARM,
                audio.getStreamMaxVolume(AudioManager.STREAM_ALARM),
                0,
            )
        }
        ringer = runCatching {
            MediaPlayer().apply {
                setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_ALARM)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build(),
                )
                setDataSource(
                    this@NotifyService,
                    RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
                        ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE),
                )
                isLooping = true
                prepare()
                start()
            }
        }.getOrNull()
        main.postDelayed(stopLater, RING_MS)
    }

    private fun stopRing() {
        main.removeCallbacks(stopLater)
        ringer?.runCatching {
            stop()
            release()
        }
        ringer = null
        previousAlarmVolume?.let { volume ->
            runCatching {
                getSystemService(AudioManager::class.java)
                    .setStreamVolume(AudioManager.STREAM_ALARM, volume, 0)
            }
        }
        previousAlarmVolume = null
    }

    // --- notifications -------------------------------------------------------

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

    private fun connectionNotification(): Notification =
        builder(CHANNEL)
            .setContentTitle("Famio ist bereit")
            .setContentText("Empfängt Benachrichtigungen – gedrückt halten zum Ausblenden")
            .setOngoing(true)
            .build()
}
