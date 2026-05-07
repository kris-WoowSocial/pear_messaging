package com.vant.chat

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED ||
            intent.action == "android.intent.action.QUICKBOOT_POWERON") {
            Log.d("BootReceiver", "Device booted, ensuring notification permissions")

            // Note: On Android 15 (One UI 7), we cannot launch activities or services
            // directly from BOOT_COMPLETED receivers. The presence of this receiver
            // ensures the app is aware of boot events. FCM token refresh will happen
            // automatically when the user opens the app next.
            
            // The battery optimization exemption and notification channel setup
            // are handled in MainActivity and FCMService when the app launches.
        }
    }
}
