package com.vant.chat

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.media.AudioManager
import android.media.Ringtone
import android.media.RingtoneManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.os.VibrationEffect
import android.os.Vibrator
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat

/**
 * Foreground service for incoming call ringing.
 *
 * Uses `shortService` foreground type on Android 14+ because:
 * - `phoneCall` requires MANAGE_OWN_CALLS or ROLE_DIALER
 * - `microphone` requires RECORD_AUDIO runtime permission AND app must be in foreground
 * - `shortService` has no special permission requirements, can run ~3 min (enough for ringing),
 *   and can be started from background (FCM message handler)
 *
 * The microphone foreground-service type is used while an answered call is active.
 * Video calls additionally use the camera foreground-service type so capture can
 * continue while the app is minimized.
 */
class CallForegroundService : Service() {

    companion object {
        const val TAG = "VantCallFG"
        // v2: v1 carried a ringtone the app could not silence per-call, and a
        // channel's sound/importance can never be changed once created. The
        // v2 channel has no sound — the service's own Ringtone is the single
        // sound source, so there is no double ring.
        const val CHANNEL_ID = "vant_chat_calls_v2"
        const val ONGOING_CHANNEL_ID = "vant_ongoing_calls"
        const val NOTIFICATION_ID = 9999
        const val ONGOING_NOTIFICATION_ID = 8888
        const val ACTION_START_RINGING = "com.vant.chat.START_RINGING"
        const val ACTION_STOP_RINGING = "com.vant.chat.STOP_RINGING"
        const val ACTION_START_ONGOING_CALL = "com.vant.chat.START_ONGOING_CALL"
        const val ACTION_STOP_ONGOING_CALL = "com.vant.chat.STOP_ONGOING_CALL"

        /**
         * Create the call notification channels. Called from
         * MainApplication.onCreate so the channels exist before the first call
         * (users can configure them in system settings and diagnostics can read
         * them), and again from Service.onCreate as a fallback. Idempotent.
         */
        fun createNotificationChannels(context: Context) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val notificationManager = context.getSystemService(NotificationManager::class.java)

                val callChannel = NotificationChannel(
                    CHANNEL_ID, "Incoming Calls", NotificationManager.IMPORTANCE_HIGH
                ).apply {
                    description = "Incoming voice and video calls"
                    lockscreenVisibility = NotificationCompat.VISIBILITY_PUBLIC
                    // No channel sound — CallForegroundService's Ringtone is
                    // the single sound source. No channel vibration either —
                    // the service's Vibrator (same pattern) is the single
                    // vibration source; both firing would double-buzz.
                    setSound(null, null)
                    enableVibration(false)
                }

                // Drop the stale v1 channel so existing installs don't see a
                // duplicate "Incoming Calls" entry in system settings. No-op
                // if it was never created.
                notificationManager.deleteNotificationChannel("vant_chat_calls")

                val ongoingChannel = NotificationChannel(
                    ONGOING_CHANNEL_ID, "Ongoing Calls", NotificationManager.IMPORTANCE_LOW
                ).apply {
                    description = "Shown while a call is in progress"
                    setSound(null, null)
                    enableVibration(false)
                    setShowBadge(false)
                }

                notificationManager.createNotificationChannel(callChannel)
                notificationManager.createNotificationChannel(ongoingChannel)
            }
        }
    }

    private var wakeLock: PowerManager.WakeLock? = null
    private var vibrator: Vibrator? = null
    private var ringtone: Ringtone? = null

    private var ongoingCallId: String? = null
    private var ongoingCallerName: String = "Unknown"
    private var ongoingIsVideo: Boolean = false
    private var ongoingStartTime: Long = 0
    private var isOngoingCall: Boolean = false

    override fun onCreate() {
        super.onCreate()
        createNotificationChannels(this)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Log.d(TAG, "onStartCommand: action=${intent?.action}")

        val action = intent?.action ?: ACTION_START_RINGING
        when (action) {
            ACTION_STOP_RINGING -> {
                stopRinging()
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_STOP_ONGOING_CALL -> {
                stopOngoingCall()
                return START_NOT_STICKY
            }
            ACTION_START_ONGOING_CALL -> {
                startOngoingCall(intent)
                return START_STICKY
            }
            else -> {
                // Default: incoming call ringing
                // CRITICAL: Start foreground IMMEDIATELY before anything else.
                // Android 14+ requires this within 5 seconds of startForegroundService().
                val callerName = intent?.getStringExtra("caller_name") ?: "Unknown"
                val callerId = intent?.getStringExtra("caller_id") ?: ""
                val callId = intent?.getStringExtra("call_id") ?: ""
                val roomId = intent?.getStringExtra("room_id") ?: ""
                val avatarUrl = intent?.getStringExtra("avatar_url") ?: ""
                val isVideo = intent?.getBooleanExtra("is_video", false) ?: false

                val notification = buildCallNotification(callerName, callerId, callId, roomId, avatarUrl, isVideo)

                try {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                        ServiceCompat.startForeground(
                            this,
                            NOTIFICATION_ID,
                            notification,
                            ServiceInfo.FOREGROUND_SERVICE_TYPE_SHORT_SERVICE
                        )
                        Log.d(TAG, "Started foreground with SHORT_SERVICE type")
                    } else {
                        startForeground(NOTIFICATION_ID, notification)
                        Log.d(TAG, "Started foreground (pre-API 34)")
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "Failed to start foreground: ${e.message}", e)
                    try {
                        startForeground(NOTIFICATION_ID, notification)
                    } catch (e2: Exception) {
                        Log.e(TAG, "Fallback startForeground also failed: ${e2.message}", e2)
                        stopSelf()
                        return START_NOT_STICKY
                    }
                }

                startRinging(callId)
                return START_NOT_STICKY
            }
        }
    }

    override fun onTimeout(startId: Int) {
        // Called on Android 14+ when shortService timeout (~3 min) expires.
        // Stop the ringing — if nobody answered in 3 minutes, it's a missed call.
        Log.d(TAG, "shortService timeout reached, stopping ringing")
        stopRinging()
        stopSelf()
    }

    // callId currently ringing, if any. A second START_RINGING intent for the
    // same call (Telecom + fallback race, duplicate FCM) must not spawn a
    // second Ringtone — the overwritten reference would keep playing.
    private var ringingCallId: String? = null

    private fun startRinging(callId: String = "") {
        if (ringingCallId == callId && ringtone?.isPlaying == true) {
            Log.d(TAG, "startRinging: already ringing for $callId — ignoring duplicate intent")
            return
        }
        ringingCallId = callId
        // Stop/release any previous instance before creating a new one —
        // Ringtone.play is async and an abandoned instance keeps sounding.
        try { ringtone?.stop() } catch (_: Exception) {}
        ringtone = null
        try { vibrator?.cancel() } catch (_: Exception) {}

        try {
            // Use MODE_RINGTONE for the ringing phase — this is the appropriate mode
            // while alerting the user. MODE_IN_COMMUNICATION must NOT be set here because
            // Android's Ringtone/MediaPlayer will internally override it, leaving the audio
            // subsystem in MODE_RINGTONE. When the call is actually answered, the accept
            // flow sets MODE_IN_COMMUNICATION before WebRTC captures audio.
            val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
            audioManager.mode = AudioManager.MODE_RINGTONE

            val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = powerManager.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "VantChat::CallRingingWakeLock"
            )
            wakeLock?.acquire(60 * 1000L)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to acquire wake lock: $e")
        }

        try {
            vibrator = getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                vibrator?.vibrate(VibrationEffect.createWaveform(longArrayOf(0, 1000, 1000), 0))
            } else {
                @Suppress("DEPRECATION")
                vibrator?.vibrate(longArrayOf(0, 1000, 1000), 0)
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start vibration: $e")
        }

        try {
            val ringtoneUri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
            ringtone = RingtoneManager.getRingtone(applicationContext, ringtoneUri)
            ringtone?.play()
        } catch (e: Exception) {
            Log.e(TAG, "Failed to play ringtone: $e")
        }
    }

    private fun stopRinging() {
        ringingCallId = null
        try { ringtone?.stop() } catch (_: Exception) {}
        try { vibrator?.cancel() } catch (_: Exception) {}
        try { wakeLock?.let { if (it.isHeld) it.release() } } catch (_: Exception) {}
        // Reset audio mode from MODE_RINGTONE to MODE_IN_COMMUNICATION
        // so the audio subsystem is ready for WebRTC voice communication.
        try {
            val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
            audioManager.mode = AudioManager.MODE_IN_COMMUNICATION
            Log.d(TAG, "stopRinging: audio mode set to MODE_IN_COMMUNICATION")
        } catch (_: Exception) {}
    }

    private fun startOngoingCall(intent: Intent?) {
        val nextCallId = intent?.getStringExtra("call_id") ?: ""
        val existingStart = if (isOngoingCall && ongoingCallId == nextCallId) {
            ongoingStartTime
        } else {
            System.currentTimeMillis()
        }
        isOngoingCall = true
        ongoingCallId = nextCallId
        ongoingCallerName = intent?.getStringExtra("caller_name") ?: "Unknown"
        ongoingIsVideo = intent?.getBooleanExtra("is_video", false) ?: false
        ongoingStartTime = existingStart

        stopRinging()

        // CRITICAL: Set audio mode for ongoing calls to maintain speaker state in background
        try {
            val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
            audioManager.mode = AudioManager.MODE_IN_COMMUNICATION
            Log.d(TAG, "Audio mode set to MODE_IN_COMMUNICATION for ongoing call")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to set audio mode for ongoing call: ${e.message}", e)
        }

        val notification = buildOngoingNotification()
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                var serviceType = ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE or
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL
                val hasCameraPermission = ContextCompat.checkSelfPermission(
                    this,
                    Manifest.permission.CAMERA
                ) == PackageManager.PERMISSION_GRANTED
                if (ongoingIsVideo && hasCameraPermission) {
                    serviceType = serviceType or ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA
                }
                ServiceCompat.startForeground(
                    this,
                    ONGOING_NOTIFICATION_ID,
                    notification,
                    serviceType
                )
                Log.d(
                    TAG,
                    "Started ongoing foreground (microphone, phoneCall" +
                        "${if (ongoingIsVideo && hasCameraPermission) ", camera" else ""})"
                )
            } else {
                startForeground(ONGOING_NOTIFICATION_ID, notification)
                Log.d(TAG, "Started ongoing foreground (pre-API 34)")
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start ongoing foreground: ${e.message}", e)
            try {
                startForeground(ONGOING_NOTIFICATION_ID, notification)
            } catch (e2: Exception) {
                Log.e(TAG, "Fallback ongoing foreground failed: ${e2.message}", e2)
                stopSelf()
            }
        }
    }

    private fun stopOngoingCall() {
        isOngoingCall = false
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun buildOngoingNotification(): Notification {
        val openIntent = Intent(this, MainActivity::class.java).apply {
            action = "com.vant.chat.OPEN_ONGOING_CALL"
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra("call_id", ongoingCallId)
            putExtra("caller_name", ongoingCallerName)
            putExtra("is_video", ongoingIsVideo)
        }

        val openPendingIntent = PendingIntent.getActivity(
            this, 0, openIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val callType = if (ongoingIsVideo) "Video call" else "Voice call"
        val endCallIntent = Intent(this, MainActivity::class.java).apply {
            action = "com.vant.chat.END_CALL"
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra("call_id", ongoingCallId)
        }
        val endCallPendingIntent = PendingIntent.getActivity(
            this, 1, endCallIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val caller = androidx.core.app.Person.Builder()
            .setName(ongoingCallerName)
            .setIcon(
                androidx.core.graphics.drawable.IconCompat.createWithResource(
                    this,
                    R.drawable.ic_call_notification
                )
            )
            .build()
        val callStyle = NotificationCompat.CallStyle.forOngoingCall(
            caller,
            endCallPendingIntent
        )

        return NotificationCompat.Builder(this, ONGOING_CHANNEL_ID)
            .setContentTitle(ongoingCallerName)
            .setContentText(callType)
            .setSmallIcon(R.drawable.ic_call_notification)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setStyle(callStyle)
            .setContentIntent(openPendingIntent)
            .setOngoing(true)
            .setAutoCancel(false)
            .setSilent(true)
            .setShowWhen(true)
            .setWhen(ongoingStartTime)
            .setUsesChronometer(true)
            .setChronometerCountDown(false)
            .build()
    }

    private fun buildCallNotification(
        callerName: String,
        callerId: String,
        callId: String,
        roomId: String,
        avatarUrl: String,
        isVideo: Boolean
    ): Notification {
        // Foreground-service notification that doubles as the incoming-call UI
        // trigger: the full-screen intent launches IncomingCallActivity over the
        // lock screen, and the CallStyle actions let the user answer/decline from
        // the heads-up notification if the full-screen UI can't appear.
        val contentIntent = Intent(this, IncomingCallActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra("caller_name", callerName)
            putExtra("caller_id", callerId)
            putExtra("call_id", callId)
            putExtra("room_id", roomId)
            putExtra("avatar_url", avatarUrl)
            putExtra("is_video", isVideo)
        }

        val contentPendingIntent = PendingIntent.getActivity(
            this, 0, contentIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        // Answer/decline actions so the call can be handled directly from the
        // notification (heads-up fallback when the full-screen UI can't show).
        val answerIntent = Intent(this, MainActivity::class.java).apply {
            action = "com.vant.chat.ANSWER_CALL"
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra("call_id", callId)
            putExtra("room_id", roomId)
            putExtra("caller_name", callerName)
            putExtra("caller_id", callerId)
            putExtra("is_video", isVideo)
            putExtra("from_native", true)
            putExtra("answered_from_background", true)
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

        val caller = androidx.core.app.Person.Builder()
            .setName(callerName)
            .setIcon(
                androidx.core.graphics.drawable.IconCompat.createWithResource(
                    this,
                    R.drawable.ic_call_notification
                )
            )
            .build()

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(if (isVideo) "Incoming video call" else "Incoming call")
            .setContentText(callerName)
            .setSmallIcon(R.drawable.ic_call_notification)
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setStyle(
                NotificationCompat.CallStyle.forIncomingCall(
                    caller,
                    declinePendingIntent,
                    answerPendingIntent
                )
            )
            .setContentIntent(contentPendingIntent)
            // The full-screen intent is what actually launches IncomingCallActivity
            // over the lock screen. Direct startActivity() from a background
            // service is silently blocked by the OS.
            .setFullScreenIntent(contentPendingIntent, true)
            .setOngoing(true)
            .setAutoCancel(false)
            .build()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        stopRinging()
        try {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } catch (_: Exception) {}
        super.onDestroy()
    }
}
