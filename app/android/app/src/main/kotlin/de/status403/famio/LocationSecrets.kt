package de.status403.famio

import android.content.Context
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey

/** Secrets needed by the native background location service.
 *
 * Diagnostics and the enabled switch stay in ordinary preferences; the
 * bearer token, server address and certificate pin are encrypted with an
 * Android Keystore-backed key.
 */
object LocationSecrets {
    private const val PREFS = "famio_location_secrets"
    private val keys = listOf("url", "token", "pin", "device")

    fun prefs(context: Context) = EncryptedSharedPreferences.create(
        context,
        PREFS,
        MasterKey.Builder(context)
            .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
            .build(),
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
        EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
    )

    fun migrate(context: Context) {
        val plain = context.getSharedPreferences(LocationService.PREFS, Context.MODE_PRIVATE)
        val secure = prefs(context)
        val edit = secure.edit()
        var changed = false
        for (key in keys) {
            if (!secure.contains(key) && plain.contains(key)) {
                edit.putString(key, plain.getString(key, null))
                changed = true
            }
        }
        if (changed) edit.apply()
        plain.edit().apply { for (key in keys) remove(key) }.apply()
    }

    fun clear(context: Context) = prefs(context).edit().clear().apply()
}
