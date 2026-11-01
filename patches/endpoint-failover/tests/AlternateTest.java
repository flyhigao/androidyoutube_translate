package app.yydarlinker.deepseekcaptions;
import java.lang.reflect.Method;
public class AlternateTest {
    public static void main(String[] args) throws Exception {
        Method m = DeepSeekConfig.class.getDeclaredMethod("alternate", String.class);
        m.setAccessible(true);
        String a = "https://airoute.codet.net/a2bxj5/v1/plain/chat/completions";
        String b = "http://172.20.16.249:8787/a2bxj5/v1/plain/chat/completions";
        String c = "http://192.168.2.97:8787/a2bxj5/v1/plain/chat/completions";
        System.out.println(a + " -> " + m.invoke(null, a));
        System.out.println(b + " -> " + m.invoke(null, b));
        System.out.println(c + " -> " + m.invoke(null, c));
    }
}
