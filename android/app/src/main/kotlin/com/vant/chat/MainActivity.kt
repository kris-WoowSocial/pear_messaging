package com.vant.chat

import android.app.NotificationManager
import android.app.PictureInPictureParams
import android.content.Intent
import android.content.res.Configuration
import android.graphics.Rect
import android.net.Uri
import android.os.Build
import android.util.Log
import android.util.Rational
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorManager
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.ToneGenerator
import android.provider.Settings
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView
import android.graphics.Color
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.EventChannel

class MainActivity : FlutterFragmentActivity() {
    companion object {
        /**
         * Live MainActivity count. While > 0 the app's primary engine (and
         * therefore its CallController + signaling socket) is running, so the
         * FCM service must NOT pre-warm a second engine — a duplicate isolate
         * would register the same deviceId on the socket and the server kicks
         * the main connection, which killed the warm-call signaling.
         */
        @Volatile private var liveInstanceCount = 0
        val isMainActivityAlive: Boolean get() = liveInstanceCount > 0

        // ---- Picture-in-Picture state (video calls, ff_pip_android) ----
        // Logcat tag for every PiP decision — filter `adb logcat -s VantPip`.
        const val PIP_TAG = "VantPip"
        /** True while the activity is actually in PiP (from
         *  onPictureInPictureModeChanged). Volatile so Dart's synchronous
         *  query and any lifecycle thread see the same value. */
        @Volatile var isInPipMode = false
            private set
        /** Set BEFORE enterPictureInPictureMode() so Dart can distinguish a
         *  PiP-entry `paused` lifecycle event from real backgrounding. */
        @Volatile var pipEntering = false
            private set
    }

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
    private var callAudioFocusRequest: AudioFocusRequest? = null
    private var callTransitionOverlay: View? = null
    private val callOverlayHandler = Handler(Looper.getMainLooper())
    // The fragment's getFlutterEngine() NPEs while the delegate is unattached —
    // cache the engine here instead so call-intent pushes can safely check it.
    private var attachedEngine: FlutterEngine? = null
    private var usedPrewarmEngine = false
    private var pendingPushRetries = 0

    // PiP: Dart flips pipEligible only while a connected video call is up.
    // pipRatio tracks the remote video aspect (9:16 fallback).
    private var pipEligible = false
    private var pipRatioW = 9
    private var pipRatioH = 16
    // PiP exit classification: onPictureInPictureModeChanged(false) alone
    // can't tell "expanded to full screen" (onResume follows) from
    // "dismissed with X" (onStop follows). Dart-side lifecycle events
    // arrive too late to distinguish them — decide here by event ordering:
    // whichever of onResume/onStop arrives first wins; a 1.5s fallback
    // covers OEMs that stop short of onStop.
    @Volatile private var pipExitAwaitingResume = false
    private val pipOutcomeHandler = Handler(Looper.getMainLooper())
    private val pipOutcomeCheck = Runnable {
        if (pipExitAwaitingResume) {
            pipExitAwaitingResume = false
            emitPipOutcome("dismissed", "timeout-fallback")
        }
    }

    /**
     * If the FCM service pre-warmed an engine while the phone was ringing,
     * attach it instead of booting a fresh one — this is what collapses the
     * ~5s cold-start engine wait after Accept. Only returned while the engine
     * is actually in the cache (the delegate throws if we name a missing id).
     */
    override fun getCachedEngineId(): String? {
        return if (FlutterEngineCache.getInstance()
                .contains(VantFirebaseMessagingService.CALL_PREWARM_ENGINE_ID)
        ) VantFirebaseMessagingService.CALL_PREWARM_ENGINE_ID else null
    }

    /**
     * Cached engines default to outliving the host activity. The pre-warm
     * engine is owned by this call — destroy it with the activity exactly
     * like a cold-booted engine so Dart/media/plugins can't linger after
     * the call ends.
     */
    override fun shouldDestroyEngineWithHost(): Boolean {
        return getCachedEngineId() != null || super.shouldDestroyEngineWithHost()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        liveInstanceCount++

        // Cold-start answer: the engine needs ~5s to boot — cover the blank
        // window with a native "Connecting…" surface until the first frame.
        if (intent?.action == "com.vant.chat.ANSWER_CALL") {
            showCallTransitionOverlay()
        }

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
        attachedEngine = flutterEngine

        // If this is the ringing-time pre-warm engine, detach it from the
        // cache — the activity owns its lifecycle from here (destroyed with
        // the activity/call teardown, matching a cold-booted engine).
        if (flutterEngine === FlutterEngineCache.getInstance()
                .get(VantFirebaseMessagingService.CALL_PREWARM_ENGINE_ID)
        ) {
            FlutterEngineCache.getInstance()
                .remove(VantFirebaseMessagingService.CALL_PREWARM_ENGINE_ID)
            usedPrewarmEngine = true
            println("callUX: attached pre-warmed ringing engine")
        }

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
                "setAudioMode" -> {
                    val mode = call.argument<String>("mode") ?: "MODE_IN_COMMUNICATION"
                    setAudioMode(mode)
                    result.success(null)
                }
                "setTelecomAudioRoute" -> {
                    val speakerOn = call.argument<Boolean>("speakerOn") ?: false
                    VantCallManager.setAudioRoute(this, speakerOn)
                    result.success(null)
                }
                "stopRingingAndSetAudioMode" -> {
                    stopRingingAndSetAudioMode()
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
                "reportOutgoingTelecomCall" -> {
                    val calleeId = call.argument<String>("calleeId") ?: ""
                    val calleeName = call.argument<String>("calleeName") ?: "Unknown"
                    val isVideo = call.argument<Boolean>("isVideo") ?: false
                    result.success(
                        VantCallManager.reportOutgoingCall(
                            this,
                            calleeName,
                            calleeId,
                            isVideo
                        )
                    )
                }
                "markTelecomCallActive" -> {
                    VantCallManager.markActiveCall(call.argument<String>("callId") ?: "")
                    result.success(null)
                }
                "teardownAndroidCall" -> {
                    val callId = call.argument<String>("callId") ?: ""
                    result.success(teardownAndroidCall(callId))
                }
                "startOngoingCall" -> {
                    val callId = call.argument<String>("callId") ?: ""
                    val callerName = call.argument<String>("callerName") ?: "Unknown"
                    val isVideo = call.argument<Boolean>("isVideo") ?: false
                    startOngoingCallService(callId, callerName, isVideo)
                    result.success(null)
                }
                "ensureAudioMode" -> {
                    val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                    val currentMode = audioManager.mode
                    
                    if (currentMode != AudioManager.MODE_IN_COMMUNICATION) {
                        audioManager.mode = AudioManager.MODE_IN_COMMUNICATION
                        println("🔊 ensureAudioMode: Fixed from $currentMode to MODE_IN_COMMUNICATION")
                    }
                    
                    result.success(true)
                }
                "setInCall" -> {
                    val inCall = call.argument<Boolean>("inCall") ?: false
                    val callId = call.argument<String>("callId") ?: ""
                    val isVideo = call.argument<Boolean>("isVideo") ?: false
                    val prefs = getSharedPreferences("vant_chat_prefs", Context.MODE_PRIVATE)
                    prefs.edit()
                        .putBoolean("vant_in_active_call", inCall)
                        .putString("vant_active_call_id", callId)
                        .putBoolean("vant_active_call_is_video", inCall && isVideo)
                        .apply()
                    result.success(null)
                }
                // ---- Picture-in-Picture (video calls) ----
                "setPipParams" -> {
                    pipEligible = call.argument<Boolean>("enabled") ?: false
                    val w = call.argument<Int>("width") ?: 9
                    val h = call.argument<Int>("height") ?: 16
                    if (w > 0 && h > 0) {
                        pipRatioW = w
                        pipRatioH = h
                    }
                    applyPipParams()
                    Log.i(PIP_TAG, "setPipParams eligible=$pipEligible ratio=$pipRatioW:$pipRatioH")
                    result.success(null)
                }
                "isInPipMode" -> {
                    result.success(isPipActive())
                }
                "isPipEntering" -> {
                    result.success(pipEntering)
                }
                "exitPipIfActive" -> {
                    exitPipKeepingProcess()
                    result.success(null)
                }
                "pipCallEnded" -> {
                    // Call finished (local end, remote hangup, decline). Clear
                    // auto-enter so a stale Home gesture can't re-enter PiP,
                    // then close the PiP window WITHOUT finishing the activity —
                    // moveTaskToBack keeps the Flutter engine, Dart isolate and
                    // signaling socket alive like a normal Home press.
                    pipEligible = false
                    if (Build.VERSION.SDK_INT >= 31) applyPipParams()
                    if (isPipActive()) {
                        Log.i(PIP_TAG, "call ended while in PiP -> moveTaskToBack")
                        exitPipKeepingProcess()
                    } else {
                        Log.i(PIP_TAG, "call ended, not in PiP")
                    }
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
                    // Call screen up → swap to it; call torn down before the
                    // screen ever mounted (cancel/decline raced the engine
                    // boot) → drop the overlay either way.
                    removeCallTransitionOverlay(
                        if (visible) "call-screen-visible" else "call-screen-hidden"
                    )
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
                "canUseFullScreenIntent" -> {
                    val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                    // canUseFullScreenIntent is only available on Android 14+ (API 34).
                    // On earlier versions the permission is implicitly granted.
                    result.success(
                        if (Build.VERSION.SDK_INT >= 34) {
                            notificationManager.canUseFullScreenIntent()
                        } else {
                            true
                        }
                    )
                }
                "openFullScreenIntentSettings" -> {
                    // API 34+ has a dedicated full-screen-intent settings page,
                    // but some OEMs don't implement it — resolve each candidate
                    // first and fall back to app notification settings, then app
                    // details.
                    val candidates = buildList {
                        if (Build.VERSION.SDK_INT >= 34) {
                            add(
                                Intent(
                                    Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT,
                                    Uri.parse("package:$packageName")
                                )
                            )
                        }
                        if (Build.VERSION.SDK_INT >= 26) {
                            add(
                                Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
                                    putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                                }
                            )
                        }
                        add(
                            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                                data = Uri.parse("package:$packageName")
                            }
                        )
                    }
                    try {
                        val resolved = candidates.firstOrNull {
                            it.resolveActivity(packageManager) != null
                        }
                        if (resolved != null) {
                            resolved.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            startActivity(resolved)
                            result.success(true)
                        } else {
                            println("No settings screen resolved for full-screen intent")
                            result.success(false)
                        }
                    } catch (e: Exception) {
                        println("Error opening full-screen intent settings: $e")
                        result.success(false)
                    }
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
        
        // Event channel: native -> Flutter for foreground call broadcasts
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                private var receiver: android.content.BroadcastReceiver? = null

                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    receiver = object : android.content.BroadcastReceiver() {
                        override fun onReceive(context: Context?, intent: Intent?) {
                            when (intent?.action) {
                                "com.vant.chat.SHOW_FLUTTER_CALL" -> {
                                    val data = hashMapOf<String, String>()
                                    intent.extras?.keySet()?.forEach { key ->
                                        data[key] = intent.getStringExtra(key) ?: ""
                                    }
                                    events?.success(data)
                                }
                                "com.vant.chat.CALL_HELD" -> {
                                    events?.success(hashMapOf("type" to "call_held"))
                                }
                                "com.vant.chat.CALL_UNHELD" -> {
                                    events?.success(hashMapOf("type" to "call_unheld"))
                                }
                                "com.vant.chat.PIP_CHANGED" -> {
                                    events?.success(
                                        hashMapOf(
                                            "type" to "pip_changed",
                                            "is_pip" to (intent.getStringExtra("is_pip") ?: "false")
                                        )
                                    )
                                }
                                "com.vant.chat.PIP_OUTCOME" -> {
                                    events?.success(
                                        hashMapOf(
                                            "type" to "pip_outcome",
                                            "outcome" to (intent.getStringExtra("outcome") ?: "dismissed")
                                        )
                                    )
                                }
                            }
                        }
                    }
                    val filter = android.content.IntentFilter().apply {
                        addAction("com.vant.chat.SHOW_FLUTTER_CALL")
                        addAction("com.vant.chat.CALL_HELD")
                        addAction("com.vant.chat.CALL_UNHELD")
                        addAction("com.vant.chat.PIP_CHANGED")
                        addAction("com.vant.chat.PIP_OUTCOME")
                    }
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        registerReceiver(
                            receiver,
                            filter,
                            android.content.Context.RECEIVER_NOT_EXPORTED
                        )
                    } else {
                        registerReceiver(receiver, filter)
                    }
                    callEventsReceiver = receiver
                }

                override fun onCancel(arguments: Any?) {
                    receiver?.let { unregisterReceiver(it) }
                    callEventsReceiver = null
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

        // Engine attached — push any call action captured before attach
        // (cold-start answer). On a pre-warmed engine Dart may still be
        // registering its handler, so retry briefly on notImplemented.
        if (pendingCallAction != null) {
            pushPendingCallActionToDart()
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

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) {
            val keyguardManager = getSystemService(Context.KEYGUARD_SERVICE) as android.app.KeyguardManager
            if (!keyguardManager.isKeyguardLocked) {
                // Device is unlocked, we do not want to stay on top of the lock screen.
                clearShowWhenLocked()
                println("onWindowFocusChanged: unlocked, showWhenLocked cleared")
            }
        }
    }

    // ==================== Picture-in-Picture ====================

    private fun isPipActive(): Boolean {
        return Build.VERSION.SDK_INT >= 26 && isInPictureInPictureMode
    }

    /** Build PiP params from the last Dart-supplied remote aspect ratio,
     *  clamped to Android's allowed range (~0.39 - 2.59). */
    private fun buildPipParams(): PictureInPictureParams? {
        if (Build.VERSION.SDK_INT < 26) return null
        val raw = pipRatioW.toFloat() / pipRatioH.toFloat()
        val clamped = raw.coerceIn(0.39f, 2.59f)
        val h = 1000
        val w = (clamped * h).toInt().coerceAtLeast(1)
        val builder = PictureInPictureParams.Builder()
            .setAspectRatio(Rational(w, h))
            .setSourceRectHint(Rect(0, 0, 1, 1)) // whole-window transition
        if (Build.VERSION.SDK_INT >= 31) {
            builder.setAutoEnterEnabled(pipEligible)
        }
        return builder.build()
    }

    /** Push current params to the system. On API 31+ this is also where
     *  auto-enter is armed/disarmed. */
    private fun applyPipParams() {
        if (Build.VERSION.SDK_INT < 26) return
        if (isFinishing || isDestroyed) return
        val params = buildPipParams() ?: return
        try {
            setPictureInPictureParams(params)
            if (Build.VERSION.SDK_INT >= 31) {
                Log.i(PIP_TAG, "autoEnter=${pipEligible}")
            }
        } catch (e: Exception) {
            Log.w(PIP_TAG, "setPictureInPictureParams failed: ${e.message}")
        }
    }

    /** API 26-30 entry path (31+ uses setAutoEnterEnabled). Dart has already
     *  gated eligibility through setPipParams — if pipEligible is true all
     *  conditions (video call, connected, flag, call UI visible) hold. */
    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (Build.VERSION.SDK_INT in 26..30 && pipEligible && !isPipActive()) {
            Log.i(PIP_TAG, "onUserLeaveHint -> pipEntering=true, enterPiP")
            pipEntering = true
            try {
                enterPictureInPictureMode(buildPipParams()!!)
            } catch (e: Exception) {
                pipEntering = false
                Log.w(PIP_TAG, "enterPictureInPictureMode failed: ${e.message}")
            }
        }
    }

    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: Configuration
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        isInPipMode = isInPictureInPictureMode
        pipEntering = false
        Log.i(
            PIP_TAG,
            if (isInPictureInPictureMode) "pip enter" else "pip exit"
        )
        // Forward to Dart via the existing call_events EventChannel receiver.
        try {
            val intent = Intent("com.vant.chat.PIP_CHANGED")
                .setPackage(packageName)
                .putExtra("is_pip", isInPictureInPictureMode.toString())
            sendBroadcast(intent)
        } catch (e: Exception) {
            Log.w(PIP_TAG, "pip_changed broadcast failed: ${e.message}")
        }
        if (!isInPictureInPictureMode) {
            // Expanded vs dismissed is decided by lifecycle event order:
            // onResume -> expanded, onStop -> dismissed, 1.5s -> dismissed.
            pipExitAwaitingResume = true
            pipOutcomeHandler.removeCallbacks(pipOutcomeCheck)
            pipOutcomeHandler.postDelayed(pipOutcomeCheck, 1500)
        }
    }

    override fun onResume() {
        super.onResume()
        // A pip exit followed by onResume is an expand, not an X-dismiss.
        if (pipExitAwaitingResume) {
            pipExitAwaitingResume = false
            pipOutcomeHandler.removeCallbacks(pipOutcomeCheck)
            emitPipOutcome("expanded", "onResume-first")
        }
    }

    override fun onStop() {
        super.onStop()
        // A pip exit followed by onStop means the window was dismissed (X)
        // or the task was backgrounded — not an expand.
        if (pipExitAwaitingResume) {
            pipExitAwaitingResume = false
            pipOutcomeHandler.removeCallbacks(pipOutcomeCheck)
            emitPipOutcome("dismissed", "onStop-first")
        }
    }

    // Activity-owned handle to the call_events stream receiver so onDestroy
    // can unregister it when Dart cancels nothing (activity destroyed while
    // the event stream is still subscribed). Fixes the leaked-IntentReceiver
    // warning on teardown.
    @Volatile private var callEventsReceiver: android.content.BroadcastReceiver? = null

    private fun emitPipOutcome(outcome: String, via: String) {
        Log.i(PIP_TAG, "pip outcome: $outcome ($via)")
        try {
            sendBroadcast(
                Intent("com.vant.chat.PIP_OUTCOME")
                    .setPackage(packageName)
                    .putExtra("outcome", outcome)
            )
        } catch (e: Exception) {
            Log.w(PIP_TAG, "pip_outcome broadcast failed: ${e.message}")
        }
    }

    /** Close the PiP window without destroying the Flutter engine/Dart
     *  isolate: moveTaskToBack keeps the process, socket and FGS alive —
     *  the same mechanism as pressing Home. NEVER finish() here. */
    private fun exitPipKeepingProcess() {
        if (isPipActive()) {
            Log.i(PIP_TAG, "exitPip -> moveTaskToBack")
            moveTaskToBack(true)
        }
    }
    
    private fun handleIntent(intent: Intent) {
        try {
            // Handle call actions or full-screen launch from native service
            val callAction = intent.getStringExtra("call_action")
            val showIncomingCall = intent.getBooleanExtra("show_incoming_call", false)
            val intentAction = intent.action
            val isAnswerDecline = intentAction == "com.vant.chat.ANSWER_CALL" ||
                                  intentAction == "com.vant.chat.DECLINE_CALL" ||
                                  intentAction == "com.vant.chat.END_CALL"
            val isOpenOngoing = intentAction == "com.vant.chat.OPEN_ONGOING_CALL"
            val callId = intent.getStringExtra("call_id") ?: ""
            val callerId = intent.getStringExtra("caller_id") ?: ""
            val callerName = intent.getStringExtra("caller_name") ?: ""
            val roomId = intent.getStringExtra("room_id") ?: ""
            val avatarUrl = intent.getStringExtra("avatar_url") ?: ""
            val isVideo = intent.getBooleanExtra("is_video", false)
            
            val action = when {
                isAnswerDecline -> when (intentAction) {
                    "com.vant.chat.ANSWER_CALL" -> "answer"
                    "com.vant.chat.DECLINE_CALL" -> "decline"
                    else -> "end"
                }
                isOpenOngoing -> "open_ongoing_call"
                callAction != null -> callAction
                showIncomingCall -> "show_incoming_call"
                else -> null
            }
            
            if (action != null) {
                println("Call intent received: action=$action, callId=$callId")
                if (action == "end" || action == "decline") {
                    teardownAndroidCall(callId)
                }
                
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
                        "isVideo" to isVideo,
                        "answeredFromBackground" to intent.getBooleanExtra("answered_from_background", false)
                    )
                    channel.invokeMethod("onCallAction", arguments)
                    println("Call action sent to Flutter successfully: $action, answeredFromBackground=${intent.getBooleanExtra("answered_from_background", false)}")
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

    /**
     * Stop the ringing foreground service, tell Telecom the call is ACTIVE,
     * and set MODE_IN_COMMUNICATION.
     *
     * IMPORTANT: This method must NOT request audio focus or set communication device.
     * AudioSwitch (inside flutter_webrtc) is the sole owner of audio focus and device
     * routing. If we request AUDIOFOCUS_GAIN_TRANSIENT_EXCLUSIVE or call
     * setCommunicationDevice(earpiece) here, AudioSwitch initializes into a corrupted
     * state where it thinks it selected Speakerphone but the OS route is locked to earpiece.
     */
    private fun stopRingingAndSetAudioMode() {
        try {
            // 1. CRITICAL: Tell Telecom the call is now ACTIVE. Without this, the
            // self-managed VantConnection stays in RINGING state and the system
            // audio router keeps forcing MODE_RINGTONE on the audio subsystem.
            VantCallManager.activeConnection?.let { connection ->
                connection.setActive()
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    connection.setAudioModeIsVoip(true)
                }
                println("🔊 stopRingingAndSetAudioMode: Telecom connection set to ACTIVE + VoIP")
            }
        } catch (e: Exception) {
            println("⚠️ Error setting Telecom connection active: $e")
        }

        try {
            // 2. Stop the ringtone, vibration, and foreground service
            val stopIntent = Intent(this, CallForegroundService::class.java).apply {
                action = CallForegroundService.ACTION_STOP_RINGING
            }
            startService(stopIntent)
            cancelCallNotification()
            println("🔊 stopRingingAndSetAudioMode: ringing stopped")
        } catch (e: Exception) {
            println("⚠️ Error stopping ringing: $e")
        }

        try {
            // 3. Set MODE_IN_COMMUNICATION so WebRTC's AudioTrack is created under
            // the correct mode. AudioSwitch also sets this, but doing it early is fine.
            val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
            if (audioManager.mode != AudioManager.MODE_IN_COMMUNICATION) {
                audioManager.mode = AudioManager.MODE_IN_COMMUNICATION
            }
            println("🔊 stopRingingAndSetAudioMode: MODE_IN_COMMUNICATION set")
        } catch (e: Exception) {
            println("⚠️ Error setting audio mode after stopping ringing: $e")
        }
    }

    private fun setAudioMode(mode: String) {
        try {
            val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
            val audioMode = when (mode) {
                "MODE_IN_COMMUNICATION" -> AudioManager.MODE_IN_COMMUNICATION
                "MODE_NORMAL" -> AudioManager.MODE_NORMAL
                "MODE_RINGTONE" -> AudioManager.MODE_RINGTONE
                "MODE_CALL_SCREENING" -> AudioManager.MODE_CALL_SCREENING
                else -> AudioManager.MODE_IN_COMMUNICATION
            }
            audioManager.mode = audioMode
            println("Audio mode set to $mode")
        } catch (e: Exception) {
            println("Error setting audio mode: $e")
        }
    }

    private fun setSpeakerphoneOn(on: Boolean) {
        // NO-OP: AudioSwitch (via flutter_webrtc's Helper.setSpeakerphoneOn) is the
        // sole owner of audio routing. Using setCommunicationDevice or requestAudioFocus
        // here conflicts with AudioSwitch and causes it to revert speaker selection.
        // This method is kept to avoid crashes if old Dart code paths reference it.
        println("🔊 setSpeakerphoneOn($on) - ignored, AudioSwitch manages routing")
    }

    private fun startOngoingCallService(callId: String, callerName: String, isVideo: Boolean) {
        val intent = Intent(this, CallForegroundService::class.java).apply {
            action = CallForegroundService.ACTION_START_ONGOING_CALL
            putExtra("call_id", callId)
            putExtra("caller_name", callerName)
            putExtra("is_video", isVideo)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }

    private fun teardownAndroidCall(callId: String): Boolean {
        val tornDown = VantCallManager.teardownCall(this, callId)
        if (!tornDown) return false

        stopRingback()
        releaseProximityWakeLock()
        try {
            val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                callAudioFocusRequest?.let { audioManager.abandonAudioFocusRequest(it) }
            } else {
                @Suppress("DEPRECATION")
                audioManager.abandonAudioFocus(null)
            }
        } catch (e: Exception) {
            println("Error releasing call audio focus: $e")
        } finally {
            callAudioFocusRequest = null
        }
        return true
    }

    private fun playRingback() {
        stopRingback()
        try {
            val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
            if (audioManager.mode != AudioManager.MODE_IN_COMMUNICATION) {
                audioManager.mode = AudioManager.MODE_IN_COMMUNICATION
            }
            // DO NOT force earpiece here — AudioSwitch manages device routing.
            // The ToneGenerator will play on whatever device AudioSwitch has selected.
            // ToneGenerator on STREAM_VOICE_CALL follows the current communication routing
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
                "is_video" to (intent.getBooleanExtra("is_video", false)).toString(),
                "from_native" to (intent.getBooleanExtra("from_native", false)).toString(),
                "answered_from_background" to (intent.getBooleanExtra("answered_from_background", false)).toString()
            )
            
            // If answered from native screen (or system UI while in background),
            // stop ringing and force MODE_IN_COMMUNICATION immediately so WebRTC's
            // AudioTrack is not created under MODE_RINGTONE.
            val fromNative = intent.getBooleanExtra("from_native", false)
            val answeredFromBackground = intent.getBooleanExtra("answered_from_background", false)
            if ((fromNative || answeredFromBackground) && action == "com.vant.chat.ANSWER_CALL") {
                // CRITICAL: Tell Telecom the call is now ACTIVE. Without this, the
                // self-managed VantConnection stays in RINGING state and the system
                // audio router keeps forcing MODE_RINGTONE, which causes WebRTC's
                // AudioTrack to use STREAM_RING (locks audio to earpiece).
                VantCallManager.activeConnection?.let { connection ->
                    connection.setActive()
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        connection.setAudioModeIsVoip(true)
                    }
                    println("🔊 handleCallIntent: Telecom connection set to ACTIVE + VoIP mode")
                }
                stopRingingAndSetAudioMode()
                println("🔊 handleCallIntent: Stopped ringing and forced MODE_IN_COMMUNICATION (native/bg)")
            }
            
            cancelCallNotification()
            println("Pending call action captured: $pendingCallAction, from_native: $fromNative, answeredFromBackground: $answeredFromBackground")

            if (action == "com.vant.chat.DECLINE_CALL") {
                // Paranoid cleanup — the overlay only ever shows for ANSWER,
                // but never leave it up if state got crossed.
                removeCallTransitionOverlay("decline")
            }

            // If the engine is already attached (warm activity receiving this
            // intent via onNewIntent, or a pre-warmed engine just attached),
            // nudge Dart to consume the pending action immediately instead of
            // waiting for the next onReady poll. The stored flag is only
            // cleared when Dart calls getPendingCallAction, so a failed/early
            // push still leaves the poll as fallback.
            pushPendingCallActionToDart()
        }
    }

    /**
     * Push `onPendingCallAction` to Dart. If the engine was pre-warmed during
     * ringing, CallController may still be mid-boot when ANSWER arrives, so a
     * notImplemented/error response is retried a few times — the pending
     * action stays stored until Dart actually reads it.
     */
    private fun pushPendingCallActionToDart() {
        val engine = attachedEngine ?: return
        try {
            MethodChannel(
                engine.dartExecutor.binaryMessenger,
                INCOMING_CALL_CHANNEL
            ).invokeMethod(
                "onPendingCallAction",
                null,
                object : MethodChannel.Result {
                    override fun success(result: Any?) {
                        pendingPushRetries = 0
                        println("callUX: pushed onPendingCallAction to attached engine")
                    }

                    override fun error(code: String, msg: String?, details: Any?) {
                        retryPendingPush("error:$code")
                    }

                    override fun notImplemented() {
                        retryPendingPush("notImplemented")
                    }
                }
            )
        } catch (e: Exception) {
            retryPendingPush("exception:${e.message}")
        }
    }

    private fun retryPendingPush(why: String) {
        if (pendingCallAction == null || pendingPushRetries >= 10) return
        pendingPushRetries++
        callOverlayHandler.postDelayed({ pushPendingCallActionToDart() }, 500)
        println("callUX: pending-action push $why, retry $pendingPushRetries")
    }

    /**
     * Show a dark "Connecting…" surface over the window while a cold-started
     * Flutter engine boots after answering from the native incoming-call UI.
     * Matches the call screens' black background so the hand-off reads as one
     * continuous surface instead of a black flash. Removed on the first
     * rendered Flutter frame (with a timeout safeguard).
     */
    private fun showCallTransitionOverlay() {
        if (callTransitionOverlay != null) return
        println("callUX: showing connect overlay for cold-start answer")
        val label = TextView(this).apply {
            text = "Connecting…"
            setTextColor(Color.WHITE)
            textSize = 16f
            gravity = Gravity.CENTER
            val pad = (16 * resources.displayMetrics.density).toInt()
            setPadding(0, pad, 0, 0)
        }
        val column = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            addView(ProgressBar(this@MainActivity))
            addView(label)
        }
        val overlay = FrameLayout(this).apply {
            setBackgroundColor(Color.BLACK)
            isClickable = true
            isFocusable = true
            addView(
                column,
                FrameLayout.LayoutParams(
                    ViewGroup.LayoutParams.WRAP_CONTENT,
                    ViewGroup.LayoutParams.WRAP_CONTENT,
                    Gravity.CENTER
                )
            )
        }
        addContentView(
            overlay,
            ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT
            )
        )
        callTransitionOverlay = overlay
        callOverlayHandler.postDelayed(
            { removeCallTransitionOverlay("timeout") },
            10_000L
        )
    }

    private fun removeCallTransitionOverlay(reason: String) {
        callTransitionOverlay?.let {
            println("callUX: removing connect overlay ($reason)")
            (it.parent as? ViewGroup)?.removeView(it)
            callTransitionOverlay = null
        }
    }

    override fun onDestroy() {
        callOverlayHandler.removeCallbacksAndMessages(null)
        callTransitionOverlay = null
        // Engine teardown for the pre-warm path is handled by
        // shouldDestroyEngineWithHost() so the delegate detaches/destroys in
        // the right order.
        callEventsReceiver?.let {
            try { unregisterReceiver(it) } catch (_: Exception) {}
            callEventsReceiver = null
        }
        usedPrewarmEngine = false
        attachedEngine = null
        liveInstanceCount--
        super.onDestroy()
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
