package app.blink.player

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat
import app.blink.player.ui.BlinkRoot

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
    }

    // Пульт к плееру живёт, пока приложение на экране; сама музыка играет в сервисе и без него.
    override fun onStart() {
        super.onStart()
        graph.player.connect()
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
