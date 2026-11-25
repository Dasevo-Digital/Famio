package de.status403.famio

import android.content.Context

/** Secrets needed by the native background location service.
 *
 * Diagnostics and the enabled switch stay in ordinary preferences; the
 * bearer token, server address and certificate pin are encrypted with an
 * Android Keystore-backed key (see [SecurePrefs]).
 */
object LocationSecrets {
    private const val PREFS = "famio_location_secrets"

    /** Positions not yet confirmed by the server (see [FixQueue]). */
    const val PENDING = "pending"
    private val keys = listOf("url", "token", "pin", "device")

    fun prefs(context: Context) = SecurePrefs.open(context, PREFS)

    fun migrate(context: Context) = SecurePrefs.move(
        context.getSharedPreferences(LocationService.PREFS, Context.MODE_PRIVATE),
        prefs(context),
        keys,
    )

    fun clear(context: Context) = prefs(context).edit().clear().apply()
}
