package com.tokoklontong.pos;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.content.Intent;
import android.content.SharedPreferences;
import android.os.Build;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.util.Log;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.HashSet;
import java.util.Iterator;
import java.util.Set;

public class OrderPollService extends Service {
    private static final String TAG = "OrderPoll";
    private static final String CHANNEL_UPDATES = "orders";
    private static final long INTERVAL_MS = 30000;
    private Handler handler;
    private Runnable runnable;
    private boolean knownLoaded = false;

    @Override
    public IBinder onBind(Intent intent) { return null; }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        startForegroundWithSilentNotif();
        handler = new Handler(Looper.getMainLooper());
        runnable = new Runnable() {
            @Override
            public void run() {
                pollOnce();
                handler.postDelayed(this, INTERVAL_MS);
            }
        };
        handler.post(runnable);
        return START_STICKY;
    }

    private void startForegroundWithSilentNotif() {
        NotificationManager nm = (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
        if (Build.VERSION.SDK_INT >= 26) {
            NotificationChannel ch = new NotificationChannel(CHANNEL_UPDATES, "Pesanan Online", NotificationManager.IMPORTANCE_HIGH);
            nm.createNotificationChannel(ch);
            NotificationChannel silent = new NotificationChannel("orders_fg", "Monitoring", NotificationManager.IMPORTANCE_MIN);
            nm.createNotificationChannel(silent);
        }
        Notification.Builder nb = Build.VERSION.SDK_INT >= 26
            ? new Notification.Builder(this, "orders_fg")
            : new Notification.Builder(this);
        nb.setContentTitle("KelontongPOS").setContentText("Memantau pesanan online…").setOngoing(true)
          .setSmallIcon(android.R.drawable.ic_dialog_info);
        startForeground(1, nb.build());
    }

    private void pollOnce() {
        SharedPreferences sp = getSharedPreferences("kpos", MODE_PRIVATE);
        final String url = sp.getString("sb_url", "");
        final String key = sp.getString("sb_key", "");
        final String pin = sp.getString("admin_pin", "");
        if (url.isEmpty() || key.isEmpty() || pin.isEmpty()) return;
        new Thread(new Runnable() {
            @Override
            public void run() {
                try {
                    HttpURLConnection c = (HttpURLConnection) new URL(url + "/rest/v1/rpc/shop_admin_orders").openConnection();
                    c.setRequestMethod("POST");
                    c.setConnectTimeout(15000); c.setReadTimeout(20000);
                    c.setRequestProperty("apikey", key);
                    c.setRequestProperty("Authorization", "Bearer " + key);
                    c.setRequestProperty("Content-Type", "application/json");
                    c.setDoOutput(true);
                    c.getOutputStream().write(("{\"p_admin_pin\":\"" + pin + "\"}").getBytes(StandardCharsets.UTF_8));
                    int code = c.getResponseCode();
                    if (code != 200) return;
                    BufferedReader r = new BufferedReader(new InputStreamReader(c.getInputStream(), StandardCharsets.UTF_8));
                    StringBuilder sb = new StringBuilder(); String line;
                    while ((line = r.readLine()) != null) sb.append(line);
                    JSONObject data = new JSONObject(sb.toString());
                    if (!data.optBoolean("ok")) return;
                    JSONArray orders = data.optJSONArray("orders");
                    if (orders == null) return;
                    SharedPreferences prefs = getSharedPreferences("kpos", MODE_PRIVATE);
                    Set<String> known = new HashSet<>(prefs.getStringSet("known_orders", new HashSet<String>()));
                    int newCount = 0;
                    String firstCust = "", firstTotal = "";
                    for (int i = 0; i < orders.length(); i++) {
                        JSONObject o = orders.getJSONObject(i);
                        String id = o.optString("id");
                        if (!known.contains(id)) {
                            newCount++;
                            if (firstCust.isEmpty()) { firstCust = o.optString("customer_id"); firstTotal = String.valueOf(o.optDouble("total", 0)); }
                        }
                    }
                    if (knownLoaded && newCount > 0) {
                        notifyOrders(newCount, firstCust, firstTotal);
                    }
                    Set<String> now = new HashSet<>();
                    for (int i = 0; i < orders.length(); i++) now.add(orders.getJSONObject(i).optString("id"));
                    prefs.edit().putStringSet("known_orders", now).apply();
                    knownLoaded = true;
                } catch (Exception e) {
                    Log.w(TAG, "poll error: " + e.getMessage());
                }
            }
        }).start();
    }

    private void notifyOrders(int n, String cust, String total) {
        NotificationManager nm = (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
        Notification.Builder nb = Build.VERSION.SDK_INT >= 26
            ? new Notification.Builder(this, CHANNEL_UPDATES)
            : new Notification.Builder(this);
        nb.setSmallIcon(android.R.drawable.ic_dialog_info)
          .setContentTitle("🛒 " + n + " Pesanan Online Baru!")
          .setContentText(cust + " — Rp" + total)
          .setAutoCancel(true);
        nm.notify((int) (System.currentTimeMillis() % 100000), nb.build());
    }

    @Override
    public void onDestroy() {
        if (handler != null && runnable != null) handler.removeCallbacks(runnable);
        scheduleRestart();
        super.onDestroy();
    }

    // Android mematikan service saat app di-swipe recents/force close.
    // Alarm tiap 15 menit (allow-while-idle) membangunkan service lagi,
    // selama kredensial masih tersimpan (user masih pakai fitur ini).
    private void scheduleRestart() {
        try {
            android.app.AlarmManager am = (android.app.AlarmManager) getSystemService(ALARM_SERVICE);
            android.app.PendingIntent pi = android.app.PendingIntent.getBroadcast(this, 1001,
                new Intent(this, AlarmReceiver.class),
                android.app.PendingIntent.FLAG_UPDATE_CURRENT | android.app.PendingIntent.FLAG_IMMUTABLE);
            long trigger = android.os.SystemClock.elapsedRealtime() + 15 * 60 * 1000L;
            if (Build.VERSION.SDK_INT >= 23) {
                am.setExactAndAllowWhileIdle(android.app.AlarmManager.ELAPSED_REALTIME_WAKEUP, trigger, pi);
            } else {
                am.setExact(android.app.AlarmManager.ELAPSED_REALTIME_WAKEUP, trigger, pi);
            }
        } catch (Exception e) { }
    }
}
