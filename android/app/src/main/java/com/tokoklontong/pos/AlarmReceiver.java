package com.tokoklontong.pos;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.os.Build;

public class AlarmReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context context, Intent intent) {
        // service dibunuh (swipe/force close) -> coba hidupkan lagi
        SharedPreferencesCompatCheck(context);
    }

    private void SharedPreferencesCompatCheck(Context context) {
        android.content.SharedPreferences sp = context.getSharedPreferences("kpos", Context.MODE_PRIVATE);
        if (sp.getString("admin_pin", "").isEmpty()) return; // belum pernah set kredensial
        Intent svc = new Intent(context, OrderPollService.class);
        if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(svc);
        else context.startService(svc);
    }
}
