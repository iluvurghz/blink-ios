package app.blink.player.data

import android.content.SharedPreferences
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import app.blink.core.net.KeyValue
import app.blink.core.net.SessionStore
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** SharedPreferences как простое хранилище строк для ядра. */
class PrefsKeyValue(private val prefs: SharedPreferences) : KeyValue {
    override fun get(key: String): String? = prefs.getString(key, null)

    override fun put(key: String, value: String?) {
        prefs.edit().apply { if (value == null) remove(key) else putString(key, value) }.apply()
    }
}

/**
 * Сессия входа лежит зашифрованной ключом из Android Keystore (AES-GCM, ключ не покидает устройство).
 * Если Keystore капризничает, откатываемся на приватные настройки приложения: лучше остаться
 * залогиненным, чем просить пароль на каждом запуске. Резервные копии у приложения выключены.
 */
class SecureSessionStore(private val prefs: SharedPreferences) : SessionStore {
    override fun load(): String? {
        val raw = prefs.getString(KEY, null) ?: return null
        return try {
            when {
                raw.startsWith(ENC) -> decrypt(raw.substring(ENC.length))
                raw.startsWith(PLAIN) -> raw.substring(PLAIN.length)
                else -> null
            }
        } catch (_: Exception) {
            null
        }
    }

    override fun save(value: String?) {
        if (value == null) {
            prefs.edit().remove(KEY).apply()
            return
        }
        val stored = try {
            ENC + encrypt(value)
        } catch (_: Exception) {
            PLAIN + value
        }
        prefs.edit().putString(KEY, stored).apply()
    }

    private fun key(): SecretKey {
        val ks = KeyStore.getInstance(PROVIDER).apply { load(null) }
        (ks.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, PROVIDER)
        gen.init(
            KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build(),
        )
        return gen.generateKey()
    }

    private fun encrypt(text: String): String {
        val cipher = Cipher.getInstance(TRANSFORM)
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val body = cipher.doFinal(text.toByteArray(Charsets.UTF_8))
        return Base64.encodeToString(cipher.iv + body, Base64.NO_WRAP)
    }

    private fun decrypt(b64: String): String {
        val all = Base64.decode(b64, Base64.NO_WRAP)
        val cipher = Cipher.getInstance(TRANSFORM)
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, all, 0, IV_BYTES))
        return String(cipher.doFinal(all, IV_BYTES, all.size - IV_BYTES), Charsets.UTF_8)
    }

    private companion object {
        const val KEY = "session"
        const val ENC = "e:"
        const val PLAIN = "p:"
        const val PROVIDER = "AndroidKeyStore"
        const val ALIAS = "blink.session.v1"
        const val TRANSFORM = "AES/GCM/NoPadding"
        const val IV_BYTES = 12
    }
}
