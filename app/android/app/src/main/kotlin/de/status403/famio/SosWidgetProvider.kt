package de.status403.famio

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.SizeF
import android.widget.RemoteViews

/**
 * "Famio Notruf" on the home screen: one big button that opens Famio on
 * the emergency screen, which counts down 5 seconds before the alarm (to
 * cancel a slip) – like the quick settings tile and the app shortcut.
 */
class SosWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        val launch = PendingIntent.getActivity(
            context,
            4,
            MainActivity.sosIntent(context)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        fun button(layout: Int) = RemoteViews(context.packageName, layout).apply {
            setOnClickPendingIntent(R.id.sos_widget_root, launch)
        }
        for (id in appWidgetIds) {
            // A 1x1 cell is 57 to over 100 dp wide: from Android 12 on the
            // launcher takes the big button where it fits, else the small.
            val views = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                RemoteViews(
                    mapOf(
                        SizeF(40f, 40f) to button(R.layout.sos_widget),
                        SizeF(100f, 100f) to button(R.layout.sos_widget_large),
                    ),
                )
            } else {
                button(R.layout.sos_widget)
            }
            appWidgetManager.updateAppWidget(id, views)
        }
    }
}
