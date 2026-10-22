package com.vant.chat

import io.flutter.app.FlutterApplication
import io.branch.referral.Branch

class MainApplication : FlutterApplication() {
    
    override fun onCreate() {
        super.onCreate()

        // Create call notification channels up front so they exist before the
        // first call (diagnostics can read them, users can configure them).
        CallForegroundService.createNotificationChannels(this)

        // Initialize Branch
        Branch.getAutoInstance(this)
    }
}
