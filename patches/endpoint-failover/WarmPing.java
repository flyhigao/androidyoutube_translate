package app.yydarlinker.deepseekcaptions;

import android.content.Context;

import java.net.HttpURLConnection;
import java.net.URL;

/**
 * Best-effort prewarm of the current video's whole-track cache. It follows the same LAN/public
 * endpoint preference as the translation requests, so it does not warm the wrong host after a
 * network switch. Every failure is silent: prewarming must never disturb playback.
 */
final class WarmPing {
    private WarmPing() {}

    static void ping(Context context, String videoId) {
        try {
            if (context == null || videoId == null || videoId.isEmpty()) return;
            String base = DeepSeekConfig.preferredBaseUrl(context);
            if (base == null || base.isEmpty()) return;
            String url =
                    base.replace("/v1/plain/chat/completions", "/yt/warm")
                            .replace("/v1/chat/completions", "/yt/warm");
            if (!url.contains("/yt/warm")) return;
            if (url.indexOf('?') < 0) url += "?v=" + videoId;
            else url += "&v=" + videoId;
            final String target = url;
            Thread thread =
                    new Thread(
                            () -> {
                                HttpURLConnection connection = null;
                                try {
                                    connection = (HttpURLConnection) new URL(target).openConnection();
                                    connection.setConnectTimeout(3000);
                                    connection.setReadTimeout(5000);
                                    connection.setUseCaches(false);
                                    connection.setRequestMethod("GET");
                                    connection.getResponseCode();
                                } catch (Exception ignored) {
                                    // Prewarming is optional.
                                } finally {
                                    if (connection != null) connection.disconnect();
                                }
                            },
                            "CaptionWarmPing");
            thread.setDaemon(true);
            thread.start();
        } catch (Throwable ignored) {
            // A broken extension must never stop YouTube from starting.
        }
    }
}
