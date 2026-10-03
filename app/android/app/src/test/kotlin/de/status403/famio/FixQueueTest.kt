package de.status403.famio

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class FixQueueTest {
    private val now = 1_790_000_000_000L
    private var saved: String? = null
    private fun fix(at: Long) = JSONObject().put("lat", 53.5).put("lon", 10.0).put("at", at)
    private fun queue() = FixQueue { saved = it }

    @Test
    fun survivesARestart() {
        val q = queue()
        q.add(fix(now - 60_000), now)
        q.add(fix(now), now)
        val restored = FixQueue.restore(saved, now) { saved = it }
        assertEquals(listOf(now - 60_000, now), restored.snapshot().map { it.getLong("at") })
    }

    @Test
    fun confirmsExactlyTheSentPositions() {
        val q = queue()
        q.add(fix(now - 2), now)
        val sent = q.snapshot()
        // Measured while the upload ran: must stay.
        q.add(fix(now - 1), now)
        q.confirm(sent)
        assertEquals(listOf(now - 1), q.snapshot().map { it.getLong("at") })
        q.confirm(q.snapshot())
        assertEquals(0, q.size)
        assertNull(saved)
    }

    @Test
    fun keepsAtMostADayAndFiveHundred() {
        val q = queue()
        q.add(fix(now - FixQueue.MAX_AGE_MS - 1), now - FixQueue.MAX_AGE_MS)
        for (i in 0 until FixQueue.MAX_SIZE + 10) q.add(fix(now + i), now)
        assertEquals(FixQueue.MAX_SIZE, q.size)
        assertEquals(now + 10, q.snapshot().first().getLong("at"))

        val old = FixQueue { saved = it }
        old.add(fix(now), now)
        val tomorrow = FixQueue.restore(saved, now + FixQueue.MAX_AGE_MS + 1) { saved = it }
        assertEquals(0, tomorrow.size)
        assertNull(saved)
    }

    @Test
    fun damagedStorageStartsEmpty() {
        assertEquals(0, FixQueue.restore("{kaputt", now) { saved = it }.size)
    }
}
