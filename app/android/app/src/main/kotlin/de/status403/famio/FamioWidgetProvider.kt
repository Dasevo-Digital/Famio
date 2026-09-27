package de.status403.famio

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.SharedPreferences
import android.view.View
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetProvider

/**
 * "Famio heute" on the home screen: next events, today's meal, open
 * shopping items and tasks. The app writes the lines whenever data changes;
 * the widget itself never talks to the server.
 */
class FamioWidgetProvider : HomeWidgetProvider() {
    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences,
    ) {
        val lines = listOf(R.id.widget_line1, R.id.widget_line2, R.id.widget_line3, R.id.widget_line4, R.id.widget_line5)
        for (id in appWidgetIds) {
            val views = RemoteViews(context.packageName, R.layout.famio_widget).apply {
                setTextViewText(R.id.widget_title, widgetData.getString("title", null) ?: "Famio")
                lines.forEachIndexed { i, view ->
                    val text = widgetData.getString("line$i", null)
                    setTextViewText(view, text ?: "")
                    setViewVisibility(view, if (text.isNullOrEmpty()) View.GONE else View.VISIBLE)
                }
                val empty = widgetData.getString("line0", null).isNullOrEmpty()
                setViewVisibility(R.id.widget_empty, if (empty) View.VISIBLE else View.GONE)
                setOnClickPendingIntent(
                    R.id.widget_root,
                    HomeWidgetLaunchIntent.getActivity(context, MainActivity::class.java),
                )
            }
            appWidgetManager.updateAppWidget(id, views)
        }
    }
}
