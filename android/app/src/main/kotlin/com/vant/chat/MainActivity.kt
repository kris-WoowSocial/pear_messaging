package com.vant.chat

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    private val DEEPLINK_CHANNEL = "com.pear.messaging/deeplink"
    private val APPLINKS_CHANNEL = "com.pear.messaging.pear_messaging/applinks"
    private val BATTERY_CHANNEL = "com.pear.messaging/battery"
    private var pendingIntent: Intent? = null
    
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        
        // Store the intent to handle later when Flutter engine is ready
        pendingIntent = intent
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        // Setup battery optimization channel for Samsung devices
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, BATTERY_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "isIgnoringBatteryOptimizations" -> {
                    result.success(isIgnoringBatteryOptimizations())
                }
                "requestIgnoreBatteryOptimizations" -> {
                    requestIgnoreBatteryOptimizations()
                    result.success(null)
                }
                "openBatterySettings" -> {
                    openBatterySettings()
                    result.success(null)
                }
                "getDeviceManufacturer" -> {
                    result.success(android.os.Build.MANUFACTURER)
                }
                else -> {
                    result.notImplemented()
                }
            }
        }
        
        // Setup app links method channel
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, APPLINKS_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "requestDefaultLinkHandler" -> {
                    requestDefaultLinkHandler()
                    result.success(null)
                }
                "isDefaultLinkHandler" -> {
                    val isDefault = isDefaultLinkHandler()
                    result.success(isDefault)
                }
                "getInitialLink" -> {
                    val initialLink = getInitialLink()
                    result.success(initialLink)
                }
                else -> {
                    result.notImplemented()
                }
            }
        }
        
        // Handle any pending intent now that Flutter engine is ready
        // Add a small delay to ensure Flutter engine is fully initialized
        pendingIntent?.let { intent ->
            Handler(Looper.getMainLooper()).postDelayed({
                handleIntent(intent)
                pendingIntent = null // Clear after handling
            }, 500) // 500ms delay to ensure Flutter engine is ready
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        this.intent = intent
        // Handle deep link when app is already running
        handleIntent(intent)
    }
    
    private fun handleIntent(intent: Intent) {
        try {
            val data = intent.data
            if (data != null) {
                println("Deep link received: $data")
                
                // Handle both custom scheme and Branch.io links
                if (data.scheme == "vantchat" || 
                    data.host?.contains("vantchatting.app.link") == true ||
                    data.host?.contains("pearmessaging.app.link") == true) {
                    
                    // Check if Flutter engine is available before proceeding
                    val engine = flutterEngine
                    if (engine == null) {
                        println("FlutterEngine is null, cannot handle deep link: $data")
                        return
                    }
                    
                    val messenger = engine.dartExecutor?.binaryMessenger
                    if (messenger == null) {
                        println("BinaryMessenger is null, cannot handle deep link: $data")
                        return
                    }
                    
                    // Send deep link to Flutter with proper error handling
                    try {
                        val channel = MethodChannel(messenger, DEEPLINK_CHANNEL)
                        val arguments = mapOf(
                            "url" to data.toString(),
                            "scheme" to data.scheme,
                            "host" to data.host,
                            "path" to data.path,
                            "queryParameters" to data.queryParameterNames.associateWith { data.getQueryParameter(it) }
                        )
                        channel.invokeMethod("onDeepLink", arguments)
                        println("Deep link sent to Flutter successfully")
                    } catch (e: Exception) {
                        println("Error sending deep link to Flutter: $e")
                    }
                }
            }
        } catch (e: Exception) {
            println("Error handling intent: $e")
        }
    }

    private fun requestDefaultLinkHandler() {
        try {
            // Open app info settings where user can set as default
            val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                data = Uri.parse("package:com.pear.messaging.pear_messaging")
            }
            startActivity(intent)
        } catch (e: Exception) {
            // Fallback to main settings
            val intent = Intent(Settings.ACTION_SETTINGS)
            startActivity(intent)
        }
    }

    private fun getInitialLink(): String? {
        return try {
            // Get the initial intent that started the app
            val initialIntent = intent
            val data = initialIntent?.data
            
            if (data != null) {
                println("Initial link found: $data")
                
                // Handle both custom scheme and Branch.io links
                if (data.scheme == "vantchat" || 
                    data.host?.contains("vantchatting.app.link") == true ||
                    data.host?.contains("pearmessaging.app.link") == true) {
                    return data.toString()
                }
            }
            
            println("No supported initial link found")
            null
        } catch (e: Exception) {
            println("Error getting initial link: $e")
            null
        }
    }

    private fun isDefaultLinkHandler(): Boolean {
        return try {
            val intent = Intent(Intent.ACTION_VIEW).apply {
                data = Uri.parse("https://vantchatting.app.link")
                addCategory(Intent.CATEGORY_BROWSABLE)
            }
            val resolveInfo = packageManager.resolveActivity(intent, 0)
            resolveInfo?.activityInfo?.packageName == packageName
        } catch (e: Exception) {
            false
        }
    }

    private fun isIgnoringBatteryOptimizations(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val powerManager = getSystemService(POWER_SERVICE) as PowerManager
            powerManager.isIgnoringBatteryOptimizations(packageName)
        } else {
            true
        }
    }

    private fun requestIgnoreBatteryOptimizations() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            if (!isIgnoringBatteryOptimizations()) {
                try {
                    val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                        data = Uri.parse("package:$packageName")
                    }
                    startActivity(intent)
                } catch (e: Exception) {
                    println("Error requesting battery optimization exemption: $e")
                }
            }
        }
    }

    private fun openBatterySettings() {
        try {
            // Use ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS to show the "Not Optimized" list directly
            // This is more specific for Samsung's "Deep Sleeping" apps category
            val intent = Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
            startActivity(intent)
        } catch (e: Exception) {
            println("Error opening battery optimization settings: $e")
            // Fallback to app-specific settings
            try {
                val fallbackIntent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                    data = Uri.parse("package:$packageName")
                }
                startActivity(fallbackIntent)
            } catch (e2: Exception) {
                println("Error opening fallback settings: $e2")
            }
        }
    }
}
