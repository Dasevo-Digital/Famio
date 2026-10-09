package de.status403.famio

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
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
        for (id in appWidgetIds) {
            val views = RemoteViews(context.packageName, R.layout.sos_widget).apply {
                setOnClickPendingIntent(R.id.sos_widget_root, launch)
            }
            appWidgetManager.updateAppWidget(id, views)
        }
    }
}
