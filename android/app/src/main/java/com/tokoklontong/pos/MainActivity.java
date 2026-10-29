package com.tokoklontong.pos;

import android.annotation.SuppressLint;
import android.app.DownloadManager;
import android.content.Context;
import android.content.Intent;
import android.net.Uri;
import android.os.Build;
import android.os.Environment;
import android.os.Bundle;
import android.webkit.JavascriptInterface;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.webkit.WebSettings;
import android.widget.Toast;
import android.app.Activity;
import org.json.JSONObject;
import java.io.File;
import java.io.FileOutputStream;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import android.util.Base64;

public class MainActivity extends Activity {
    private WebView webView;

    @SuppressLint("SetJavaScriptEnabled")
    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        webView = new WebView(this);
        setContentView(webView);

        WebSettings ws = webView.getSettings();
        ws.setJavaScriptEnabled(true);
        ws.setDomStorageEnabled(true);
        ws.setDatabaseEnabled(true);
        ws.setAllowFileAccess(true);
        ws.setCacheMode(WebSettings.LOAD_DEFAULT);

        webView.addJavascriptInterface(new Bridge(), "AndroidBridge");
        webView.setWebViewClient(new WebViewClient() {
            @Override
            public boolean shouldOverrideUrlLoading(WebView view, android.webkit.WebResourceRequest request) {
                android.net.Uri u = request.getUrl();
                String host = u.getHost() == null ? "" : u.getHost();
                // url eksternal (github download, wa.me, dsb) -> browser
                if (host.contains("github.com") || host.contains("wa.me") || host.contains("whatsapp.com")
                    || host.contains("play.google.com") || host.contains("drive.google.com") || host.contains("mayar.id")) {
                    try {
                        startActivity(new android.content.Intent(android.content.Intent.ACTION_VIEW, u));
                    } catch (Exception e) { }
                    return true;
                }
                return false;
            }
        });
        // WAJIB agar prompt()/alert()/confirm() dari JS berfungsi di WebView
        webView.setWebChromeClient(new android.webkit.WebChromeClient() {
            @Override
            public void onPermissionRequest(final android.webkit.PermissionRequest request) {
                runOnUiThread(() -> request.grant(request.getResources()));
            }
        });
        webView.loadUrl("file:///android_asset/index.html");
    }

    private void showNotif(String title, String body) {
        try {
            if (Build.VERSION.SDK_INT >= 33) {
                if (checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) != android.content.pm.PackageManager.PERMISSION_GRANTED) {
                    requestPermissions(new String[]{android.Manifest.permission.POST_NOTIFICATIONS}, 101);
                    // tampilkan toast dulu sekalian sebagai fallback
                    Toast.makeText(this, title + ": " + body, Toast.LENGTH_LONG).show();
                    return;
                }
            }
            android.app.NotificationManager nm = (android.app.NotificationManager) getSystemService(NOTIFICATION_SERVICE);
            if (Build.VERSION.SDK_INT >= 26) {
                nm.createNotificationChannel(new android.app.NotificationChannel("orders", "Pesanan Online", android.app.NotificationManager.IMPORTANCE_HIGH));
            }
            android.app.Notification.Builder nb = Build.VERSION.SDK_INT >= 26
                ? new android.app.Notification.Builder(this, "orders")
                : new android.app.Notification.Builder(this);
            nb.setSmallIcon(android.R.drawable.ic_dialog_info)
              .setContentTitle(title).setContentText(body)
              .setAutoCancel(true);
            nm.notify((int) System.currentTimeMillis() % 100000, nb.build());
        } catch (Exception e) { }
    }

    @Override
    public void onBackPressed() {
        if (webView.canGoBack()) webView.goBack(); else super.onBackPressed();
    }

    public class Bridge {
        @JavascriptInterface
        public void openUrl(String url) {
            try {
                startActivity(new android.content.Intent(android.content.Intent.ACTION_VIEW, android.net.Uri.parse(url)));
            } catch (Exception e) { }
        }

        @JavascriptInterface
        public void setOrderCredentials(String url, String key, String pin) {
            getSharedPreferences("kpos", MODE_PRIVATE).edit()
                .putString("sb_url", url).putString("sb_key", key).putString("admin_pin", pin).apply();
            // mulai/refresh foreground service polling
            if (Build.VERSION.SDK_INT >= 26) startForegroundService(new Intent(MainActivity.this, OrderPollService.class));
            else startService(new Intent(MainActivity.this, OrderPollService.class));
        }

        @JavascriptInterface
        public void notifyOrder(String title, String body) {
            runOnUiThread(() -> showNotif(title, body));
        }

        @JavascriptInterface
        public void toast(String msg) {
            runOnUiThread(() -> Toast.makeText(MainActivity.this, msg, Toast.LENGTH_LONG).show());
        }

        // Save base64 file (e.g. xlsx report) to Downloads, return path
        @JavascriptInterface
        public String saveFile(String fileName, String mimeType, String base64Data) {
            try {
                byte[] data = Base64.decode(base64Data, Base64.DEFAULT);
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    android.content.ContentValues cv = new android.content.ContentValues();
                    cv.put(android.provider.MediaStore.Downloads.DISPLAY_NAME, fileName);
                    cv.put(android.provider.MediaStore.Downloads.MIME_TYPE, mimeType);
                    Uri uri = getContentResolver().insert(
                        android.provider.MediaStore.Downloads.EXTERNAL_CONTENT_URI, cv);
                    try (OutputStream os = getContentResolver().openOutputStream(uri)) {
                        os.write(data);
                    }
                    return "Downloads/" + fileName;
                } else {
                    File dir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS);
                    dir.mkdirs();
                    File f = new File(dir, fileName);
                    try (FileOutputStream fos = new FileOutputStream(f)) { fos.write(data); }
                    return f.getAbsolutePath();
                }
            } catch (Exception e) {
                return "ERROR: " + e.getMessage();
            }
        }
    }
}
