package app.blink.player.data

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Handler
import android.os.Looper
import app.blink.core.offline.NetworkMonitor
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Есть ли интернет. Смотрим на основную сеть системы. Проверка «пустая ли Wi-Fi» не нужна:
 * загрузчик и так повторяет запросы, а лишние «нет сети» хуже.
 */
class AndroidNetwork(context: Context) : NetworkMonitor {
    private val cm: ConnectivityManager = context.getSystemService(ConnectivityManager::class.java)
    private val handler = Handler(Looper.getMainLooper())
    private val flow = MutableStateFlow(check())
    override val online: StateFlow<Boolean> = flow.asStateFlow()

    private fun check(): Boolean {
        val network = cm.activeNetwork ?: return false
        val caps = cm.getNetworkCapabilities(network) ?: return false
        return caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
    }

    init {
        try {
            cm.registerDefaultNetworkCallback(
                object : ConnectivityManager.NetworkCallback() {
                    override fun onAvailable(network: Network) {
                        flow.value = true
                    }

                    override fun onCapabilitiesChanged(network: Network, networkCapabilities: NetworkCapabilities) {
                        flow.value = networkCapabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                    }

                    // Wi-Fi → мобильная сеть даёт короткое «потеряно, появилось»: ждём и смотрим, что осталось.
                    override fun onLost(network: Network) {
                        handler.postDelayed({ flow.value = check() }, LOST_GRACE_MS)
                    }
                },
            )
        } catch (_: Exception) {
            // Без подписки на события остаётся стартовое значение: загрузчик сам повторит запросы.
        }
    }

    private companion object {
        const val LOST_GRACE_MS = 1500L
    }
}
