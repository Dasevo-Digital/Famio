package de.status403.famio

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** Starts location sharing again after a restart or an app update. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val prefs = context.getSharedPreferences(LocationService.PREFS, Context.MODE_PRIVATE)
        if (prefs.getBoolean("enabled", false)) {
            try {
                LocationService.start(context)
            } catch (e: Exception) {
                // Not allowed right now (e.g. background start restrictions);
                // the app starts it again when opened.
            }
        }
    }
}
