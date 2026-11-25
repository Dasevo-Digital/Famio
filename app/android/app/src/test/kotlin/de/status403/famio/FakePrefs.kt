package de.status403.famio

import android.content.SharedPreferences

/** SharedPreferences in memory: android.jar has only stubs in unit tests. */
class FakePrefs(initial: Map<String, Any?> = emptyMap()) : SharedPreferences {
    val values = HashMap(initial)

    override fun getAll(): MutableMap<String, *> = HashMap(values)
    override fun getString(key: String, defValue: String?) = values[key] as String? ?: defValue
    override fun getStringSet(key: String, defValues: MutableSet<String>?) = defValues
    override fun getInt(key: String, defValue: Int) = values[key] as Int? ?: defValue
    override fun getLong(key: String, defValue: Long) = values[key] as Long? ?: defValue
    override fun getFloat(key: String, defValue: Float) = values[key] as Float? ?: defValue
    override fun getBoolean(key: String, defValue: Boolean) = values[key] as Boolean? ?: defValue
    override fun contains(key: String) = values.containsKey(key)
    override fun registerOnSharedPreferenceChangeListener(l: SharedPreferences.OnSharedPreferenceChangeListener) {}
    override fun unregisterOnSharedPreferenceChangeListener(l: SharedPreferences.OnSharedPreferenceChangeListener) {}

    override fun edit(): SharedPreferences.Editor = object : SharedPreferences.Editor {
        private val put = HashMap<String, Any?>()
        private val removed = HashSet<String>()
        private var clear = false

        private fun set(key: String, value: Any?) = apply {
            if (value == null) removed.add(key) else put[key] = value
        }

        override fun putString(key: String, value: String?) = set(key, value)
        override fun putStringSet(key: String, values: MutableSet<String>?) = set(key, values)
        override fun putInt(key: String, value: Int) = set(key, value)
        override fun putLong(key: String, value: Long) = set(key, value)
        override fun putFloat(key: String, value: Float) = set(key, value)
        override fun putBoolean(key: String, value: Boolean) = set(key, value)
        override fun remove(key: String) = apply { removed.add(key) }
        override fun clear() = apply { clear = true }

        override fun commit(): Boolean {
            if (clear) values.clear()
            removed.forEach { values.remove(it) }
            values.putAll(put)
            return true
        }

        override fun apply() {
            commit()
        }
    }
}
