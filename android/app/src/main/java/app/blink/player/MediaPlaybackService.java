package app.blink.player;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.pm.ServiceInfo;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.media.MediaMetadata;
import android.media.session.MediaSession;
import android.media.session.PlaybackState;
import android.os.Build;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.os.SystemClock;
import androidx.core.content.ContextCompat;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * Blink in the notification shade and on the lock screen: cover, title, and the previous / play-pause / next
 * buttons, plus the headphones' and the car's buttons through the media session. While music plays it runs
 * as a foreground service, so Android doesn't put the app to sleep with the screen off.
 */
public class MediaPlaybackService extends Service {

    /** What plays now, as the page reported it. */
    static class State {
        String id = "";
        boolean playing;
        String title = "";
        String artist = "";
        String album = "";
        String art = "";
        double time;
        double duration;
    }

    private static final String CHANNEL = "playback";
    private static final int NOTIFICATION_ID = 7;
    private static final String ACT_PREV = "app.blink.player.media.PREV";
    private static final String ACT_TOGGLE = "app.blink.player.media.TOGGLE";
    private static final String ACT_NEXT = "app.blink.player.media.NEXT";
    private static final String ACT_CLOSE = "app.blink.player.media.CLOSE";
    /** After a pause the notification stays (and the app stays awake) this long, then it can be swiped away. */
    private static final long KEEP_AFTER_PAUSE_MS = 10 * 60 * 1000;

    private static final Handler main = new Handler(Looper.getMainLooper());
    private static MediaPlaybackService self;
    private static State waiting;

    private final ExecutorService io = Executors.newSingleThreadExecutor();
    private MediaSession session;
    private State state = new State();
    private Bitmap art;
    private String artFor = null;
    private boolean foreground;
    private final Runnable dropForeground = () -> {
        if (state.playing || !foreground) return;
        stopForegroundCompat(false);
        foreground = false;
        post();
    };

    private final BroadcastReceiver buttons = new BroadcastReceiver() {
        @Override
        public void onReceive(Context context, Intent intent) {
            String a = intent.getAction();
            if (ACT_PREV.equals(a)) BlinkMediaPlugin.emit("prev", 0);
            else if (ACT_NEXT.equals(a)) BlinkMediaPlugin.emit("next", 0);
            else if (ACT_TOGGLE.equals(a)) press(!state.playing);
            else if (ACT_CLOSE.equals(a)) {
                if (state.playing) BlinkMediaPlugin.emit("pause", 0);
                stopSelfNow();
            }
        }
    };

    // ---------- called from the plugin ----------

    static void push(Context ctx, State s) {
        main.post(() -> {
            if (self != null) {
                self.apply(s);
                return;
            }
            waiting = s;
            // Nothing to show until the first track actually plays (a paused track restored at launch stays quiet).
            if (!s.playing) return;
            try {
                ContextCompat.startForegroundService(ctx.getApplicationContext(), new Intent(ctx, MediaPlaybackService.class));
            } catch (Exception e) {
                // Android refuses to start it from the background: the next report from the foreground starts it.
            }
        });
    }

    static void shutdown(Context ctx) {
        main.post(() -> {
            waiting = null;
            if (self != null) self.stopSelfNow();
        });
    }

    // ---------- service ----------

    @Override
    public void onCreate() {
        super.onCreate();
        self = this;
        if (Build.VERSION.SDK_INT >= 26) {
            NotificationChannel ch = new NotificationChannel(CHANNEL, "Сейчас играет", NotificationManager.IMPORTANCE_LOW);
            ch.setDescription("Трек и кнопки управления, пока играет музыка");
            ch.setShowBadge(false);
            ch.setSound(null, null);
            ch.enableVibration(false);
            nm().createNotificationChannel(ch);
        }
        session = new MediaSession(this, "Blink");
        session.setCallback(
            new MediaSession.Callback() {
                @Override
                public void onPlay() {
                    press(true);
                }

                @Override
                public void onPause() {
                    press(false);
                }

                @Override
                public void onStop() {
                    press(false);
                }

                @Override
                public void onSkipToNext() {
                    BlinkMediaPlugin.emit("next", 0);
                }

                @Override
                public void onSkipToPrevious() {
                    BlinkMediaPlugin.emit("prev", 0);
                }

                @Override
                public void onSeekTo(long pos) {
                    state.time = pos / 1000.0;
                    updateSession();
                    BlinkMediaPlugin.emit("seek", pos / 1000.0);
                }
            }
        );
        session.setSessionActivity(openApp());
        session.setActive(true);
        IntentFilter f = new IntentFilter();
        f.addAction(ACT_PREV);
        f.addAction(ACT_TOGGLE);
        f.addAction(ACT_NEXT);
        f.addAction(ACT_CLOSE);
        ContextCompat.registerReceiver(this, buttons, f, ContextCompat.RECEIVER_NOT_EXPORTED);
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        State s = waiting != null ? waiting : state;
        waiting = null;
        // Started with startForegroundService: Android wants the notification right away.
        state = s;
        updateSession();
        goForeground(build());
        loadArt();
        return START_NOT_STICKY;
    }

    @Override
    public void onTaskRemoved(Intent rootIntent) {
        // Swiped out of recent apps: the page and its music are gone.
        stopSelfNow();
        super.onTaskRemoved(rootIntent);
    }

    @Override
    public void onDestroy() {
        main.removeCallbacks(dropForeground);
        try {
            unregisterReceiver(buttons);
        } catch (Exception ignored) {}
        if (session != null) {
            session.setActive(false);
            session.release();
        }
        io.shutdownNow();
        if (self == this) self = null;
        super.onDestroy();
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    // ---------- state ----------

    /** A button outside the app: show the new state at once, the page confirms it a moment later. */
    private void press(boolean play) {
        state.playing = play;
        updateSession();
        post();
        BlinkMediaPlugin.emit(play ? "play" : "pause", 0);
    }

    private void apply(State s) {
        boolean newArt = !s.art.equals(state.art);
        state = s;
        updateSession();
        post();
        if (newArt) loadArt();
    }

    private void updateSession() {
        long actions =
            PlaybackState.ACTION_PLAY |
            PlaybackState.ACTION_PAUSE |
            PlaybackState.ACTION_PLAY_PAUSE |
            PlaybackState.ACTION_SKIP_TO_NEXT |
            PlaybackState.ACTION_SKIP_TO_PREVIOUS |
            PlaybackState.ACTION_SEEK_TO |
            PlaybackState.ACTION_STOP;
        session.setPlaybackState(
            new PlaybackState.Builder()
                .setActions(actions)
                .setState(
                    state.playing ? PlaybackState.STATE_PLAYING : PlaybackState.STATE_PAUSED,
                    (long) (state.time * 1000),
                    state.playing ? 1f : 0f,
                    SystemClock.elapsedRealtime()
                )
                .build()
        );
        MediaMetadata.Builder m = new MediaMetadata.Builder()
            .putString(MediaMetadata.METADATA_KEY_TITLE, state.title)
            .putString(MediaMetadata.METADATA_KEY_ARTIST, state.artist)
            .putString(MediaMetadata.METADATA_KEY_ALBUM, state.album)
            .putLong(MediaMetadata.METADATA_KEY_DURATION, (long) (state.duration * 1000));
        if (art != null && state.art.equals(artFor)) m.putBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART, art);
        session.setMetadata(m.build());
    }

    private void post() {
        Notification n = build();
        if (state.playing) {
            main.removeCallbacks(dropForeground);
            goForeground(n);
        } else {
            nm().notify(NOTIFICATION_ID, n);
            main.removeCallbacks(dropForeground);
            if (foreground) main.postDelayed(dropForeground, KEEP_AFTER_PAUSE_MS);
        }
    }

    private void goForeground(Notification n) {
        try {
            if (Build.VERSION.SDK_INT >= 29) startForeground(NOTIFICATION_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK);
            else startForeground(NOTIFICATION_ID, n);
            foreground = true;
        } catch (Exception e) {
            // Not allowed from the background right now: at least keep the notification current.
            nm().notify(NOTIFICATION_ID, n);
        }
    }

    private void stopForegroundCompat(boolean remove) {
        if (Build.VERSION.SDK_INT >= 24) stopForeground(remove ? STOP_FOREGROUND_REMOVE : STOP_FOREGROUND_DETACH);
        else stopForeground(remove);
    }

    private void stopSelfNow() {
        main.removeCallbacks(dropForeground);
        stopForegroundCompat(true);
        foreground = false;
        nm().cancel(NOTIFICATION_ID);
        stopSelf();
    }

    // ---------- notification ----------

    private Notification build() {
        Notification.Builder b = Build.VERSION.SDK_INT >= 26 ? new Notification.Builder(this, CHANNEL) : new Notification.Builder(this);
        b.setSmallIcon(R.drawable.ic_stat_blink)
            .setContentTitle(state.title.isEmpty() ? "Blink" : state.title)
            .setContentText(state.artist)
            .setContentIntent(openApp())
            .setDeleteIntent(button(ACT_CLOSE, 4))
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setShowWhen(false)
            .setOnlyAlertOnce(true)
            .setOngoing(state.playing)
            .addAction(new Notification.Action.Builder(android.R.drawable.ic_media_previous, "Назад", button(ACT_PREV, 1)).build())
            .addAction(
                new Notification.Action.Builder(
                    state.playing ? android.R.drawable.ic_media_pause : android.R.drawable.ic_media_play,
                    state.playing ? "Пауза" : "Играть",
                    button(ACT_TOGGLE, 2)
                ).build()
            )
            .addAction(new Notification.Action.Builder(android.R.drawable.ic_media_next, "Дальше", button(ACT_NEXT, 3)).build())
            .setStyle(new Notification.MediaStyle().setMediaSession(session.getSessionToken()).setShowActionsInCompactView(0, 1, 2));
        if (art != null && state.art.equals(artFor)) b.setLargeIcon(art);
        if (Build.VERSION.SDK_INT >= 31) b.setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE);
        return b.build();
    }

    private PendingIntent openApp() {
        Intent i = new Intent(this, MainActivity.class).setFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP | Intent.FLAG_ACTIVITY_REORDER_TO_FRONT);
        return PendingIntent.getActivity(this, 0, i, PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
    }

    private PendingIntent button(String action, int code) {
        Intent i = new Intent(action).setPackage(getPackageName());
        return PendingIntent.getBroadcast(this, code, i, PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
    }

    private NotificationManager nm() {
        return (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
    }

    // ---------- cover ----------

    private void loadArt() {
        final String url = state.art;
        if (url.equals(artFor) && art != null) return;
        if (url.isEmpty()) {
            art = BitmapFactory.decodeResource(getResources(), R.mipmap.ic_launcher);
            artFor = url;
            updateSession();
            post();
            return;
        }
        io.execute(() -> {
            Bitmap bmp = fetch(url);
            main.post(() -> {
                if (!url.equals(state.art)) return; // the track changed meanwhile
                art = bmp != null ? bmp : BitmapFactory.decodeResource(getResources(), R.mipmap.ic_launcher);
                artFor = url;
                updateSession();
                post();
            });
        });
    }

    private static Bitmap fetch(String url) {
        HttpURLConnection c = null;
        try {
            if (url.startsWith("data:")) {
                int comma = url.indexOf(',');
                byte[] bytes = android.util.Base64.decode(url.substring(comma + 1), android.util.Base64.DEFAULT);
                return scale(BitmapFactory.decodeByteArray(bytes, 0, bytes.length));
            }
            c = (HttpURLConnection) new URL(url).openConnection();
            c.setConnectTimeout(8000);
            c.setReadTimeout(10000);
            c.setRequestProperty("User-Agent", "Blink/1.0 (desktop music player)");
            try (InputStream in = c.getInputStream()) {
                return scale(BitmapFactory.decodeStream(in));
            }
        } catch (Exception e) {
            return null;
        } finally {
            if (c != null) c.disconnect();
        }
    }

    private static Bitmap scale(Bitmap b) {
        if (b == null) return null;
        int max = 640;
        int w = b.getWidth(), h = b.getHeight();
        if (w <= max && h <= max) return b;
        float k = (float) max / Math.max(w, h);
        return Bitmap.createScaledBitmap(b, Math.round(w * k), Math.round(h * k), true);
    }
}
