package de.status403.famio

import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.widget.Toast
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Updates from the family's Famio server (`famio/app_update`): installs an
 * APK the Dart side downloaded and checked against the signed release.
 * Android asks the user to confirm and accepts it only if it is signed with
 * the same key as the installed app, so the data stays.
 *
 * Needs REQUEST_INSTALL_PACKAGES, which a Play Store build would leave out.
 */
class AppUpdateChannel(private val activity: Activity, messenger: BinaryMessenger) {
    init {
        MethodChannel(messenger, "famio/app_update").setMethodCallHandler { call, result ->
            when (call.method) {
                "canInstall" -> result.success(
                    Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
                        activity.packageManager.canRequestPackageInstalls(),
                )
                "openInstallSettings" -> {
                    activity.startActivity(
                        Intent(
                            Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                            Uri.parse("package:${activity.packageName}"),
                        ),
                    )
                    result.success(null)
                }
                "install" -> {
                    val path = call.argument<String>("path")
                    if (path == null) {
                        result.error("path", "path missing", null)
                    } else {
                        runCatching { install(File(path)) }
                            .onSuccess { result.success(null) }
                            .onFailure { result.error("install", it.message, null) }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun install(apk: File) {
        val installer = activity.packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
        // Only ever an update of Famio itself.
        params.setAppPackageName(activity.packageName)
        val id = installer.createSession(params)
        installer.openSession(id).use { session ->
            apk.inputStream().use { input ->
                session.openWrite("famio.apk", 0, apk.length()).use { output ->
                    input.copyTo(output)
                    session.fsync(output)
                }
            }
            val intent = Intent(activity, AppUpdateReceiver::class.java)
            // Mutable: the installer adds the status to this intent.
            val pending = PendingIntent.getBroadcast(
                activity,
                id,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE,
            )
            session.commit(pending.intentSender)
        }
        apk.delete()
    }
}

/** Shows Android's confirmation, or why the installation failed. */
class AppUpdateReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                val confirm = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    intent.getParcelableExtra(Intent.EXTRA_INTENT)
                }
                confirm?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                if (confirm != null) context.startActivity(confirm)
            }
            PackageInstaller.STATUS_SUCCESS -> Unit
            // Cancelled by the user: nothing to report.
            PackageInstaller.STATUS_FAILURE_ABORTED -> Unit
            else -> Toast.makeText(
                context,
                context.getString(
                    R.string.app_update_failed,
                    intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE) ?: "",
                ),
                Toast.LENGTH_LONG,
            ).show()
        }
    }
}
