package app.blink.player.offline

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import app.blink.core.offline.OfflineState
import app.blink.core.ui.Format
import app.blink.player.BlinkApp
import app.blink.player.MainActivity
import app.blink.player.R
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

/**
 * Пока что-то качается, держим сервис переднего плана с уведомлением (система не убивает процесс, когда экран выключен).
 * Сам скачивает OfflineManager в процессе приложения, сервис лишь показывает прогресс и кнопки «Пауза» и «Отменить».
 * Когда очередь пустеет, сервис гасится сам.
 */
class DownloadService : Service() {
    private var watcher: Job? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val graph = (application as BlinkApp).graph
        when (intent?.action) {
            ACTION_PAUSE -> graph.offline.pause()
            ACTION_RESUME -> graph.offline.resume()
            ACTION_CANCEL -> graph.offline.cancelAll()
        }
        ensureChannel()
        ServiceCompat.startForeground(
            this,
            NOTIFICATION_ID,
            notification(graph.offline.state.value),
            ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
        )
        if (watcher == null) {
            watcher = graph.scope.launch {
                graph.offline.state.collect { st ->
                    if (st.active) {
                        getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, notification(st))
                    } else {
                        stopForeground(STOP_FOREGROUND_REMOVE)
                        stopSelf()
                    }
                }
            }
        }
        return START_NOT_STICKY
    }

    // Android 15 ограничивает такие сервисы шестью часами: честно останавливаемся, очередь продолжится при следующем запуске.
    override fun onTimeout(startId: Int, fgsType: Int) {
        stopSelf()
    }

    override fun onDestroy() {
        watcher?.cancel()
        watcher = null
        super.onDestroy()
    }

    private fun ensureChannel() {
        val nm = getSystemService(NotificationManager::class.java)
        if (nm.getNotificationChannel(CHANNEL_ID) == null) {
            nm.createNotificationChannel(NotificationChannel(CHANNEL_ID, "Загрузки", NotificationManager.IMPORTANCE_LOW))
        }
    }

    private fun notification(st: OfflineState): Notification {
        val running = st.jobs.filter { !it.failed }
        val fraction = if (running.isEmpty()) 0f else running.map { it.fraction }.average().toFloat()
        val known = running.any { it.total != null }
        val title = if (st.paused) "Загрузки на паузе" else "Сохраняем для офлайна"
        val text = Format.tracks(running.size) + (if (!st.online) " · ждём интернет" else "")
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_download)
            .setContentTitle(title)
            .setContentText(text)
            .setProgress(100, (fraction * 100).toInt(), !known)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setContentIntent(open)
            .addAction(0, if (st.paused) "Продолжить" else "Пауза", action(if (st.paused) ACTION_RESUME else ACTION_PAUSE))
            .addAction(0, "Отменить", action(ACTION_CANCEL))
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .build()
    }

    private fun action(name: String): PendingIntent =
        PendingIntent.getService(
            this,
            name.hashCode(),
            Intent(this, DownloadService::class.java).setAction(name),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

    companion object {
        private const val CHANNEL_ID = "downloads"
        private const val NOTIFICATION_ID = 17
        private const val ACTION_PAUSE = "app.blink.player.PAUSE"
        private const val ACTION_RESUME = "app.blink.player.RESUME"
        private const val ACTION_CANCEL = "app.blink.player.CANCEL"

        fun start(context: Context) {
            try {
                ContextCompat.startForegroundService(context, Intent(context, DownloadService::class.java))
            } catch (_: Exception) {
                // Из фона Android 12+ запрещает запускать такие сервисы: загрузка всё равно идёт, пока жив процесс.
            }
        }
    }
}
