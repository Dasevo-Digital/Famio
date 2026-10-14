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
 * shopping items and tasks, each as a row tinted in its section's color.
 * The app writes the rows whenever data changes; the widget itself never
 * talks to the server.
 */
class FamioWidgetProvider : HomeWidgetProvider() {
    private data class Row(val row: Int, val lead: Int, val text: Int)

    private val rows = listOf(
        Row(R.id.widget_row0, R.id.widget_lead0, R.id.widget_text0),
        Row(R.id.widget_row1, R.id.widget_lead1, R.id.widget_text1),
        Row(R.id.widget_row2, R.id.widget_lead2, R.id.widget_text2),
        Row(R.id.widget_row3, R.id.widget_lead3, R.id.widget_text3),
        Row(R.id.widget_row4, R.id.widget_lead4, R.id.widget_text4),
    )

    // Resources, not colors: the launcher resolves them, so the rows follow
    // the phone's light or dark mode without an update.
    private val backgrounds = mapOf(
        "event" to R.drawable.widget_row_event,
        "meal" to R.drawable.widget_row_meal,
        "tasks" to R.drawable.widget_row_tasks,
        "shopping" to R.drawable.widget_row_shopping,
        "sleep" to R.drawable.widget_row_sleep,
    )

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences,
    ) {
        for (id in appWidgetIds) {
            val views = RemoteViews(context.packageName, R.layout.famio_widget).apply {
                setTextViewText(R.id.widget_date, widgetData.getString("date", null) ?: "")
                var any = false
                rows.forEachIndexed { i, r ->
                    // "line$i": written by apps before 2.0.5, until the app
                    // runs again after the update.
                    val text = widgetData.getString("text$i", null)
                        ?: widgetData.getString("line$i", null)
                    if (text.isNullOrEmpty()) {
                        setViewVisibility(r.row, View.GONE)
                        return@forEachIndexed
                    }
                    any = true
                    val lead = widgetData.getString("lead$i", null)
                    setViewVisibility(r.row, View.VISIBLE)
                    setTextViewText(r.text, text)
                    setTextViewText(r.lead, lead ?: "")
                    setViewVisibility(r.lead, if (lead.isNullOrEmpty()) View.GONE else View.VISIBLE)
                    setInt(
                        r.row,
                        "setBackgroundResource",
                        backgrounds[widgetData.getString("kind$i", null)] ?: R.drawable.widget_row_event,
                    )
                }
                setViewVisibility(R.id.widget_empty, if (any) View.GONE else View.VISIBLE)
                setOnClickPendingIntent(
                    R.id.widget_root,
                    HomeWidgetLaunchIntent.getActivity(context, MainActivity::class.java),
                )
            }
            appWidgetManager.updateAppWidget(id, views)
        }
    }
}
