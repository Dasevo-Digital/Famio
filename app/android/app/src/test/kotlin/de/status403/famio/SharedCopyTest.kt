package de.status403.famio

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.InputStream
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SharedCopyTest {
    /** Endless, and counts how much was read from it. */
    private class Endless : InputStream() {
        var read = 0L
        override fun read(): Int {
            read++
            return 65
        }
        override fun read(b: ByteArray, off: Int, len: Int): Int {
            b.fill(65, off, off + len)
            read += len
            return len
        }
    }

    @Test
    fun copiesUpToTheLimit() {
        val out = ByteArrayOutputStream()
        assertEquals(10L, SharedCopy.copyAtMost(ByteArrayInputStream(ByteArray(10)), out, 10))
        assertEquals(10, out.size())
    }

    @Test
    fun stopsReadingBeyondTheLimit() {
        val input = Endless()
        val out = ByteArrayOutputStream()
        assertNull(SharedCopy.copyAtMost(input, out, 100_000))
        assertTrue(out.size() <= 100_000)
        // Not the whole (endless) stream, only a little more than the limit.
        assertTrue(input.read < 100_000 + 2 * 64 * 1024)
    }

    @Test
    fun leavesNoPartialFile() {
        val dir = File.createTempFile("shared", "").apply { delete(); mkdirs() }
        try {
            val big = File(dir, "big")
            assertFalse(SharedCopy.copyToFile(Endless(), big, 1000))
            assertFalse(big.exists())
            val empty = File(dir, "empty")
            assertFalse(SharedCopy.copyToFile(ByteArrayInputStream(ByteArray(0)), empty, 1000))
            assertFalse(empty.exists())
            val small = File(dir, "small")
            assertTrue(SharedCopy.copyToFile(ByteArrayInputStream(ByteArray(5) { 7 }), small, 1000))
            assertEquals(5L, small.length())
        } finally {
            dir.deleteRecursively()
        }
    }

    @Test
    fun onlyContentFromOtherApps() {
        val own = "de.status403.famio"
        assertTrue(SharedCopy.fromOtherApp("content", "com.example.files", own))
        assertTrue(SharedCopy.fromOtherApp("content", null, own))
        assertFalse(SharedCopy.fromOtherApp("content", own, own))
        assertFalse(SharedCopy.fromOtherApp("file", null, own))
        assertFalse(SharedCopy.fromOtherApp(null, null, own))
    }
}
