package de.status403.famio

import android.content.Context

/**
 * Server address, certificate pin and token of [NotifyService], encrypted
 * like [LocationSecrets]. The token can only fetch the member's
 * notifications, but it can do so until it is revoked. The switches
 * ("enabled", "details") and the position ("last") stay in
 * [NotifyService.PREFS].
 */
object NotifySecrets {
    private const val PREFS = "famio_notify_secrets"
    private val keys = listOf("url", "token", "pin")

    fun prefs(context: Context) = SecurePrefs.open(context, PREFS)

    /** Famio before 2.0.63 kept them in plain text. */
    fun migrate(context: Context) = SecurePrefs.move(
        context.getSharedPreferences(NotifyService.PREFS, Context.MODE_PRIVATE),
        prefs(context),
        keys,
    )

    fun clear(context: Context) = prefs(context).edit().clear().apply()
}
