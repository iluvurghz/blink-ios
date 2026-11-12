package app.blink.player;

import com.getcapacitor.JSObject;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;

/**
 * The page's side of the notification player (src/lib/capBridge.js): the page sends what plays now
 * (update), the notification, the lock screen and the headphones send their buttons back ("media" events).
 * The music itself plays in the page; MediaPlaybackService only shows it and keeps the app alive.
 */
@CapacitorPlugin(name = "BlinkMedia")
public class BlinkMediaPlugin extends Plugin {

    private static BlinkMediaPlugin instance;

    @Override
    public void load() {
        instance = this;
    }

    /** A button was pressed outside the app: play, pause, next, prev, or seek (to `time` seconds). */
    static void emit(String cmd, double time) {
        BlinkMediaPlugin p = instance;
        if (p == null) return;
        JSObject o = new JSObject();
        o.put("cmd", cmd);
        if ("seek".equals(cmd)) o.put("time", time);
        p.notifyListeners("media", o, false);
    }

    @PluginMethod
    public void update(PluginCall call) {
        MediaPlaybackService.State s = new MediaPlaybackService.State();
        s.id = call.getString("id", "");
        s.playing = Boolean.TRUE.equals(call.getBoolean("playing", false));
        s.title = call.getString("title", "");
        s.artist = call.getString("artist", "");
        s.album = call.getString("album", "");
        s.art = call.getString("art", "");
        s.time = call.getDouble("time", 0.0);
        s.duration = call.getDouble("duration", 0.0);
        MediaPlaybackService.push(getContext(), s);
        call.resolve();
    }

    @Override
    protected void handleOnDestroy() {
        // The page is gone (the app was closed): nothing plays any more, take the notification away.
        MediaPlaybackService.shutdown(getContext());
        if (instance == this) instance = null;
    }
}
