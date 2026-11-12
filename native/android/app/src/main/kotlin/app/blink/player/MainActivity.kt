package app.blink.player

import android.Manifest
import android.content.pm.PackageManager
import android.content.Intent
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat
import app.blink.core.social.FriendsApi
import app.blink.core.social.RoomSession
import app.blink.player.ui.BlinkRoot
import kotlinx.coroutines.launch

class MainActivity : ComponentActivity() {
    private val graph: Graph get() = (application as BlinkApp).graph

    private val notificationPermission = registerForActivityResult(ActivityResultContracts.RequestPermission()) { }

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge(
            statusBarStyle = SystemBarStyle.dark(android.graphics.Color.TRANSPARENT),
            navigationBarStyle = SystemBarStyle.dark(android.graphics.Color.TRANSPARENT),
        )
        super.onCreate(savedInstanceState)
        setContent { BlinkRoot(graph, onDownloadsStarted = ::askNotificationsOnce) }
        handleLink(intent)
    }

    // Сайт вернул пользователя по blink://auth: activity уже открыта (singleTask), ссылка приходит сюда.
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleLink(intent)
    }

    private fun handleLink(intent: Intent?) {
        val data = intent?.data ?: return
        val url = data.toString()
        if (data.scheme == "blink") return graph.finishSignIn(url)
        RoomSession.codeFrom(url)?.let { code ->
            if (graph.auth.session.value == null) {
                graph.toasts.show("Войдите, чтобы слушать вместе")
                graph.nav.go(Tab.Account)
            } else {
                graph.room.join(code)
                graph.nav.open(Overlay.Room)
            }
            return
        }
        FriendsApi.codeFrom(url)?.let { code ->
            graph.nav.open(Overlay.Friends)
            graph.scope.launch { graph.friends.accept(code) }
        }
    }

    // Пульт к плееру живёт, пока приложение на экране; сама музыка играет в сервисе и без него.
    override fun onStart() {
        super.onStart()
        graph.player.connect()
        // Вернулись из браузера после оплаты: подписка могла появиться.
        if (graph.auth.session.value != null) graph.scope.launch { graph.plus.refresh() }
    }

    override fun onStop() {
        graph.player.disconnect()
        super.onStop()
    }

    /** Разрешение на уведомления просим не при запуске, а когда загрузка действительно началась (и один раз). */
    private fun askNotificationsOnce() {
        if (Build.VERSION.SDK_INT < 33) return
        val prefs = graph.prefs
        if (prefs.getBoolean(ASKED_NOTIFICATIONS, false)) return
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) return
        prefs.edit().putBoolean(ASKED_NOTIFICATIONS, true).apply()
        notificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
    }

    private companion object {
        const val ASKED_NOTIFICATIONS = "asked_notifications"
    }
}
