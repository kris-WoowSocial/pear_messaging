package com.vant.chat

import android.app.ActivityManager
import android.app.KeyguardManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.os.Build
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import io.flutter.embedding.engine.FlutterEngine
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
        private val flutterEngineStarted = AtomicBoolean(false)
        private var backgroundFlutterEngine: FlutterEngine? = null
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

        wakeUpDevice()

        if (isAppForeground() && isFlutterCallScreenVisible()) {
            Log.d(TAG, "📞 Flutter call screen already visible, skipping native UI")
            return
        }

        // If app is in foreground and unlocked, send broadcast to Flutter
        if (isAppForeground() && !isScreenLockedOrOff()) {
            Log.d(TAG, "📞 App foreground and unlocked, sending broadcast to Flutter")
            startRingingService(callerName, callerId, callId, roomId, avatarUrl, isVideo)
            sendFlutterCallBroadcast(data)
            return
        }

        // App is background/killed OR screen is locked.
        // Use Android Telecom framework (like WhatsApp) for guaranteed full-screen intent.
        Log.d(TAG, "📞 Reporting incoming call to Telecom framework")
        val telecomSuccess = VantCallManager.reportIncomingCall(
            this, callerName, callerId, callId, roomId, avatarUrl, isVideo
        )

        if (!telecomSuccess) {
            // Fallback: direct notification + activity if Telecom fails
            Log.w(TAG, "📞 Telecom failed, using fallback approach")
            startRingingService(callerName, callerId, callId, roomId, avatarUrl, isVideo)
            showCallNotification(callerName, callerId, callId, roomId, avatarUrl, isVideo)
            launchIncomingCallActivity(callerName, callerId, callId, roomId, avatarUrl, isVideo)
        }
    }

    private fun handleCallCancelled(data: Map<String, String>) {
        val callId = data["callId"] ?: data["call_id"] ?: ""
        Log.d(TAG, "📞 Cancelling call: $callId")

        // Disconnect from Telecom framework
        VantCallManager.disconnectActiveCall()
        VantCallManager.stopRinging(this)
        VantCallManager.cancelNotification(this)

        try {
            stopService(Intent(this, CallForegroundService::class.java))
        } catch (e: Exception) {
            Log.e(TAG, "⚠️ Failed to stop CallForegroundService: $e")
        }

        sendBroadcast(Intent("com.vant.chat.CANCEL_CALL").apply {
            putExtra("call_id", callId)
        })
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

    private fun startRingingService(
        callerName: String, callerId: String, callId: String,
        roomId: String, avatarUrl: String, isVideo: Boolean
    ) {
        val intent = Intent(this, CallForegroundService::class.java).apply {
            action = CallForegroundService.ACTION_START_RINGING
            putExtra("caller_name", callerName)
            putExtra("caller_id", callerId)
            putExtra("call_id", callId)
            putExtra("room_id", roomId)
            putExtra("avatar_url", avatarUrl)
            putExtra("is_video", isVideo)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
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

    // ==================== NOTIFICATION & ACTIVITY ====================

    private fun showCallNotification(
        callerName: String, callerId: String, callId: String,
        roomId: String, avatarUrl: String, isVideo: Boolean
    ) {
        createCallNotificationChannel()

        val fullScreenIntent = Intent(this, IncomingCallActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra("caller_name", callerName)
            putExtra("caller_id", callerId)
            putExtra("call_id", callId)
            putExtra("room_id", roomId)
            putExtra("avatar_url", avatarUrl)
            putExtra("is_video", isVideo)
        }

        val fullScreenPendingIntent = PendingIntent.getActivity(
            this, 0, fullScreenIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val answerIntent = Intent(this, MainActivity::class.java).apply {
            action = "com.vant.chat.ANSWER_CALL"
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra("call_id", callId)
            putExtra("room_id", roomId)
            putExtra("caller_name", callerName)
            putExtra("caller_id", callerId)
            putExtra("is_video", isVideo)
        }
        val answerPendingIntent = PendingIntent.getActivity(
            this, 1, answerIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val declineIntent = Intent(this, MainActivity::class.java).apply {
            action = "com.vant.chat.DECLINE_CALL"
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra("call_id", callId)
            putExtra("caller_id", callerId)
        }
        val declinePendingIntent = PendingIntent.getActivity(
            this, 2, declineIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val ringtoneUri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)

        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(if (isVideo) "Incoming video call" else "Incoming call")
            .setContentText(callerName)
            .setSmallIcon(R.drawable.ic_call_notification)
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setFullScreenIntent(fullScreenPendingIntent, true)
            .setContentIntent(fullScreenPendingIntent)
            .setOngoing(true)
            .setAutoCancel(false)
            .setSound(ringtoneUri)
            .addAction(R.drawable.ic_call_answer, "Answer", answerPendingIntent)
            .addAction(R.drawable.ic_call_end, "Decline", declinePendingIntent)
            .build()

        val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        notificationManager.notify(NOTIFICATION_ID, notification)
    }

    private fun launchIncomingCallActivity(
        callerName: String, callerId: String, callId: String,
        roomId: String, avatarUrl: String, isVideo: Boolean
    ) {
        try {
            val intent = Intent(this, IncomingCallActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                        Intent.FLAG_ACTIVITY_CLEAR_TOP or
                        Intent.FLAG_ACTIVITY_EXCLUDE_FROM_RECENTS or
                        Intent.FLAG_ACTIVITY_CLEAR_TASK
                putExtra("caller_name", callerName)
                putExtra("caller_id", callerId)
                putExtra("call_id", callId)
                putExtra("room_id", roomId)
                putExtra("avatar_url", avatarUrl)
                putExtra("is_video", isVideo)
            }
            startActivity(intent)
            Log.d(TAG, "✅ Launched IncomingCallActivity")
        } catch (e: Exception) {
            Log.e(TAG, "❌ Failed to launch IncomingCallActivity: $e")
        }
    }

    private fun createCallNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val ringtoneUri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
            val channel = NotificationChannel(
                CHANNEL_ID, "Incoming Calls", NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "Incoming voice and video calls"
                lockscreenVisibility = NotificationCompat.VISIBILITY_PUBLIC
                setSound(ringtoneUri, AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build())
                enableVibration(true)
                vibrationPattern = longArrayOf(0, 1000, 1000)
            }
            val notificationManager = getSystemService(NotificationManager::class.java)
            notificationManager.createNotificationChannel(channel)
        }
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
