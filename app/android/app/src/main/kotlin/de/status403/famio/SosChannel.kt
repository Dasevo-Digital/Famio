package de.status403.famio

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.MediaPlayer
import android.net.Uri
import android.os.BatteryManager
import android.os.Build
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import android.telephony.SmsManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * The emergency button's phone side (`famio/sos`): one fresh position, a
 * siren on the alarm stream (sounds also on silent), a direct call and a
 * text message. Permissions are asked for when first needed.
 */
class SosChannel(private val activity: Activity, messenger: BinaryMessenger) {
    private var player: MediaPlayer? = null
    private var previousAlarmVolume: Int? = null
    private var pending: Pair<MethodCall, MethodChannel.Result>? = null
    private val main = Handler(Looper.getMainLooper())

    init {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "currentFix" -> withPermissions(LOCATION, call, result) { currentFix(call, result) }
                "startSiren" -> {
                    startSiren(call.argument<ByteArray>("wav")!!)
                    result.success(null)
                }
                "stopSiren" -> {
                    stopSiren()
                    result.success(null)
                }
                "call" -> withPermissions(arrayOf(Manifest.permission.CALL_PHONE), call, result) {
                    result.success(callNow(call.argument<String>("number")!!))
                }
                "sendSms" -> withPermissions(arrayOf(Manifest.permission.SEND_SMS), call, result) {
                    result.success(
                        sendSms(call.argument<List<String>>("numbers")!!, call.argument<String>("text")!!),
                    )
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun granted(permission: String) =
        activity.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    /** Runs [action] once one of [permissions] is granted; else answers false/null. */
    private fun withPermissions(
        permissions: Array<String>,
        call: MethodCall,
        result: MethodChannel.Result,
        action: () -> Unit,
    ) {
        if (permissions.any { granted(it) }) {
            action()
            return
        }
        if (pending != null) {
            result.success(if (call.method == "currentFix") null else false)
            return
        }
        pending = call to result
        activity.requestPermissions(permissions, REQUEST)
    }

    /** From MainActivity.onRequestPermissionsResult. */
    fun onPermissionResult(requestCode: Int): Boolean {
        if (requestCode != REQUEST) return false
        val (call, result) = pending ?: return true
        pending = null
        val needed = when (call.method) {
            "currentFix" -> LOCATION
            "call" -> arrayOf(Manifest.permission.CALL_PHONE)
            else -> arrayOf(Manifest.permission.SEND_SMS)
        }
        if (needed.none { granted(it) }) {
            result.success(if (call.method == "currentFix") null else false)
            return true
        }
        when (call.method) {
            "currentFix" -> currentFix(call, result)
            "call" -> result.success(callNow(call.argument<String>("number")!!))
            else -> result.success(
                sendSms(call.argument<List<String>>("numbers")!!, call.argument<String>("text")!!),
            )
        }
        return true
    }

    private fun battery(): Int? =
        (activity.getSystemService(Context.BATTERY_SERVICE) as BatteryManager)
            .getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
            .takeIf { it in 0..100 }

    private fun answer(result: MethodChannel.Result, location: Location?) {
        if (location == null) {
            result.success(null)
            return
        }
        result.success(
            mapOf(
                "latitude" to location.latitude,
                "longitude" to location.longitude,
                "accuracy" to if (location.hasAccuracy()) location.accuracy.toDouble() else null,
                "battery" to battery(),
            ),
        )
    }

    /**
     * A fresh fix from GPS (or the network), at most `timeoutMs`; falls
     * back to the last known position if nothing new arrives in time.
     */
    @Suppress("MissingPermission", "DEPRECATION")
    private fun currentFix(call: MethodCall, result: MethodChannel.Result) {
        val manager = activity.getSystemService(Context.LOCATION_SERVICE) as LocationManager
        val timeout = (call.argument<Int>("timeoutMs") ?: 20000).toLong()
        val providers = listOf(LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER)
            .filter { runCatching { manager.isProviderEnabled(it) }.getOrDefault(false) }
        val lastKnown = providers
            .mapNotNull { runCatching { manager.getLastKnownLocation(it) }.getOrNull() }
            .maxByOrNull { it.time }
        if (providers.isEmpty()) {
            answer(result, lastKnown)
            return
        }
        var done = false
        val listeners = mutableListOf<LocationListener>()
        val cancel = CancellationSignal()
        fun finish(location: Location?) {
            if (done) return
            done = true
            cancel.cancel()
            listeners.forEach { runCatching { manager.removeUpdates(it) } }
            answer(result, location ?: lastKnown)
        }
        main.postDelayed({ finish(null) }, timeout)
        for (provider in providers) {
            if (Build.VERSION.SDK_INT >= 30) {
                manager.getCurrentLocation(provider, cancel, activity.mainExecutor) { location ->
                    // GPS is better; the network answers only when GPS has nothing.
                    if (location != null &&
                        (provider == LocationManager.GPS_PROVIDER || providers.size == 1)
                    ) {
                        finish(location)
                    } else if (location != null) {
                        main.postDelayed({ finish(location) }, 8000)
                    }
                }
            } else {
                val listener = LocationListener { location -> finish(location) }
                listeners.add(listener)
                manager.requestSingleUpdate(provider, listener, Looper.getMainLooper())
            }
        }
    }

    /** Loops [wav] on the alarm stream at full volume until [stopSiren]. */
    private fun startSiren(wav: ByteArray) {
        stopSiren()
        val file = File(activity.cacheDir, "sos-siren.wav")
        file.writeBytes(wav)
        val audio = activity.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        previousAlarmVolume = audio.getStreamVolume(AudioManager.STREAM_ALARM)
        runCatching {
            audio.setStreamVolume(
                AudioManager.STREAM_ALARM,
                audio.getStreamMaxVolume(AudioManager.STREAM_ALARM),
                0,
            )
        }
        player = MediaPlayer().apply {
            setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_ALARM)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build(),
            )
            setDataSource(file.absolutePath)
            isLooping = true
            prepare()
            start()
        }
    }

    fun stopSiren() {
        player?.runCatching {
            stop()
            release()
        }
        player = null
        previousAlarmVolume?.let { volume ->
            val audio = activity.getSystemService(Context.AUDIO_SERVICE) as AudioManager
            runCatching { audio.setStreamVolume(AudioManager.STREAM_ALARM, volume, 0) }
        }
        previousAlarmVolume = null
    }

    private fun callNow(number: String): Boolean {
        if (!granted(Manifest.permission.CALL_PHONE)) return false
        return runCatching {
            activity.startActivity(
                Intent(Intent.ACTION_CALL, Uri.parse("tel:" + Uri.encode(number)))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
            true
        }.getOrDefault(false)
    }

    @Suppress("DEPRECATION")
    private fun sendSms(numbers: List<String>, text: String): Boolean {
        if (!granted(Manifest.permission.SEND_SMS)) return false
        val sms = if (Build.VERSION.SDK_INT >= 31) {
            activity.getSystemService(SmsManager::class.java)
        } else {
            SmsManager.getDefault()
        } ?: return false
        var sent = false
        for (number in numbers.filter { it.isNotBlank() }) {
            runCatching {
                sms.sendMultipartTextMessage(number, null, sms.divideMessage(text), null, null)
                sent = true
            }
        }
        return sent
    }

    companion object {
        const val CHANNEL = "famio/sos"
        private const val REQUEST = 4720
        private val LOCATION = arrayOf(
            Manifest.permission.ACCESS_FINE_LOCATION,
            Manifest.permission.ACCESS_COARSE_LOCATION,
        )
    }
}
