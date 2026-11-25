package de.status403.famio

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The token of the own push and of location sharing leave plain text. */
class SecurePrefsTest {
    @Test
    fun movesTheSecretsAndKeepsTheSwitches() {
        // As Famio 2.0.62 left them in famio_notify.
        val plain = FakePrefs(
            mapOf(
                "enabled" to true,
                "details" to false,
                "last" to 42L,
                "url" to "https://famio.example.de/",
                "token" to "notify-token",
                "pin" to "AB:CD",
            ),
        )
        val secure = FakePrefs()
        SecurePrefs.move(plain, secure, listOf("url", "token", "pin"))
        assertEquals("notify-token", secure.getString("token", null))
        assertEquals("https://famio.example.de/", secure.getString("url", null))
        assertEquals("AB:CD", secure.getString("pin", null))
        assertFalse(plain.contains("token"))
        assertFalse(plain.contains("url"))
        assertFalse(plain.contains("pin"))
        assertTrue(plain.getBoolean("enabled", false))
        assertEquals(42L, plain.getLong("last", -1))
    }

    @Test
    fun aNewerSecretIsNotOverwritten() {
        val plain = FakePrefs(mapOf("token" to "old"))
        val secure = FakePrefs(mapOf("token" to "new"))
        SecurePrefs.move(plain, secure, listOf("token"))
        assertEquals("new", secure.getString("token", null))
        assertFalse(plain.contains("token"))
    }

    @Test
    fun nothingToMove() {
        val plain = FakePrefs(mapOf("enabled" to true))
        val secure = FakePrefs()
        SecurePrefs.move(plain, secure, listOf("url", "token", "pin"))
        assertTrue(secure.values.isEmpty())
        assertEquals(mapOf<String, Any?>("enabled" to true), plain.values)
    }
}
