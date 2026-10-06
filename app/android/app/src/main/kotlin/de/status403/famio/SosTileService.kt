package de.status403.famio

import android.app.PendingIntent
import android.content.Intent
import android.os.Build
import android.service.quicksettings.TileService

/**
 * "Famio Notruf" in the quick settings: opens Famio on the emergency
 * screen, which counts down 5 seconds before the alarm (to cancel a slip).
 */
class SosTileService : TileService() {
    override fun onClick() {
        val intent = MainActivity.sosIntent(this).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        // Works on the lock screen too: the phone is unlocked first.
        unlockAndRun {
            if (Build.VERSION.SDK_INT >= 34) {
                startActivityAndCollapse(
                    PendingIntent.getActivity(
                        this,
                        3,
                        intent,
                        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
                    ),
                )
            } else {
                @Suppress("DEPRECATION", "StartActivityAndCollapseDeprecated")
                startActivityAndCollapse(intent)
            }
        }
    }
}
