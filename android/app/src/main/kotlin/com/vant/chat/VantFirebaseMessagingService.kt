package com.vant.chat

import android.app.ActivityManager
import android.app.KeyguardManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.embedding.engine.loader.FlutterLoader
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.FlutterCallbackInformation
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Custom FCM service that extends FirebaseMessagingService directly (NOT
 * FlutterFirebaseMessagingService) to avoid R8/ProGuard stripping parent
 * class methods when building an App Bundle for the Play Store.
 *
 * Call messages (incoming_call, call_cancelled, missed_call) are handled
 * natively. All other messages are forwarded to Flutter's background
 * message handler via a dedicated background FlutterEngine.
 */
class VantFirebaseMessagingService : FirebaseMessagingService() {

    companion object {
        const val TAG = "VantFCM"
        const val CHANNEL_ID = "vant_chat_calls"
        const val NOTIFICATION_ID = 9999
        const val MISSED_CALL_CHANNEL_ID = "missed_call_channel"
        const val MISSED_CALL_NOTIFICATION_ID = 2001

        /** Engine cached while the phone rings so Accept can attach a warm one. */
        const val CALL_PREWARM_ENGINE_ID = "vant_call_prewarm"
        const val PREWARM_TIMEOUT_MS = 75_000L

        private val flutterEngineStarted = AtomicBoolean(false)
        private var backgroundFlutterEngine: FlutterEngine? = null
        private val mainHandler = Handler(Looper.getMainLooper())
        private var prewarmTimeoutRunnable: Runnable? = null

        /**
         * Remove + destroy the ringing-time pre-warm engine. Safe to call from
         * any thread; no-op once MainActivity has attached it (the engine is
         * removed from the cache on attach, so get() returns null).
         */
        fun discardPrewarmEngine() {
            mainHandler.post {
                prewarmTimeoutRunnable?.let { mainHandler.removeCallbacks(it) }
                prewarmTimeoutRunnable = null
                val cache = FlutterEngineCache.getInstance()
                cache.get(CALL_PREWARM_ENGINE_ID)?.let { stale ->
                    cache.remove(CALL_PREWARM_ENGINE_ID)
                    stale.destroy()
                    Log.d(TAG, "callUX: pre-warm engine discarded")
                }
            }
        }
    }

    override fun onMessageReceived(remoteMessage: RemoteMessage) {
        super.onMessageReceived(remoteMessage)

        val data = remoteMessage.data
        val type = data["type"]

        Log.d(TAG, "📞 FCM received: type=$type, data=$data")

        when (type) {
            "incoming_call" -> handleIncomingCall(data)
            "call_cancelled" -> handleCallCancelled(data)
            "missed_call" -> handleMissedCall(data)
            else -> {
                Log.d(TAG, "ℹ️ Non-call message received: $type, forwarding to Flutter")
                forwardToFlutter(remoteMessage)
            }
        }
    }

    // ==================== FLUTTER BACKGROUND FORWARDING ====================

    /**
     * Forward non-call messages to Flutter's background message handler.
     * This replaces the old super.onMessageReceived() from FlutterFirebaseMessagingService.
     * We spin up a background FlutterEngine (if not already running) and invoke the
     * registered Dart background callback via MethodChannel.
     */
    private fun forwardToFlutter(remoteMessage: RemoteMessage) {
        try {
            val prefs = getSharedPreferences(
                "io.flutter.firebase.messaging.callback",
                Context.MODE_PRIVATE
            )
            val callbackHandle = prefs.getLong("callback_handle", 0L)

            if (callbackHandle == 0L) {
                Log.w(TAG, "No Flutter background callback registered. Message dropped.")
                return
            }

            // Never spin up a second engine during a ringing/active call — it
            // would compete for CPU/audio resources and run plugin init while
            // the user is on the call screen.
            if (VantCallManager.activeConnection != null) {
                Log.d(TAG, "Call in progress — deferring background forwarding")
                return
            }

            // FlutterLoader.startInitialization must run on the main thread —
            // onMessageReceived arrives on a worker thread, so hop over before
            // touching the engine. Everything downstream (MethodChannel invoke)
            // must be on the main thread anyway.
            Handler(Looper.getMainLooper()).post {
                try {
                    // Burst-safe: posts are serialized on the main thread and
                    // startFlutterBackgroundEngine sets this flag only after a
                    // successful start, so a burst of pushes can never create
                    // more than one engine.
                    if (!flutterEngineStarted.get()) {
                        startFlutterBackgroundEngine(callbackHandle)
                    }
                    val engine = backgroundFlutterEngine
                    if (engine != null) {
                        val channel = MethodChannel(
                            engine.dartExecutor.binaryMessenger,
                            "plugins.flutter.io/firebase_messaging_background"
                        )

                        val messageMap = mutableMapOf<String, Any?>(
                            "data" to remoteMessage.data,
                            "messageId" to remoteMessage.messageId,
                            "sentTime" to remoteMessage.sentTime,
                            "from" to remoteMessage.from,
                            "ttl" to remoteMessage.ttl
                        )

                        remoteMessage.notification?.let { notification ->
                            messageMap["notification"] = mapOf(
                                "title" to notification.title,
                                "body" to notification.body
                            )
                        }

                        channel.invokeMethod("MessagingBackground#onMessage", messageMap)
                        Log.d(TAG, "Message forwarded to Flutter background handler")
                    } else {
                        Log.w(TAG, "Background engine unavailable, message dropped")
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "Error forwarding to Flutter on main thread: ${e.message}", e)
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error forwarding to Flutter: ${e.message}", e)
        }
    }

    private fun startFlutterBackgroundEngine(callbackHandle: Long) {
        try {
            if (flutterEngineStarted.get()) return

            val flutterLoader = FlutterLoader()
            if (!flutterLoader.initialized()) {
                flutterLoader.startInitialization(applicationContext)
            }
            flutterLoader.ensureInitializationComplete(applicationContext, null)

            val callbackInfo = FlutterCallbackInformation.lookupCallbackInformation(callbackHandle)
            if (callbackInfo == null) {
                Log.e(TAG, "Could not find Flutter callback information for handle: $callbackHandle")
                return
            }

            val appBundlePath = flutterLoader.findAppBundlePath()

            val engine = FlutterEngine(applicationContext)
            val args = DartExecutor.DartCallback(
                applicationContext.assets,
                appBundlePath,
                callbackInfo
            )

            engine.dartExecutor.executeDartCallback(args)
            backgroundFlutterEngine = engine
            flutterEngineStarted.set(true)

            Log.d(TAG, "Flutter background engine started for message forwarding")
        } catch (e: Exception) {
            Log.e(TAG, "Error starting Flutter background engine: ${e.message}", e)
        }
    }

    // ==================== CALL HANDLING METHODS ====================

    private fun handleIncomingCall(data: Map<String, String>) {
        val callerName = data["callerName"] ?: data["caller_name"] ?: "Unknown"
        val callerId = data["callerId"] ?: data["caller_id"] ?: ""
        val callId = data["callId"] ?: data["call_id"] ?: ""
        val roomId = data["roomId"] ?: data["room_id"] ?: ""
        val avatarUrl = data["avatarUrl"] ?: data["avatar_url"] ?: ""
        val isVideo = data["isVideo"] == "true" || data["is_video"] == "true"

        if (callId.isEmpty() || callerId.isEmpty()) {
            Log.w(TAG, "⚠️ Invalid incoming_call data: missing callId or callerId")
            return
        }

        Log.d(TAG, "📞 Incoming call from $callerName (callId=$callId)")
        VantCallManager.logIncomingCallDiagnostics(this)

        wakeUpDevice()

        if (isAppForeground() && isFlutterCallScreenVisible()) {
            Log.d(TAG, "📞 Flutter call screen already visible, skipping native UI")
            return
        }

        // If app is in foreground and unlocked, send broadcast to Flutter
        if (isAppForeground() && !isScreenLockedOrOff()) {
            Log.d(TAG, "📞 App foreground and unlocked, sending broadcast to Flutter")
            VantCallManager.startRinging(this, callerName, callerId, callId, roomId, avatarUrl, isVideo)
            sendFlutterCallBroadcast(data)
            return
        }

        // App is background/killed OR screen is locked.
        // Boot the Dart engine now so socket registration + resync + ICE
        // prefetch can complete during the ring — MainActivity attaches this
        // engine on Accept instead of cold-booting a second one.
        prewarmCallEngine(callId)

        // Make the ringing callId visible to the (headless) Dart side so it can
        // proactively fetch the offer via call_resync before Accept.
        getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            .edit()
            .putString("flutter.ringing_call_id", callId)
            .putString("flutter.ringing_caller_id", callerId)
            .apply()

        // Use Android Telecom framework (like WhatsApp) for guaranteed full-screen intent.
        Log.d(TAG, "📞 Reporting incoming call to Telecom framework")
        val telecomSuccess = VantCallManager.reportIncomingCall(
            this, callerName, callerId, callId, roomId, avatarUrl, isVideo
        )

        if (!telecomSuccess) {
            // Fallback: activity first; if it can't be launched, a notification with
            // answer/decline actions + full-screen intent is shown.
            Log.w(TAG, "📞 Telecom failed, using fallback approach")
            VantCallManager.presentIncomingCall(this, callerName, callerId, callId, roomId, avatarUrl, isVideo)
        }
    }

    /**
     * Boot the app's Dart entrypoint on a second engine while the native
     * ringing UI is up and stash it in FlutterEngineCache under
     * [CALL_PREWARM_ENGINE_ID]. CallController's onInit then connects +
     * registers the signaling socket during the ring, and MainActivity
     * attaches this warm engine on Accept. Guarded against an active call
     * and against duplicate pushes for the same ring. Destroyed by
     * [discardPrewarmEngine] (cancel/decline/end) or the timeout runnable.
     */
    private fun prewarmCallEngine(callId: String) {
        if (VantCallManager.activeConnection != null) {
            Log.d(TAG, "callUX: active call in progress — skipping engine pre-warm")
            return
        }
        if (MainActivity.isMainActivityAlive) {
            // App is already running — the main engine handles the call; a
            // second isolate would double-register the deviceId and get the
            // primary socket kicked by the server.
            Log.d(TAG, "callUX: main activity alive — skipping engine pre-warm")
            return
        }
        mainHandler.post {
            try {
                val cache = FlutterEngineCache.getInstance()
                if (cache.get(CALL_PREWARM_ENGINE_ID) != null) {
                    Log.d(TAG, "callUX: pre-warm engine already cached, reusing")
                    return@post
                }
                val loader = FlutterLoader()
                if (!loader.initialized()) {
                    loader.startInitialization(applicationContext)
                }
                loader.ensureInitializationComplete(applicationContext, null)

                val engine = FlutterEngine(applicationContext)
                engine.dartExecutor.executeDartEntrypoint(
                    DartExecutor.DartEntrypoint.createDefault()
                )
                cache.put(CALL_PREWARM_ENGINE_ID, engine)
                Log.d(TAG, "callUX: pre-warmed engine cached while ringing ($callId)")

                prewarmTimeoutRunnable = Runnable { discardPrewarmEngine() }
                mainHandler.postDelayed(prewarmTimeoutRunnable!!, PREWARM_TIMEOUT_MS)
            } catch (e: Exception) {
                Log.e(TAG, "callUX: pre-warm engine failed: ${e.message}", e)
            }
        }
    }

    private fun handleCallCancelled(data: Map<String, String>) {
        val callId = data["callId"] ?: data["call_id"] ?: ""
        Log.d(TAG, "📞 Cancelling call: $callId")

        markMissedCallForFsiPrompt()
        VantCallManager.teardownCall(this, callId)
        discardPrewarmEngine()
        clearRingingCallMarker()
    }

    private fun handleMissedCall(data: Map<String, String>) {
        val callId = data["callId"] ?: data["call_id"] ?: ""
        val callerId = data["callerId"] ?: data["caller_id"] ?: ""
        val callerName = data["callerName"] ?: data["caller_name"] ?: "Unknown"

        if (callId.isEmpty() || callerId.isEmpty()) {
            Log.w(TAG, "⚠️ Invalid missed_call data")
            return
        }

        Log.d(TAG, "📞 Showing missed call notification for $callerName")
        markMissedCallForFsiPrompt()
        discardPrewarmEngine()
        clearRingingCallMarker()
        createMissedCallChannel()

        val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        val callBackIntent = Intent(this, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            putExtra("call_action", "callback")
            putExtra("call_id", callId)
            putExtra("caller_id", callerId)
            putExtra("caller_name", callerName)
        }

        val pendingIntent = PendingIntent.getActivity(
            this,
            callId.hashCode(),
            callBackIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val notification = NotificationCompat.Builder(this, MISSED_CALL_CHANNEL_ID)
            .setContentTitle("Missed call from $callerName")
            .setContentText("Tap to call back")
            .setSmallIcon(R.drawable.ic_stat_ic_notification)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setAutoCancel(true)
            .setContentIntent(pendingIntent)
            .build()

        notificationManager.notify(MISSED_CALL_NOTIFICATION_ID + callId.hashCode(), notification)
    }

    // ==================== UTILITY METHODS ====================

    /**
     * A call the user didn't answer may mean the full-screen intent was
     * suppressed — flag it so the next app open can offer the settings prompt
     * (consumed one-shot by CallController; the prompt still only shows when
     * canUseFullScreenIntent() is false). Written into the Flutter
     * SharedPreferences backend so Dart's SharedPreferences can read it.
     */
    private fun markMissedCallForFsiPrompt() {
        getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            .edit()
            .putBoolean("flutter.fsi_prompt_after_missed_call", true)
            .apply()
    }

    private fun clearRingingCallMarker() {
        getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            .edit()
            .remove("flutter.ringing_call_id")
            .remove("flutter.ringing_caller_id")
            .apply()
    }

    private fun wakeUpDevice() {
        try {
            val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
            val wakeLock = powerManager.newWakeLock(
                PowerManager.FULL_WAKE_LOCK or
                PowerManager.ACQUIRE_CAUSES_WAKEUP or
                PowerManager.ON_AFTER_RELEASE,
                "VantChat::IncomingCallWakeLock"
            )
            wakeLock.acquire(30 * 1000L)
            wakeLock.release()
        } catch (e: Exception) {
            Log.e(TAG, "❌ Failed to wake device: $e")
        }
    }

    private fun isAppForeground(): Boolean {
        val activityManager = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val runningProcesses = activityManager.runningAppProcesses ?: return false
        for (processInfo in runningProcesses) {
            if (processInfo.importance == ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND &&
                processInfo.processName == packageName) {
                return true
            }
        }
        return false
    }

    private fun isScreenLockedOrOff(): Boolean {
        val keyguardManager = getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
        val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
        return keyguardManager.isKeyguardLocked || !powerManager.isInteractive
    }

    private fun isFlutterCallScreenVisible(): Boolean {
        val prefs = getSharedPreferences("vant_chat_prefs", Context.MODE_PRIVATE)
        return prefs.getBoolean("flutter_call_screen_visible", false)
    }

    private fun sendFlutterCallBroadcast(data: Map<String, String>) {
        sendBroadcast(Intent("com.vant.chat.SHOW_FLUTTER_CALL").apply {
            putExtra("call_id", data["callId"] ?: data["call_id"] ?: "")
            putExtra("caller_id", data["callerId"] ?: data["caller_id"] ?: "")
            putExtra("caller_name", data["callerName"] ?: data["caller_name"] ?: "Unknown")
            putExtra("room_id", data["roomId"] ?: data["room_id"] ?: "")
            putExtra("avatar_url", data["avatarUrl"] ?: data["avatar_url"] ?: "")
            putExtra("is_video", data["isVideo"] ?: data["is_video"] ?: "false")
        })
    }

    private fun createMissedCallChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                MISSED_CALL_CHANNEL_ID,
                "Missed Calls",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "Notifications for missed calls"
            }
            val notificationManager = getSystemService(NotificationManager::class.java)
            notificationManager.createNotificationChannel(channel)
        }
    }

    override fun onNewToken(token: String) {
        super.onNewToken(token)
        Log.d(TAG, "🔑 FCM token refreshed: $token")
    }
}
