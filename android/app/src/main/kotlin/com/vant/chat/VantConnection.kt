package com.vant.chat

import android.content.Context
import android.content.Intent
import android.media.AudioManager
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

        // Stop ringing
        VantCallManager.stopRinging(context)

        // Set audio mode for VoIP calls (prevents speaker delay)
        val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        audioManager.mode = AudioManager.MODE_IN_COMMUNICATION
        audioManager.isSpeakerphoneOn = false

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
        }
        context.startActivity(intent)
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
