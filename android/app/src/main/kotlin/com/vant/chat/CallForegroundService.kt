package com.vant.chat

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioAttributes
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

/**
 * Foreground service for incoming call ringing.
 *
 * Uses `shortService` foreground type on Android 14+ because:
 * - `phoneCall` requires MANAGE_OWN_CALLS or ROLE_DIALER
 * - `microphone` requires RECORD_AUDIO runtime permission AND app must be in foreground
 * - `shortService` has no special permission requirements, can run ~3 min (enough for ringing),
 *   and can be started from background (FCM message handler)
 *
 * The microphone foreground service type is only needed when the call is actually answered
 * and WebRTC starts capturing audio — that is handled by flutter_background_service, not here.
 */
class CallForegroundService : Service() {

    companion object {
        const val TAG = "VantCallFG"
        const val CHANNEL_ID = "vant_chat_calls"
        const val NOTIFICATION_ID = 9999
        const val ACTION_START_RINGING = "com.vant.chat.START_RINGING"
        const val ACTION_STOP_RINGING = "com.vant.chat.STOP_RINGING"
    }

    private var wakeLock: PowerManager.WakeLock? = null
    private var vibrator: Vibrator? = null
    private var ringtone: Ringtone? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Log.d(TAG, "onStartCommand: action=${intent?.action}")

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
                // Android 14+ (API 34): use shortService type — no special permissions needed
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
            // Last resort: try without specifying type
            try {
                startForeground(NOTIFICATION_ID, notification)
            } catch (e2: Exception) {
                Log.e(TAG, "Fallback startForeground also failed: ${e2.message}", e2)
                stopSelf()
                return START_NOT_STICKY
            }
        }

        val action = intent?.action
        if (action == ACTION_STOP_RINGING) {
            stopRinging()
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            return START_NOT_STICKY
        }

        startRinging()
        return START_NOT_STICKY
    }

    override fun onTimeout(startId: Int) {
        // Called on Android 14+ when shortService timeout (~3 min) expires.
        // Stop the ringing — if nobody answered in 3 minutes, it's a missed call.
        Log.d(TAG, "shortService timeout reached, stopping ringing")
        stopRinging()
        stopSelf()
    }

    private fun startRinging() {
        try {
            // Set audio mode for VoIP calls (prevents speaker delay)
            val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
            audioManager.mode = AudioManager.MODE_IN_COMMUNICATION

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
        try { wakeLock?.let { if (it.isHeld) it.release() } } catch (_: Exception) {}
        try { vibrator?.cancel() } catch (_: Exception) {}
        try { ringtone?.stop() } catch (_: Exception) {}
    }

    private fun buildCallNotification(
        callerName: String,
        callerId: String,
        callId: String,
        roomId: String,
        avatarUrl: String,
        isVideo: Boolean
    ): Notification {
        // This is the foreground service's required notification.
        // It must be visible, but it is intentionally silent and has no actions.
        // The actual incoming-call UI is the IncomingCallActivity; if that cannot
        // be launched, VantCallManager.showCallNotification() posts a rich fallback
        // notification with answer/decline actions and a full-screen intent.
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

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(if (isVideo) "Incoming video call" else "Incoming call")
            .setContentText(callerName)
            .setSmallIcon(R.drawable.ic_call_notification)
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setContentIntent(contentPendingIntent)
            .setOngoing(true)
            .setAutoCancel(false)
            .setSilent(true)
            .build()
    }

    private fun createNotificationChannel() {
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

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        stopRinging()
        super.onDestroy()
    }
}
