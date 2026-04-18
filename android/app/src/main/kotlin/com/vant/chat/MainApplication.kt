package com.vant.chat

import io.flutter.app.FlutterApplication
import io.branch.referral.Branch

class MainApplication : FlutterApplication() {
    
    override fun onCreate() {
        super.onCreate()
        
        // Initialize Branch
        Branch.getAutoInstance(this)
    }
}
