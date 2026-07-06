package com.vant.chat

import android.app.NotificationManager
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorManager
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.ToneGenerator
import android.provider.Settings
import android.view.WindowManager
import android.Manifest
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.EventChannel

class MainActivity : FlutterFragmentActivity() {
    private val DEEPLINK_CHANNEL = "com.pear.messaging/deeplink"
    private val APPLINKS_CHANNEL = "com.pear.messaging.pear_messaging/applinks"
    private val BATTERY_CHANNEL = "com.pear.messaging/battery"
    private val AUDIO_CHANNEL = "com.pear.messaging/audio"
    private val CALL_CHANNEL = "com.pear.messaging/call"
    private val PROXIMITY_CHANNEL = "com.pear.messaging/proximity"
    private val INCOMING_CALL_CHANNEL = "com.vant.chat/incoming_call"
    private val EVENT_CHANNEL = "com.vant.chat/call_events"
    private var pendingIntent: Intent? = null
    private var pendingCallAction: String? = null
    private var pendingCallData: Map<String, String>? = null
    private var proximityWakeLock: PowerManager.WakeLock? = null
    private var toneGenerator: ToneGenerator? = null
    private var ringbackHandler: Handler? = null
    private var ringbackRunnable: Runnable? = null
    
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Pre-register Telecom phone account so incoming calls work immediately
        VantCallManager.ensurePhoneAccountRegistered(this)

        // Store the intent to handle later when Flutter engine is ready
        pendingIntent = intent

        // Capture answer/decline notification actions (if any) before the engine is ready
        handleCallIntent(intent)

        // If the device is locked when the activity launches (e.g. cold-start from
        // a CallKit accept notification on the lock screen), set showWhenLocked
        // immediately — before Flutter renders — so the call screen appears over
        // the lock screen without requiring a PIN.
        val keyguardManager = getSystemService(Context.KEYGUARD_SERVICE) as android.app.KeyguardManager
        if (keyguardManager.isKeyguardLocked) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                setShowWhenLocked(true)
                setTurnScreenOn(true)
            } else {
                @Suppress("DEPRECATION")
                window.addFlags(
                    WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                    WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
                )
            }
            // Also acquire a brief wake lock to physically turn the screen on
            try {
                @Suppress("DEPRECATION")
                val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                val wl = pm.newWakeLock(
                    PowerManager.FULL_WAKE_LOCK or
                    PowerManager.ACQUIRE_CAUSES_WAKEUP or
                    PowerManager.ON_AFTER_RELEASE,
                    "vant:coldStartWakeLock"
                )
                wl.acquire(10_000L)
                Handler(Looper.getMainLooper()).postDelayed({
                    if (wl.isHeld) wl.release()
                }, 3_000L)
            } catch (e: Exception) {
                println("coldStart wakeLock error: $e")
            }
            println("onCreate: device locked on cold-start, showWhenLocked applied")
        }
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
        
        // Setup audio routing method channel for reliable speakerphone control during WebRTC calls
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, AUDIO_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "setSpeakerphoneOn" -> {
                    val on = call.argument<Boolean>("on") ?: false
                    setSpeakerphoneOn(on)
                    result.success(null)
                }
                "playRingback" -> {
                    playRingback()
                    result.success(null)
                }
                "stopRingback" -> {
                    stopRingback()
                    result.success(null)
                }
                else -> {
                    result.notImplemented()
                }
            }
        }

        // Setup call method channel for lock screen dismissal and call management
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CALL_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "dismissKeyguard" -> {
                    dismissKeyguard()
                    result.success(null)
                }
                "showWhenLocked" -> {
                    showWhenLocked()
                    result.success(null)
                }
                "isScreenLocked" -> {
                    result.success(isScreenLocked())
                }
                "clearShowWhenLocked" -> {
                    clearShowWhenLocked()
                    result.success(null)
                }
                "relockDevice" -> {
                    relockDevice()
                    result.success(null)
                }
                "isAppInBackground" -> {
                    result.success(isAppInBackground())
                }
                "finishAndRemoveTask" -> {
                    closeApp()
                    result.success(null)
                }
                else -> {
                    result.notImplemented()
                }
            }
        }

        // Setup proximity method channel for screen off during calls
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PROXIMITY_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "acquireProximityWakeLock" -> {
                    acquireProximityWakeLock()
                    result.success(null)
                }
                "releaseProximityWakeLock" -> {
                    releaseProximityWakeLock()
                    result.success(null)
                }
                "turnScreenOff" -> {
                    turnScreenOff()
                    result.success(null)
                }
                "turnScreenOn" -> {
                    turnScreenOn()
                    result.success(null)
                }
                "checkProximitySensor" -> {
                    val sensorInfo = checkProximitySensor()
                    result.success(sensorInfo)
                }
                else -> {
                    result.notImplemented()
                }
            }
        }

        // Setup incoming call method channel for native foreground service
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, INCOMING_CALL_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "showIncomingCall" -> {
                    val callerName = call.argument<String>("caller_name") ?: "Unknown"
                    val callId = call.argument<String>("call_id") ?: ""
                    val callerId = call.argument<String>("caller_id") ?: ""
                    showIncomingCall(callerName, callId, callerId)
                    result.success(null)
                }
                "stopIncomingCall" -> {
                    stopIncomingCall()
                    result.success(null)
                }
                "setCallScreenVisible" -> {
                    val visible = call.argument<Boolean>("visible") ?: false
                    val prefs = getSharedPreferences("vant_chat_prefs", Context.MODE_PRIVATE)
                    prefs.edit().putBoolean("flutter_call_screen_visible", visible).apply()
                    result.success(null)
                }
                "getPendingCallAction" -> {
                    val response = if (pendingCallAction != null) {
                        mapOf(
                            "action" to pendingCallAction,
                            "data" to pendingCallData
                        )
                    } else null
                    result.success(response)
                    pendingCallAction = null
                    pendingCallData = null
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
        
        // Event channel: native -> Flutter for foreground incoming call broadcasts
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                private var receiver: android.content.BroadcastReceiver? = null

                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    receiver = object : android.content.BroadcastReceiver() {
                        override fun onReceive(context: Context?, intent: Intent?) {
                            if (intent?.action == "com.vant.chat.SHOW_FLUTTER_CALL") {
                                val data = hashMapOf<String, String>()
                                intent.extras?.keySet()?.forEach { key ->
                                    data[key] = intent.getStringExtra(key) ?: ""
                                }
                                events?.success(data)
                            }
                        }
                    }
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        registerReceiver(
                            receiver,
                            android.content.IntentFilter("com.vant.chat.SHOW_FLUTTER_CALL"),
                            android.content.Context.RECEIVER_NOT_EXPORTED
                        )
                    } else {
                        registerReceiver(
                            receiver,
                            android.content.IntentFilter("com.vant.chat.SHOW_FLUTTER_CALL")
                        )
                    }
                }

                override fun onCancel(arguments: Any?) {
                    receiver?.let { unregisterReceiver(it) }
                }
            })
        
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
        // Capture answer/decline notification actions (if any)
        handleCallIntent(intent)
        // If the device is locked when the activity comes to foreground
        // (e.g. CallKit accept from lock screen), show over lock screen immediately
        val keyguardManager = getSystemService(Context.KEYGUARD_SERVICE) as android.app.KeyguardManager
        if (keyguardManager.isKeyguardLocked) {
            showWhenLocked()
            println("onNewIntent: device locked, showWhenLocked applied")
        }
        // Handle deep link when app is already running
        handleIntent(intent)
    }
    
    private fun handleIntent(intent: Intent) {
        try {
            // Handle call actions or full-screen launch from native service
            val callAction = intent.getStringExtra("call_action")
            val showIncomingCall = intent.getBooleanExtra("show_incoming_call", false)
            val intentAction = intent.action
            val isAnswerDecline = intentAction == "com.vant.chat.ANSWER_CALL" ||
                                  intentAction == "com.vant.chat.DECLINE_CALL"
            val callId = intent.getStringExtra("call_id") ?: ""
            val callerId = intent.getStringExtra("caller_id") ?: ""
            val callerName = intent.getStringExtra("caller_name") ?: ""
            val roomId = intent.getStringExtra("room_id") ?: ""
            val avatarUrl = intent.getStringExtra("avatar_url") ?: ""
            val isVideo = intent.getBooleanExtra("is_video", false)
            
            val action = when {
                isAnswerDecline -> if (intentAction == "com.vant.chat.ANSWER_CALL") "answer" else "decline"
                callAction != null -> callAction
                showIncomingCall -> "show_incoming_call"
                else -> null
            }
            
            if (action != null) {
                println("Call intent received: action=$action, callId=$callId")
                
                // Check if Flutter engine is available
                val engine = flutterEngine
                if (engine == null) {
                    println("FlutterEngine is null, cannot handle call action: $action")
                    // Store for later handling when engine is ready
                    pendingIntent = intent
                    return
                }
                
                val messenger = engine.dartExecutor?.binaryMessenger
                if (messenger == null) {
                    println("BinaryMessenger is null, cannot handle call action: $action")
                    pendingIntent = intent
                    return
                }
                
                // Send call action to Flutter
                try {
                    val channel = MethodChannel(messenger, CALL_CHANNEL)
                    val arguments = mapOf(
                        "action" to action,
                        "callId" to callId,
                        "callerId" to callerId,
                        "callerName" to callerName,
                        "roomId" to roomId,
                        "avatarUrl" to avatarUrl,
                        "isVideo" to isVideo
                    )
                    channel.invokeMethod("onCallAction", arguments)
                    println("Call action sent to Flutter successfully: $action")
                } catch (e: Exception) {
                    println("Error sending call action to Flutter: $e")
                }
                return
            }
            
            // Handle deep links
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

    private fun setSpeakerphoneOn(on: Boolean) {
        try {
            val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager

            // Request audio focus for call
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                audioManager.requestAudioFocus(
                    AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_EXCLUSIVE)
                        .setAudioAttributes(
                            AudioAttributes.Builder()
                                .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                                .build()
                        )
                        .build()
                )
            }

            // WebRTC calls need MODE_IN_COMMUNICATION for speakerphone routing to work reliably
            audioManager.mode = AudioManager.MODE_IN_COMMUNICATION

            // On Android 11+ (API 31+), use setCommunicationDevice for reliable routing
            // On older Android, use isSpeakerphoneOn
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val audioDevices = audioManager.availableCommunicationDevices
                val targetType = if (on) {
                    AudioDeviceInfo.TYPE_BUILTIN_SPEAKER
                } else {
                    AudioDeviceInfo.TYPE_BUILTIN_EARPIECE
                }
                val device = audioDevices.find { it.type == targetType }
                if (device != null) {
                    val success = audioManager.setCommunicationDevice(device)
                    println("Communication device set to ${device.type}, success=$success, requested=$on")
                } else {
                    // Fallback to speakerphone flag
                    audioManager.isSpeakerphoneOn = on
                    println("AudioDeviceInfo type $targetType not available, fallback to speakerphone=$on")
                }
            } else {
                audioManager.isSpeakerphoneOn = on
                println("Speakerphone set to $on (legacy audio mode)")
            }
        } catch (e: Exception) {
            println("Error setting speakerphone: $e")
        }
    }

    private fun playRingback() {
        stopRingback()
        try {
            val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
            audioManager.mode = AudioManager.MODE_IN_COMMUNICATION
            // Route to earpiece
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val earpiece = audioManager.availableCommunicationDevices
                    .find { it.type == AudioDeviceInfo.TYPE_BUILTIN_EARPIECE }
                if (earpiece != null) audioManager.setCommunicationDevice(earpiece)
            } else {
                audioManager.isSpeakerphoneOn = false
            }
            // ToneGenerator on STREAM_VOICE_CALL always follows earpiece/speaker routing
            toneGenerator = ToneGenerator(AudioManager.STREAM_VOICE_CALL, 80)
            val handler = Handler(Looper.getMainLooper())
            ringbackHandler = handler
            val runnable = object : Runnable {
                override fun run() {
                    try {
                        toneGenerator?.startTone(ToneGenerator.TONE_SUP_RINGTONE, 1000)
                    } catch (_: Exception) {}
                    handler.postDelayed(this, 3000)
                }
            }
            ringbackRunnable = runnable
            handler.post(runnable)
            println("Ringback started via ToneGenerator on STREAM_VOICE_CALL")
        } catch (e: Exception) {
            println("Error starting ringback: $e")
        }
    }

    private fun stopRingback() {
        try {
            ringbackRunnable?.let { ringbackHandler?.removeCallbacks(it) }
            ringbackHandler = null
            ringbackRunnable = null
            toneGenerator?.stopTone()
            toneGenerator?.release()
            toneGenerator = null
            println("Ringback stopped")
        } catch (e: Exception) {
            println("Error stopping ringback: $e")
        }
    }

    private fun dismissKeyguard() {
        try {
            // Show activity OVER the lock screen without unlocking the device.
            // setShowWhenLocked(true) + setTurnScreenOn(true) is sufficient:
            // the Flutter UI renders on top of the lock screen, user never enters PIN.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                setShowWhenLocked(true)
                setTurnScreenOn(true)
            } else {
                @Suppress("DEPRECATION")
                window.addFlags(
                    WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                    WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
                )
            }
            println("dismissKeyguard: showing over lock screen (no PIN required)")
        } catch (e: Exception) {
            println("Error in dismissKeyguard: $e")
        }
    }

    private fun isAppInBackground(): Boolean {
        return !lifecycle.currentState.isAtLeast(androidx.lifecycle.Lifecycle.State.RESUMED)
    }

    private fun closeApp() {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                this.finishAndRemoveTask()
            } else {
                @Suppress("DEPRECATION")
                moveTaskToBack(true)
            }
            println("closeApp: app closed after cold-start call ended")
        } catch (e: Exception) {
            println("closeApp error: $e")
        }
    }

    private fun isScreenLocked(): Boolean {
        return try {
            val keyguardManager = getSystemService(Context.KEYGUARD_SERVICE) as android.app.KeyguardManager
            keyguardManager.isKeyguardLocked
        } catch (e: Exception) {
            false
        }
    }

    private fun showWhenLocked() {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                setShowWhenLocked(true)
                setTurnScreenOn(true)
            } else {
                @Suppress("DEPRECATION")
                window.addFlags(
                    WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                    WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
                )
            }
            // Physically wake the screen using a brief FULL_WAKE_LOCK.
            // setTurnScreenOn alone only works when the activity is already
            // being brought forward by user interaction; this forces the screen
            // on from a completely off state (same technique as alarm apps).
            @Suppress("DEPRECATION")
            val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
            val wakeLock = powerManager.newWakeLock(
                PowerManager.FULL_WAKE_LOCK or
                PowerManager.ACQUIRE_CAUSES_WAKEUP or
                PowerManager.ON_AFTER_RELEASE,
                "vant:incomingCallWakeLock"
            )
            wakeLock.acquire(10_000L) // hold for up to 10s; released once screen is on
            // Release after a short delay so the screen stays on for the user
            android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                if (wakeLock.isHeld) wakeLock.release()
            }, 3_000L)
            println("showWhenLocked: screen woken via FULL_WAKE_LOCK")
        } catch (e: Exception) {
            println("Error enabling show when locked: $e")
        }
    }

    private fun relockDevice() {
        try {
            // Clear showWhenLocked so the lock screen is allowed to cover the app again.
            // Then move task to back — OS immediately shows the lock screen on top.
            clearShowWhenLocked()
            moveTaskToBack(true)
            println("relockDevice: flags cleared, moved to back, lock screen will appear")
        } catch (e: Exception) {
            println("relockDevice error: $e")
        }
    }

    private fun clearShowWhenLocked() {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                setShowWhenLocked(false)
                setTurnScreenOn(false)
            } else {
                @Suppress("DEPRECATION")
                window.clearFlags(
                    WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                    WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON or
                    WindowManager.LayoutParams.FLAG_DISMISS_KEYGUARD
                )
            }
            println("clearShowWhenLocked: power button lock restored")
        } catch (e: Exception) {
            println("Error clearing show when locked: $e")
        }
    }

    private fun acquireProximityWakeLock() {
        try {
            val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
            val hasProximitySensor = powerManager.isWakeLockLevelSupported(PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK)
            println("Device supports PROXIMITY_SCREEN_OFF_WAKE_LOCK: $hasProximitySensor")

            if (!hasProximitySensor) {
                println("WARNING: Device does not support PROXIMITY_SCREEN_OFF_WAKE_LOCK - will use manual screen control")
                return
            }

            // Use PROXIMITY_SCREEN_OFF_WAKE_LOCK to automatically turn screen off when phone is near ear
            // This wake lock is released automatically when the phone moves away from the ear
            proximityWakeLock = powerManager.newWakeLock(
                PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK,
                "vant_chat:proximity_wake_lock"
            )
            // Use a long timeout (1 hour) - the wake lock is released automatically by proximity sensor
            proximityWakeLock?.acquire(60*60*1000L /* 1 hour timeout */)
            println("Proximity wake lock acquired - screen will turn off when phone is near ear")
        } catch (e: Exception) {
            println("Error acquiring proximity wake lock: $e")
        }
    }

    private fun releaseProximityWakeLock() {
        try {
            proximityWakeLock?.release()
            proximityWakeLock = null
            println("Proximity wake lock released")
            // Force screen on after releasing wake lock to prevent stuck dark screen
            forceScreenOn()
        } catch (e: Exception) {
            println("Error releasing proximity wake lock: $e")
        }
    }

    private fun forceScreenOn() {
        try {
            runOnUiThread {
                // 1. Temporarily acquire a bright wake lock to turn screen on
                @Suppress("DEPRECATION")
                val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
                val wakeLock = powerManager.newWakeLock(
                    PowerManager.SCREEN_BRIGHT_WAKE_LOCK or
                    PowerManager.ACQUIRE_CAUSES_WAKEUP,
                    "vant:forceScreenOn"
                )
                wakeLock.acquire(2 * 1000L) // 2 seconds
                wakeLock.release()

                // 2. Restore window brightness to default
                val layoutParams = window.attributes
                layoutParams.screenBrightness = WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE
                window.attributes = layoutParams

                // 3. Clear any dim flags
                window.clearFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND)

                println("forceScreenOn: brightness restored")
            }
        } catch (e: Exception) {
            println("Error forcing screen on: $e")
        }
    }

    private fun turnScreenOff() {
        try {
            runOnUiThread {
                // Fallback: dim screen to 0 brightness to simulate screen off
                val layoutParams = window.attributes
                layoutParams.screenBrightness = 0.0f
                window.attributes = layoutParams
                println("Manual screen OFF requested - brightness set to 0")
            }
        } catch (e: Exception) {
            println("Error turning screen off: $e")
        }
    }

    private fun turnScreenOn() {
        try {
            runOnUiThread {
                // Restore default brightness
                val layoutParams = window.attributes
                layoutParams.screenBrightness = WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE
                window.attributes = layoutParams
                println("Manual screen ON requested - brightness restored")
            }
        } catch (e: Exception) {
            println("Error turning screen on: $e")
        }
    }

    private fun checkProximitySensor(): Map<String, Any> {
        try {
            val sensorManager = getSystemService(Context.SENSOR_SERVICE) as SensorManager
            val proximitySensor = sensorManager.getDefaultSensor(Sensor.TYPE_PROXIMITY)
            val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
            val hasWakeLock = powerManager.isWakeLockLevelSupported(PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK)

            val result = mutableMapOf<String, Any>(
                "hasProximitySensor" to (proximitySensor != null),
                "hasProximityWakeLock" to hasWakeLock
            )

            if (proximitySensor != null) {
                result["sensorName"] = proximitySensor.name ?: "Unknown"
                result["sensorVendor"] = proximitySensor.vendor ?: "Unknown"
                result["sensorMaxRange"] = proximitySensor.maximumRange
                result["sensorResolution"] = proximitySensor.resolution
            }

            println("Proximity sensor check: $result")
            return result
        } catch (e: Exception) {
            println("Error checking proximity sensor: $e")
            return mapOf(
                "hasProximitySensor" to false,
                "hasProximityWakeLock" to false,
                "error" to e.message.toString()
            )
        }
    }

    private fun handleCallIntent(intent: Intent) {
        val action = intent.action
        if (action == "com.vant.chat.ANSWER_CALL" || action == "com.vant.chat.DECLINE_CALL") {
            pendingCallAction = action
            pendingCallData = mapOf(
                "call_id" to (intent.getStringExtra("call_id") ?: ""),
                "room_id" to (intent.getStringExtra("room_id") ?: ""),
                "caller_name" to (intent.getStringExtra("caller_name") ?: ""),
                "caller_id" to (intent.getStringExtra("caller_id") ?: ""),
                "is_video" to (intent.getBooleanExtra("is_video", false)).toString()
            )
            cancelCallNotification()
            println("Pending call action captured: $pendingCallAction")
        }
    }

    private fun cancelCallNotification() {
        try {
            val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            notificationManager.cancel(VantFirebaseMessagingService.NOTIFICATION_ID)
        } catch (e: Exception) {
            println("Error cancelling call notification: $e")
        }
    }

    private fun showIncomingCall(callerName: String, callId: String, callerId: String) {
        try {
            val intent = Intent(this, CallForegroundService::class.java).apply {
                action = CallForegroundService.ACTION_START_RINGING
                putExtra("caller_name", callerName)
                putExtra("call_id", callId)
                putExtra("caller_id", callerId)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(intent)
            } else {
                startService(intent)
            }
            println("Call foreground service started for: $callerName")
        } catch (e: Exception) {
            println("Error starting call foreground service: $e")
        }
    }

    private fun stopIncomingCall() {
        try {
            val intent = Intent(this, CallForegroundService::class.java).apply {
                action = CallForegroundService.ACTION_STOP_RINGING
            }
            // Use regular startService for the stop action. The service is already
            // foreground (if it was running) and only needs to run onStartCommand to
            // clean up; startForegroundService would re-impose the 5-second
            // startForeground() deadline and can crash on busy cold-start paths.
            startService(intent)
            cancelCallNotification()
            println("Call foreground service stopped")
        } catch (e: Exception) {
            println("Error stopping call foreground service: $e")
        }
    }
}
