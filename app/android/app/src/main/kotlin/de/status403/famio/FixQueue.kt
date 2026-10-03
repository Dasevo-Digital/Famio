package de.status403.famio

import org.json.JSONArray
import org.json.JSONObject
import java.util.Collections
import java.util.IdentityHashMap

/**
 * Positions the server has not confirmed yet. Every change goes to [persist]
 * (the service keeps them encrypted next to the token, see
 * [LocationSecrets]), so they survive a restart of the service – for at
 * most [MAX_AGE_MS] and [MAX_SIZE] positions, as on iOS.
 */
internal class FixQueue(private val persist: (String?) -> Unit) {
    companion object {
        const val MAX_SIZE = 500
        const val MAX_AGE_MS = 24 * 60 * 60_000L

        /** The queue saved as [stored], without positions too old to matter. */
        fun restore(stored: String?, now: Long, persist: (String?) -> Unit): FixQueue {
            val queue = FixQueue(persist)
            if (stored != null) {
                try {
                    val array = JSONArray(stored)
                    for (i in 0 until array.length()) queue.items.add(array.getJSONObject(i))
                } catch (e: Exception) {
                    // Unreadable: start empty rather than not at all.
                    queue.items.clear()
                }
            }
            if (queue.prune(now)) queue.save()
            return queue
        }
    }

    private val items = ArrayList<JSONObject>()

    @Synchronized
    fun add(fix: JSONObject, now: Long) {
        items.add(fix)
        prune(now)
        save()
    }

    /** The positions to send now. */
    @Synchronized
    fun snapshot(): List<JSONObject> = ArrayList(items)

    /**
     * The server confirmed [sent]: exactly those leave the queue, not ones
     * measured while the upload ran.
     */
    @Synchronized
    fun confirm(sent: List<JSONObject>) {
        if (sent.isEmpty()) return
        val done = Collections.newSetFromMap(IdentityHashMap<JSONObject, Boolean>())
        done.addAll(sent)
        if (items.removeAll { it in done }) save()
    }

    @get:Synchronized
    val size: Int get() = items.size

    /** Drops positions older than a day and the oldest beyond [MAX_SIZE]. */
    private fun prune(now: Long): Boolean {
        val before = items.size
        items.removeAll { now - it.optLong("at", 0L) > MAX_AGE_MS }
        while (items.size > MAX_SIZE) items.removeAt(0)
        return items.size != before
    }

    private fun save() = persist(if (items.isEmpty()) null else JSONArray(items).toString())
}
