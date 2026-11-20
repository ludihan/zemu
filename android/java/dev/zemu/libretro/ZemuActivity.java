package dev.zemu.libretro;

import org.libsdl.app.SDLActivity;
import org.libsdl.app.SDLSurface;

import android.content.Context;
import android.graphics.Insets;
import android.os.Build;
import android.view.DisplayCutout;
import android.os.Bundle;
import android.view.View;
import android.view.Window;
import android.view.WindowInsets;
import android.view.WindowInsetsController;

import android.database.Cursor;
import android.net.Uri;
import android.provider.OpenableColumns;

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

    // Layout flags kept on all the time so the bars never resize our surface.
    private static final int LAYOUT_FLAGS = View.SYSTEM_UI_FLAG_LAYOUT_STABLE
            | View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN | View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION;
    private static final int IMMERSIVE_FLAGS = View.SYSTEM_UI_FLAG_FULLSCREEN
            | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION | View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY;

    private static volatile boolean sImmersive;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        // Draw edge to edge from the start: the GUI keeps clear of the bars
        // using the insets, and hiding them later won't resize the surface.
        applyBars();
    }

    @Override
    public void onWindowFocusChanged(boolean hasFocus) {
        super.onWindowFocusChanged(hasFocus);
        if (hasFocus) {
            applyBars(); // dialogs and the shade can bring the bars back
        }
    }

    /**
     * Called from native code: hide the status and navigation bars while a
     * game is playing (a swipe from the edge shows them for a moment), show
     * them in the menus. Unlike SDL's fullscreen this never resizes the
     * surface, which could leave the renderer drawing to a stale one.
     */
    public static void setGameBars(boolean immersive) {
        sImmersive = immersive;
        final SDLActivity a = (SDLActivity) mSingleton;
        if (a != null) {
            a.runOnUiThread(() -> ((ZemuActivity) a).applyBars());
        }
    }

    private void applyBars() {
        Window w = getWindow();
        if (w == null) {
            return;
        }
        if (Build.VERSION.SDK_INT >= 30 /* Android 11 (R) */) {
            w.setDecorFitsSystemWindows(false);
            WindowInsetsController c = w.getInsetsController();
            if (c != null) {
                int bars = WindowInsets.Type.statusBars() | WindowInsets.Type.navigationBars();
                if (sImmersive) {
                    c.setSystemBarsBehavior(WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE);
                    c.hide(bars);
                } else {
                    c.show(bars);
                }
            }
        } else {
            w.getDecorView().setSystemUiVisibility(LAYOUT_FLAGS | (sImmersive ? IMMERSIVE_FLAGS : 0));
        }
    }

    /**
     * What actually covers the screen: visible system bars and the display
     * cutout. SDL's safe area also includes the edge gesture zones, which
     * grow in immersive mode; fine for buttons, but the game picture only
     * needs to avoid real obstructions. Pixels, implemented in android.odin.
     */
    static native void nativeVisibleInsets(int left, int top, int right, int bottom);

    @Override
    protected SDLSurface createSDLSurface(Context context) {
        return new SDLSurface(context) {
            @Override
            public WindowInsets onApplyWindowInsets(View v, WindowInsets insets) {
                int l = 0, t = 0, r = 0, b = 0;
                if (Build.VERSION.SDK_INT >= 30 /* Android 11 (R) */) {
                    Insets i = insets.getInsets(WindowInsets.Type.systemBars() | WindowInsets.Type.displayCutout());
                    l = i.left; t = i.top; r = i.right; b = i.bottom;
                } else {
                    l = insets.getSystemWindowInsetLeft();
                    t = insets.getSystemWindowInsetTop();
                    r = insets.getSystemWindowInsetRight();
                    b = insets.getSystemWindowInsetBottom();
                    DisplayCutout c = insets.getDisplayCutout();
                    if (c != null) {
                        l = Math.max(l, c.getSafeInsetLeft());
                        t = Math.max(t, c.getSafeInsetTop());
                        r = Math.max(r, c.getSafeInsetRight());
                        b = Math.max(b, c.getSafeInsetBottom());
                    }
                }
                try {
                    nativeVisibleInsets(l, t, r, b);
                } catch (UnsatisfiedLinkError e) {
                    // Native library not ready yet; SDL's safe area still applies.
                }
                return super.onApplyWindowInsets(v, insets);
            }
        };
    }

    /**
     * Called from native code. The file name the user sees for a content://
     * URI from the file picker, or null. The URI itself often only holds an
     * id (e.g. ".../document/msf:1000000033" from Downloads).
     */
    public static String displayName(String uri) {
        try (Cursor c = getContext().getContentResolver().query(Uri.parse(uri),
                new String[] { OpenableColumns.DISPLAY_NAME }, null, null, null)) {
            if (c != null && c.moveToFirst()) {
                return c.getString(0);
            }
        } catch (Exception e) {
            // Fall back to guessing from the URI.
        }
        return null;
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
