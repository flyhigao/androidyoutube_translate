package app.yydarlinker.deepseekcaptions;

import com.sun.net.httpserver.HttpServer;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.net.InetSocketAddress;
import java.util.concurrent.atomic.AtomicInteger;

public class FailoverBothFailTest {
    static HttpServer server(int status, AtomicInteger hits) throws Exception {
        HttpServer s = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        s.createContext("/", ex -> {
            hits.incrementAndGet();
            byte[] body = "{}".getBytes();
            ex.sendResponseHeaders(status, body.length);
            ex.getResponseBody().write(body);
            ex.close();
        });
        s.start();
        return s;
    }
    public static void main(String[] args) throws Exception {
        AtomicInteger p = new AtomicInteger();
        HttpServer primary = server(404, p);
        int pp = primary.getAddress().getPort();
        int dead = 1; // nothing listens here
        TranslationSettings cfg = new TranslationSettings(true,
                "http://127.0.0.1:" + pp + "/v1", "hy7b", "p", "k", "stored_custom",
                "http://127.0.0.1:" + dead + "/v1", "k", "hy7b", true);
        org.json.JSONObject request = new org.json.JSONObject(); request.put("model","hy7b");
        Method m = RebuildApi.class.getDeclaredMethod("sendWithFailover",
                TranslationSettings.class, org.json.JSONObject.class, String.class,
                DeepSeekApiClient.RequestControl.class, long.class, RebuildStream.Reader.class);
        m.setAccessible(true);
        Object response = m.invoke(null, cfg, request, request.toString(), null,
                System.nanoTime() + 5_000_000_000L, null);
        Field status = response.getClass().getDeclaredField("status"); status.setAccessible(true);
        System.out.println("first status=" + status.get(response) + " primary_hits=" + p.get());
        Object second = m.invoke(null, cfg, request, request.toString(), null,
                System.nanoTime() + 5_000_000_000L, null);
        System.out.println("second status=" + status.get(second) + " primary_hits=" + p.get());
        primary.stop(0);
        if ((int) status.get(response) != 404 || (int) status.get(second) != 404 || p.get() != 2) System.exit(1);
    }
}
