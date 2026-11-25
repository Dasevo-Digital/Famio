package de.status403.famio

import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.content.SharedPreferences

/**
 * The rows of "Famio heute": appointments, the meal, open tasks, shopping
 * and a sleeping child. Kept encrypted like [LocationSecrets] (the app's
 * database is encrypted too) and only while such a widget is on the home
 * screen; without one the app writes nothing.
 */
object WidgetData {
    private const val PREFS = "famio_widget"

    /** Where Famio before 2.0.63 kept the rows (home_widget, plain text). */
    private const val LEGACY = "HomeWidgetPreferences"
    const val ROWS = 5

    private val legacyKeys = listOf("date") +
        (0 until ROWS).flatMap { listOf("kind$it", "lead$it", "text$it", "line$it") }

    data class Row(val kind: String?, val lead: String?, val text: String)

    /** The "Famio heute" widgets on the home screen. */
    fun ids(context: Context): IntArray = runCatching {
        AppWidgetManager.getInstance(context)?.getAppWidgetIds(
            ComponentName(context, FamioWidgetProvider::class.java),
        )
    }.getOrNull() ?: IntArray(0)

    /** Keeps and shows the rows if a widget is there; true if one shows them. */
    fun save(context: Context, date: String, rows: List<Row>): Boolean {
        dropLegacy(legacy(context))
        val ids = ids(context)
        if (ids.isEmpty()) {
            store(context).edit().clear().apply()
            return false
        }
        write(store(context), date, rows)
        FamioWidgetProvider.show(context, ids)
        return true
    }

    /** Signed out or the last widget removed: nothing is kept. */
    fun clear(context: Context) {
        dropLegacy(legacy(context))
        runCatching { store(context).edit().clear().apply() }
        FamioWidgetProvider.show(context, ids(context))
    }

    /** The date and rows the widgets show (null: not filled yet). */
    fun read(context: Context): Pair<String?, List<Row>> = read(store(context))

    /**
     * After an update from Famio before 2.0.63: rows a widget shows move
     * into the encrypted store, the plain copy goes.
     */
    fun migrate(context: Context) {
        val legacy = legacy(context)
        if (legacyKeys.none { legacy.contains(it) }) return
        val store = store(context)
        if (ids(context).isNotEmpty() && !store.contains("date")) {
            val rows = (0 until ROWS).mapNotNull { i ->
                val text = legacy.getString("text$i", null) ?: legacy.getString("line$i", null)
                if (text.isNullOrEmpty()) {
                    null
                } else {
                    Row(legacy.getString("kind$i", null), legacy.getString("lead$i", null), text)
                }
            }
            write(store, legacy.getString("date", null) ?: "", rows, commit = true)
        }
        dropLegacy(legacy)
    }

    fun write(store: SharedPreferences, date: String, rows: List<Row>, commit: Boolean = false) {
        val edit = store.edit().clear().putString("date", date)
        rows.take(ROWS).forEachIndexed { i, row ->
            edit.putString("kind$i", row.kind)
            edit.putString("lead$i", row.lead)
            edit.putString("text$i", row.text)
        }
        if (commit) edit.commit() else edit.apply()
    }

    fun read(store: SharedPreferences): Pair<String?, List<Row>> {
        val rows = (0 until ROWS).mapNotNull { i ->
            val text = store.getString("text$i", null)
            if (text.isNullOrEmpty()) {
                null
            } else {
                Row(store.getString("kind$i", null), store.getString("lead$i", null), text)
            }
        }
        return store.getString("date", null) to rows
    }

    fun dropLegacy(legacy: SharedPreferences) {
        if (legacyKeys.none { legacy.contains(it) }) return
        legacy.edit().apply { legacyKeys.forEach { remove(it) } }.commit()
    }

    private fun store(context: Context) = SecurePrefs.open(context, PREFS)

    private fun legacy(context: Context) =
        context.getSharedPreferences(LEGACY, Context.MODE_PRIVATE)
}
