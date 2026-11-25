package de.status403.famio

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The rows of "Famio heute" in the widget's own store (#607). */
class WidgetDataTest {
    @Test
    fun writesAndReadsTheRows() {
        val store = FakePrefs()
        WidgetData.write(
            store,
            "Mi., 25. Nov.",
            listOf(
                WidgetData.Row("event", "17:30", "Fußballtraining"),
                WidgetData.Row("sleep", "🌙", "Emil schläft seit 14:30"),
            ),
        )
        val (date, rows) = WidgetData.read(store)
        assertEquals("Mi., 25. Nov.", date)
        assertEquals(
            listOf(
                WidgetData.Row("event", "17:30", "Fußballtraining"),
                WidgetData.Row("sleep", "🌙", "Emil schläft seit 14:30"),
            ),
            rows,
        )
    }

    @Test
    fun fewerRowsLeaveNoneBehind() {
        val store = FakePrefs()
        WidgetData.write(store, "Mo.", (1..5).map { WidgetData.Row("event", null, "Termin $it") })
        WidgetData.write(store, "Di.", listOf(WidgetData.Row("meal", "🍽", "Pizza")))
        val (date, rows) = WidgetData.read(store)
        assertEquals("Di.", date)
        assertEquals(listOf(WidgetData.Row("meal", "🍽", "Pizza")), rows)
        assertNull(store.getString("text4", null))
    }

    @Test
    fun atMostFiveRows() {
        val store = FakePrefs()
        WidgetData.write(store, "Mo.", (1..7).map { WidgetData.Row("event", null, "Termin $it") })
        assertEquals(5, WidgetData.read(store).second.size)
    }

    @Test
    fun notFilledYet() {
        assertEquals(null to emptyList<WidgetData.Row>(), WidgetData.read(FakePrefs()))
    }

    @Test
    fun thePlainCopyOfAnOlderFamioGoes() {
        // home_widget's preferences as Famio 2.0.62 wrote them.
        val legacy = FakePrefs(
            mapOf(
                "date" to "Mi., 25. Nov.",
                "kind0" to "sleep",
                "lead0" to "🌙",
                "text0" to "Emil schläft seit 14:30",
                "line1" to "🍽 Pfannkuchen",
                // Not ours: stays.
                "flutter.other" to "x",
            ),
        )
        WidgetData.dropLegacy(legacy)
        assertEquals(mapOf<String, Any?>("flutter.other" to "x"), legacy.values)
        WidgetData.dropLegacy(legacy)
        assertTrue(legacy.contains("flutter.other"))
    }
}
