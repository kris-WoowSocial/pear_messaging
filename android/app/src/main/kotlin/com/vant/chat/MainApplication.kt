package com.vant.chat

import io.flutter.app.FlutterApplication

class MainApplication : FlutterApplication() {
    
    override fun onCreate() {
        super.onCreate()

        // Create call notification channels up front so they exist before the
        // first call (diagnostics can read them, users can configure them).
        CallForegroundService.createNotificationChannels(this)
    }
}
