package com.vant.chat

import android.content.Context
import android.content.Intent
import android.media.AudioManager
import android.os.Build
import android.os.Bundle
import android.telecom.Connection
import android.telecom.DisconnectCause
import android.util.Log

/**
 * Represents a single VoIP call within the Android Telecom framework.
 * Handles answer, reject, and disconnect actions from system UI, Bluetooth, etc.
 */
class VantConnection(private val context: Context) : Connection() {

    companion object {
        const val TAG = "VantConnection"
    }

    private val connectionExtras = Bundle()

    fun setConnectionExtra(key: String, value: String) {
        connectionExtras.putString(key, value)
    }

    fun setConnectionExtra(key: String, value: Boolean) {
        connectionExtras.putBoolean(key, value)
    }

    fun getConnectionExtra(key: String): String? = connectionExtras.getString(key)

    override fun onShowIncomingCallUi() {
        Log.d(TAG, "onShowIncomingCallUi — system wants us to show incoming call UI")

        // Signal that Telecom triggered our UI — prevents the fallback timer from firing
        VantCallManager.markCallUiShown()

        val callerName = connectionExtras.getString("caller_name") ?: "Unknown"
        val callerId = connectionExtras.getString("caller_id") ?: ""
        val callId = connectionExtras.getString("call_id") ?: ""
        val roomId = connectionExtras.getString("room_id") ?: ""
        val avatarUrl = connectionExtras.getString("avatar_url") ?: ""
        val isVideo = connectionExtras.getBoolean("is_video", false)

        // Start ringing and try to show the full-screen IncomingCallActivity.
        // If the activity cannot be launched, presentIncomingCall falls back to a
        // notification with answer/decline actions and a full-screen intent.
        VantCallManager.presentIncomingCall(context, callerName, callerId, callId, roomId, avatarUrl, isVideo)
    }

    override fun onAnswer() {
        Log.d(TAG, "onAnswer called (from system UI / Bluetooth / etc.)")
        setActive()

        // Tell Telecom this is a VoIP call so the system doesn't fight our audio routing
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            setAudioModeIsVoip(true)
        }

        // Stop ringing
        VantCallManager.stopRinging(context)

        // Set MODE_IN_COMMUNICATION so WebRTC AudioTrack is created correctly.
        // DO NOT request audio focus or set communication device — AudioSwitch
        // (flutter_webrtc) is the sole owner of audio focus and device routing.
        val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        if (audioManager.mode != AudioManager.MODE_IN_COMMUNICATION) {
            audioManager.mode = AudioManager.MODE_IN_COMMUNICATION
        }
        Log.d(TAG, "Audio mode set to MODE_IN_COMMUNICATION (AudioSwitch handles routing)")

        // Check if app is in background
        val isAppInBackground = isAppInBackground(context)
        Log.d(TAG, "App in background when answering: $isAppInBackground")

        // Launch MainActivity with ANSWER_CALL action
        val callId = connectionExtras.getString("call_id") ?: ""
        val roomId = connectionExtras.getString("room_id") ?: ""
        val callerName = connectionExtras.getString("caller_name") ?: ""
        val callerId = connectionExtras.getString("caller_id") ?: ""
        val isVideo = connectionExtras.getBoolean("is_video", false)

        val intent = Intent(context, MainActivity::class.java).apply {
            action = "com.vant.chat.ANSWER_CALL"
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra("call_id", callId)
            putExtra("room_id", roomId)
            putExtra("caller_name", callerName)
            putExtra("caller_id", callerId)
            putExtra("is_video", isVideo)
            putExtra("answered_from_background", isAppInBackground) // Dynamic check
            putExtra("from_native", true) // Mark as answered from native UI
        }
        context.startActivity(intent)
    }

    private fun isAppInBackground(context: Context): Boolean {
        val activityManager = context.getSystemService(Context.ACTIVITY_SERVICE) as android.app.ActivityManager
        val appProcesses = activityManager.runningAppProcesses ?: return false
        val packageName = context.packageName
        val currentProcessId = android.os.Process.myPid()
        
        for (processInfo in appProcesses) {
            if (processInfo.processName == packageName && processInfo.pid == currentProcessId) {
                val importance = processInfo.importance
                return importance == android.app.ActivityManager.RunningAppProcessInfo.IMPORTANCE_BACKGROUND ||
                       importance == android.app.ActivityManager.RunningAppProcessInfo.IMPORTANCE_SERVICE ||
                       importance == android.app.ActivityManager.RunningAppProcessInfo.IMPORTANCE_CANT_SAVE_STATE
            }
        }
        return false
    }

    override fun onHold() {
        Log.d(TAG, "onHold called by Telecom — external call took over")
        // Keep the VoIP connection alive while the system handles another call.
        super.onHold()
        // Notify Flutter so it can mute WebRTC audio and show "call on hold" UI
        context.sendBroadcast(Intent("com.vant.chat.CALL_HELD"))
    }

    override fun onUnhold() {
        Log.d(TAG, "onUnhold called by Telecom — external call ended")
        super.onUnhold()
        setActive()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            setAudioModeIsVoip(true)
        }
        // Notify Flutter so it can unmute WebRTC audio and resume the call UI
        context.sendBroadcast(Intent("com.vant.chat.CALL_UNHELD"))
    }

    override fun onReject() {
        Log.d(TAG, "onReject called")
        setDisconnected(DisconnectCause(DisconnectCause.REJECTED))
        val callId = connectionExtras.getString("call_id") ?: ""
        VantCallManager.clearActiveConnection(this)
        VantCallManager.releaseCallResources(context, callId)

        val callerId = connectionExtras.getString("caller_id") ?: ""
        val intent = Intent(context, MainActivity::class.java).apply {
            action = "com.vant.chat.DECLINE_CALL"
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra("call_id", callId)
            putExtra("caller_id", callerId)
        }
        context.startActivity(intent)
        destroy()
    }

    override fun onDisconnect() {
        Log.d(TAG, "onDisconnect called")
        setDisconnected(DisconnectCause(DisconnectCause.LOCAL))
        val callId = connectionExtras.getString("call_id") ?: ""
        VantCallManager.clearActiveConnection(this)
        VantCallManager.releaseCallResources(context, callId)

        val intent = Intent(context, MainActivity::class.java).apply {
            action = "com.vant.chat.END_CALL"
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra("call_id", callId)
        }
        context.startActivity(intent)
        destroy()
    }

    override fun onAbort() {
        Log.d(TAG, "onAbort called")
        setDisconnected(DisconnectCause(DisconnectCause.CANCELED))
        val callId = connectionExtras.getString("call_id") ?: ""
        VantCallManager.clearActiveConnection(this)
        VantCallManager.releaseCallResources(context, callId)
        destroy()
    }
}
