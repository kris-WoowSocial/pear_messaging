package com.vant.chat

import android.app.NotificationManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioManager
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.telecom.CallAudioState
import android.util.Log
import android.view.WindowManager
import android.widget.ImageView
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import com.bumptech.glide.Glide

class IncomingCallActivity : AppCompatActivity() {

    private var callId: String = ""
    private var callerId: String = ""
    private var callerName: String = ""
    private var roomId: String = ""
    private var avatarUrl: String = ""
    private var isVideo: Boolean = false
    private var cancelReceiver: BroadcastReceiver? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setupLockScreen()
        setContentView(R.layout.activity_incoming_call)
        readExtras()
        bindViews()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        readExtras()
        bindViews()
    }

    private fun setupLockScreen() {
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
        try {
            @Suppress("DEPRECATION")
            val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
            val wakeLock = powerManager.newWakeLock(
                PowerManager.FULL_WAKE_LOCK or
                PowerManager.ACQUIRE_CAUSES_WAKEUP or
                PowerManager.ON_AFTER_RELEASE,
                "VantChat::IncomingCallActivityWakeLock"
            )
            wakeLock.acquire(30 * 1000L)
            wakeLock.release()
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    private fun readExtras() {
        val extras = intent.extras
        callId = extras?.getString("call_id") ?: ""
        callerId = extras?.getString("caller_id") ?: ""
        callerName = extras?.getString("caller_name") ?: "Unknown"
        roomId = extras?.getString("room_id") ?: ""
        avatarUrl = extras?.getString("avatar_url") ?: ""
        isVideo = extras?.getBoolean("is_video", false) ?: false
    }

    private fun bindViews() {
        val tvName = findViewById<TextView>(R.id.tvCallerName)
        val tvStatus = findViewById<TextView>(R.id.tvCallStatus)
        val ivAvatar = findViewById<ImageView>(R.id.ivCallerAvatar)
        val btnAnswer = findViewById<ImageView>(R.id.btnAnswer)
        val btnDecline = findViewById<ImageView>(R.id.btnDecline)

        tvName.text = callerName
        tvStatus.text = if (isVideo) "Incoming video call" else "Incoming call..."

        if (avatarUrl.isNotEmpty()) {
            Glide.with(this)
                .load(avatarUrl)
                .placeholder(R.mipmap.launcher_icon)
                .error(R.mipmap.launcher_icon)
                .circleCrop()
                .into(ivAvatar)
        } else {
            ivAvatar.setImageResource(R.mipmap.launcher_icon)
        }

        btnAnswer.setOnClickListener { answerCall() }
        btnDecline.setOnClickListener { declineCall() }

        // Listen for caller cancelling the call so we can close the native UI automatically.
        cancelReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                if (intent?.action == "com.vant.chat.CANCEL_CALL") {
                    val cancelledCallId = intent.getStringExtra("call_id")
                    if (cancelledCallId == null || cancelledCallId == callId) {
                        finish()
                    }
                }
            }
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(
                cancelReceiver,
                IntentFilter("com.vant.chat.CANCEL_CALL"),
                Context.RECEIVER_NOT_EXPORTED
            )
        } else {
            registerReceiver(cancelReceiver, IntentFilter("com.vant.chat.CANCEL_CALL"))
        }
    }

    private fun answerCall() {
        Log.d("IncomingCallActivity", "✅ Answer tapped from native screen")

        // CRITICAL: Tell the Telecom framework that the call is now ACTIVE.
        // Without this, the self-managed VantConnection stays in RINGING state and
        // the system audio router keeps overriding MODE_IN_COMMUNICATION back to
        // MODE_RINGTONE. This causes WebRTC's AudioTrack to be created under
        // STREAM_RING which locks audio to the earpiece permanently.
        VantCallManager.activeConnection?.let { connection ->
            connection.setActive()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                connection.setAudioModeIsVoip(true)
            }
            if (isVideo && Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                try {
                    connection.setAudioRoute(CallAudioState.ROUTE_SPEAKER)
                } catch (e: Exception) {
                    Log.e("IncomingCallActivity", "Failed to route video call to speaker", e)
                }
            }
            Log.d("IncomingCallActivity", "🔊 Telecom connection set to ACTIVE + VoIP mode")
        }

        // Set MODE_IN_COMMUNICATION so WebRTC AudioTrack is created under correct mode.
        // DO NOT request audio focus or force earpiece — AudioSwitch (flutter_webrtc)
        // is the sole owner of audio focus and device routing.
        val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        if (audioManager.mode != AudioManager.MODE_IN_COMMUNICATION) {
            audioManager.mode = AudioManager.MODE_IN_COMMUNICATION
        }
        Log.d("IncomingCallActivity", "🔊 Audio mode set to MODE_IN_COMMUNICATION")

        cancelCallNotification()
        val intent = Intent(this, MainActivity::class.java).apply {
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
        startActivity(intent)
        finish()
    }

    private fun declineCall() {
        cancelCallNotification()
        val intent = Intent(this, MainActivity::class.java).apply {
            action = "com.vant.chat.DECLINE_CALL"
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra("call_id", callId)
            putExtra("caller_id", callerId)
        }
        startActivity(intent)
        finish()
    }

    private fun cancelCallNotification() {
        try {
            val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            notificationManager.cancel(VantFirebaseMessagingService.NOTIFICATION_ID)
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    override fun onDestroy() {
        cancelReceiver?.let { unregisterReceiver(it) }
        super.onDestroy()
        try {
            stopService(Intent(this, CallForegroundService::class.java))
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }
}
