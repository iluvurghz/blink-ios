package app.blink.player.data

import android.content.SharedPreferences
import app.blink.core.wave.BlobStore

/** Небольшой JSON-файл ядра (состояние Вспышки, лайки) в приватных настройках приложения. */
class PrefsBlob(private val prefs: SharedPreferences, private val key: String) : BlobStore {
    override fun load(): String? = prefs.getString(key, null)

    override fun save(value: String?) {
        prefs.edit().apply { if (value == null) remove(key) else putString(key, value) }.apply()
    }
}
