package com.tokoklontong.pos;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.os.Build;

public class BootReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context context, Intent intent) {
        if (intent == null || !Intent.ACTION_BOOT_COMPLETED.equals(intent.getAction())) return;
        android.content.SharedPreferences sp = context.getSharedPreferences("kpos", Context.MODE_PRIVATE);
        if (sp.getString("admin_pin", "").isEmpty()) return;
        Intent svc = new Intent(context, OrderPollService.class);
        if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(svc);
        else context.startService(svc);
    }
}
