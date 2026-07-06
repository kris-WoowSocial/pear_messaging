package com.vant.chat

import android.app.NotificationManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
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
        tvStatus.text = if (isVideo) "Incoming video call..." else "Incoming call..."

        if (avatarUrl.isNotEmpty()) {
            Glide.with(this)
                .load(avatarUrl)
                .placeholder(R.drawable.ic_call_notification)
                .circleCrop()
                .into(ivAvatar)
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
        cancelCallNotification()
        val intent = Intent(this, MainActivity::class.java).apply {
            action = "com.vant.chat.ANSWER_CALL"
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra("call_id", callId)
            putExtra("room_id", roomId)
            putExtra("caller_name", callerName)
            putExtra("caller_id", callerId)
            putExtra("is_video", isVideo)
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
