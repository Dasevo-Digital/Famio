package de.status403.famio

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey

/**
 * Preferences encrypted with an Android Keystore-backed key, for what the
 * native parts keep outside the app's encrypted database: server access of
 * the background services and the rows of the home screen widget.
 */
object SecurePrefs {
    private val open = HashMap<String, SharedPreferences>()

    @Synchronized
    fun open(context: Context, name: String): SharedPreferences =
        open.getOrPut(name) {
            val app = context.applicationContext
            EncryptedSharedPreferences.create(
                app,
                name,
                MasterKey.Builder(app)
                    .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
                    .build(),
                EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
            )
        }

    /**
     * Moves the text values [keys] from [plain] (written by an older Famio)
     * to [secure], unless [secure] has them already, and removes them from
     * [plain] – only after [secure] has them on disk.
     */
    fun move(plain: SharedPreferences, secure: SharedPreferences, keys: Collection<String>) {
        val found = keys.filter { plain.contains(it) }
        if (found.isEmpty()) return
        val edit = secure.edit()
        var changed = false
        for (key in found) {
            if (!secure.contains(key)) {
                edit.putString(key, plain.getString(key, null))
                changed = true
            }
        }
        if (changed) edit.commit()
        plain.edit().apply { found.forEach { remove(it) } }.commit()
    }
}
