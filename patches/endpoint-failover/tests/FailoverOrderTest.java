package app.yydarlinker.deepseekcaptions;

import java.lang.reflect.Method;
import java.util.List;

public class FailoverOrderTest {
    static String names(Object list) throws Exception {
        StringBuilder out = new StringBuilder();
        for (Object t : (java.util.List<?>) list) {
            java.lang.reflect.Field f = t.getClass().getDeclaredField("baseUrl");
            f.setAccessible(true);
            if (out.length() > 0) out.append(" -> ");
            out.append(f.get(t));
        }
        return out.toString();
    }
    public static void main(String[] args) throws Exception {
        TranslationSettings lan = new TranslationSettings(true,
                "http://192.168.2.97:8787/a2bxj5/v1/plain/chat/completions", "hy7b", "p", "k", "stored_custom",
                "https://airoute.codet.net/a2bxj5/v1/plain/chat/completions", "k", "hy7b", true);
        TranslationSettings cell = new TranslationSettings(true,
                "http://192.168.2.97:8787/a2bxj5/v1/plain/chat/completions", "hy7b", "p", "k", "stored_custom",
                "https://airoute.codet.net/a2bxj5/v1/plain/chat/completions", "k", "hy7b", false);
        Method m = RebuildApi.class.getDeclaredMethod("targets", TranslationSettings.class);
        m.setAccessible(true);
        System.out.println("wifi first=" + names(m.invoke(null, lan)));
        System.out.println("cell first=" + names(m.invoke(null, cell)));
        TranslationSettings remote = new TranslationSettings(true,
                "https://airoute.codet.net/a2bxj5/v1/plain/chat/completions", "hy7b", "p", "k", "stored_custom",
                "http://192.168.2.97:8787/a2bxj5/v1/plain/chat/completions", "k", "hy7b", true);
        System.out.println("remote+wifi first=" + names(m.invoke(null, remote)));
        System.out.println("remote+cell first=" + names(m.invoke(null, new TranslationSettings(true,
                "https://airoute.codet.net/a2bxj5/v1/plain/chat/completions", "hy7b", "p", "k", "stored_custom",
                "http://192.168.2.97:8787/a2bxj5/v1/plain/chat/completions", "k", "hy7b", false))));
        TranslationSettings single = new TranslationSettings(true, "http://192.168.2.97:8787/v1", "hy7b", "p", "k", "x");
        System.out.println("single=" + names(m.invoke(null, single)));
    }
}
