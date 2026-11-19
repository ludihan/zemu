package dev.zemu.libretro;

import org.libsdl.app.SDLActivity;

import java.io.BufferedInputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;

public class ZemuActivity extends SDLActivity {
    @Override
    protected String[] getLibraries() {
        return new String[] { "SDL3", "main" };
    }

    /**
     * Called from native code. Downloads url to dest on a background thread,
     * then creates dest + ".ok" or dest + ".err" so the native side can poll.
     */
    public static void download(final String url, final String dest) {
        new Thread(() -> {
            boolean ok = false;
            try {
                String u = url;
                for (int redirects = 0; redirects < 5 && !ok; redirects++) {
                    HttpURLConnection c = (HttpURLConnection) new URL(u).openConnection();
                    c.setConnectTimeout(20000);
                    c.setReadTimeout(30000);
                    c.setInstanceFollowRedirects(true);
                    int code = c.getResponseCode();
                    if (code >= 300 && code < 400) {
                        u = c.getHeaderField("Location");
                        c.disconnect();
                        continue;
                    }
                    if (code != 200) {
                        c.disconnect();
                        break;
                    }
                    try (InputStream in = new BufferedInputStream(c.getInputStream());
                         OutputStream out = new FileOutputStream(dest)) {
                        byte[] buf = new byte[65536];
                        int n;
                        while ((n = in.read(buf)) > 0) {
                            out.write(buf, 0, n);
                        }
                    }
                    c.disconnect();
                    ok = true;
                }
            } catch (Exception e) {
                ok = false;
            }
            try {
                new File(dest + (ok ? ".ok" : ".err")).createNewFile();
            } catch (IOException e) {
                // Nothing to report to; the native side times out on its own.
            }
        }, "zemu-download").start();
    }
}
