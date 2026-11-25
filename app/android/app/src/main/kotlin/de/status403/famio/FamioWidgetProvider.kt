package de.status403.famio

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.view.View
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetLaunchIntent

/**
 * "Famio heute" on the home screen: next events, today's meal, open
 * shopping items and tasks, each as a row tinted in its section's color.
 * The app writes the rows whenever data changes (see [WidgetData]); the
 * widget itself never talks to the server.
 */
class FamioWidgetProvider : AppWidgetProvider() {
    companion object {
        /** Draws [ids] again from [WidgetData]. */
        fun show(context: Context, ids: IntArray) {
            if (ids.isEmpty()) return
            runCatching {
                FamioWidgetProvider().draw(context, AppWidgetManager.getInstance(context), ids)
            }
        }
    }

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
    ) {
        runCatching { WidgetData.migrate(context) }
        draw(context, appWidgetManager, appWidgetIds)
    }

    /** The last widget was removed: its rows are not kept. */
    override fun onDisabled(context: Context) {
        runCatching { WidgetData.clear(context) }
    }

    private fun draw(context: Context, manager: AppWidgetManager, ids: IntArray) {
        // Not readable (keystore): empty rather than nothing at all.
        val (date, lines) = runCatching { WidgetData.read(context) }
            .getOrDefault(null to emptyList())
        for (id in ids) {
            val views = RemoteViews(context.packageName, R.layout.famio_widget).apply {
                setTextViewText(R.id.widget_date, date ?: "")
                rows.forEachIndexed { i, r ->
                    val line = lines.getOrNull(i)
                    if (line == null) {
                        setViewVisibility(r.row, View.GONE)
                        return@forEachIndexed
                    }
                    setViewVisibility(r.row, View.VISIBLE)
                    setTextViewText(r.text, line.text)
                    setTextViewText(r.lead, line.lead ?: "")
                    setViewVisibility(
                        r.lead,
                        if (line.lead.isNullOrEmpty()) View.GONE else View.VISIBLE,
                    )
                    setInt(
                        r.row,
                        "setBackgroundResource",
                        backgrounds[line.kind] ?: R.drawable.widget_row_event,
                    )
                }
                setViewVisibility(
                    R.id.widget_empty,
                    if (lines.isEmpty()) View.VISIBLE else View.GONE,
                )
                // Placed while Famio was not running: it fills the rows
                // when it is opened.
                setTextViewText(
                    R.id.widget_empty,
                    context.getString(
                        if (date == null) R.string.widget_open_famio else R.string.widget_nothing_today,
                    ),
                )
                setOnClickPendingIntent(
                    R.id.widget_root,
                    HomeWidgetLaunchIntent.getActivity(context, MainActivity::class.java),
                )
            }
            manager.updateAppWidget(id, views)
        }
    }
}
